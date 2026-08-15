#!/usr/bin/env bash
# vless-reality-deploy — VLESS + Reality + Vision 一键部署与线路优化
#
# 在裸 Debian/Ubuntu VPS 上从零部署 Xray VLESS-Reality 代理，
# 并应用经过实测的 TCP 内核优化（含 tcpfit BDP 推导 + 限速器整形）。
#
# 用法:
#   bash vless-reality-deploy.sh                # 完整部署（推荐）
#   bash vless-reality-deploy.sh --skip-sweep   # 跳过限速器扫描（省流量）
#   bash vless-reality-deploy.sh --optimize-only # 只做网络优化，不重装 Xray
#   bash vless-reality-deploy.sh --show-config  # 打印当前客户端配置
#
# 幂等：重复运行不会重复安装，密钥和 UUID 保存在 /usr/local/etc/xray/.deploy-info
#
# 优化内容:
#   1. BBR + fq 拥塞控制
#   2. tcpfit v0.5.6 — BDP 实测推导缓冲区 + 限速器拐点扫描 + HTB 整形
#      项目: https://github.com/Kylin010/tcpfit (MIT License)
#   3. initcwnd/initrwnd = 32, TCP Fast Open
#   4. conntrack 扩容 524288
#   5. virtio_net 多队列（如果支持）
#   6. Xray sockopt: tcpFastOpen + tcpNoDelay + keepalive
#   7. UFW 防火墙: 仅放行 22/443
#
# 安全说明:
#   - UUID / 密钥对 / shortId 全部在运行时由 Xray 生成，不写死在脚本里
#   - Reality 伪装目标默认 www.amazon.com:443（可改 REALITY_DEST）
#   - tcpfit 快照保存在 /var/lib/tcpfit/，随时可 tcpfit rollback

set -euo pipefail

# ─── 可配置项 ────────────────────────────────────────────────────────────────
XRAY_PORT="${XRAY_PORT:-443}"
SSH_PORT="${SSH_PORT:-22}"
REALITY_DEST="${REALITY_DEST:-www.amazon.com:443}"
REALITY_SNI="${REALITY_SNI:-www.amazon.com}"
BANDWIDTH="${BANDWIDTH:-500}"          # Mbps, 用于 tcpfit 推导 BDP
SWEEP_PEER="${SWEEP_PEER:-}"           # iperf3 对端, 留空则自动选
SKIP_SWEEP=0
OPTIMIZE_ONLY=0

STATE_FILE="/usr/local/etc/xray/.deploy-info"
TCPFIT_VERSION="0.5.6"
TCPFIT_URL="https://raw.githubusercontent.com/Kylin010/tcpfit/v${TCPFIT_VERSION}/tcpfit.sh"

# ─── 颜色 ────────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  G=$'\033[0;32m'; R=$'\033[0;31m'; Y=$'\033[0;33m'; C=$'\033[0;36m'; B=$'\033[1m'; P=$'\033[0m'
else
  G=''; R=''; Y=''; C=''; B=''; P=''
fi
info(){ printf '%s %s\n' "${C}[*]${P}" "$*"; }
ok(){   printf '%s %s\n' "${G}[+]${P}" "$*"; }
warn(){ printf '%s %s\n' "${Y}[!]${P}" "$*" >&2; }
die(){  printf '%s %s\n' "${R}[x]${P}" "$*" >&2; exit "${2:-1}"; }

# ─── 参数解析 ────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-sweep)     SKIP_SWEEP=1; shift ;;
    --optimize-only)  OPTIMIZE_ONLY=1; shift ;;
    --show-config)    SHOW_CONFIG=1; shift ;;
    --bw)             BANDWIDTH="$2"; shift 2 ;;
    --sweep-peer)     SWEEP_PEER="$2"; shift 2 ;;
    --port)           XRAY_PORT="$2"; shift 2 ;;
    --dest)           REALITY_DEST="$2"; REALITY_SNI="${2%%:*}"; shift 2 ;;
    -h|--help)        sed -n '2,/^set /{/^set /!{s/^# \?//;p}}' "$0"; exit 0 ;;
    *)                die "未知参数: $1" ;;
  esac
done

need_root(){ [ "$(id -u)" = 0 ] || die "需要 root 权限"; }

detect_iface(){ ip -4 route show default 2>/dev/null | awk '{print $5; exit}'; }

# ─── 打印已保存的客户端配置 ─────────────────────────────────────────────────
cmd_show_config(){
  [ -f "$STATE_FILE" ] || die "未找到部署信息，请先运行完整部署"
  # shellcheck disable=SC1090
  . "$STATE_FILE"
  echo
  echo "${B}── vless 分享链接 ──${P}"
  echo
  echo "vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${TAG:-VLESS-Reality}"
  echo
  echo "${B}── 参数速查 ──${P}"
  printf '  %-14s %s\n' "Address:"   "$SERVER_IP"
  printf '  %-14s %s\n' "Port:"      "$PORT"
  printf '  %-14s %s\n' "UUID:"      "$UUID"
  printf '  %-14s %s\n' "Flow:"      "xtls-rprx-vision"
  printf '  %-14s %s\n' "Security:"  "reality"
  printf '  %-14s %s\n' "SNI:"       "$SNI"
  printf '  %-14s %s\n' "PublicKey:" "$PUBLIC_KEY"
  printf '  %-14s %s\n' "ShortID:"   "$SHORT_ID"
  echo
}

# ─── 阶段 1: 安装 Xray ──────────────────────────────────────────────────────
install_xray(){
  info "[1/5] 安装 Xray-core"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl unzip ufw jq > /dev/null 2>&1

  if ! command -v xray >/dev/null 2>&1; then
    bash -c "$(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install 2>&1 | tail -3
  else
    info "Xray 已安装: $(xray version 2>&1 | head -1)"
  fi
}

# ─── 阶段 2: 生成密钥并写入配置 ─────────────────────────────────────────────
configure_xray(){
  info "[2/5] 配置 VLESS + Reality + Vision"

  if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    info "复用已有密钥 (UUID: ${UUID:0:8}...)"
  else
    local keys
    keys=$(xray x25519)
    PRIVATE_KEY=$(echo "$keys" | grep -i private | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$keys"  | grep -i public  | awk '{print $NF}')
    UUID=$(xray uuid)
    SHORT_ID=$(openssl rand -hex 4)
    SERVER_IP=$(curl -s4 --max-time 8 ifconfig.co 2>/dev/null || curl -s4 --max-time 8 api.ipify.org)
    SNI="$REALITY_SNI"
    PORT="$XRAY_PORT"
    TAG="VLESS-Reality"

    mkdir -p "$(dirname "$STATE_FILE")"
    cat > "$STATE_FILE" <<EOF
UUID=$UUID
PRIVATE_KEY=$PRIVATE_KEY
PUBLIC_KEY=$PUBLIC_KEY
SHORT_ID=$SHORT_ID
SERVER_IP=$SERVER_IP
SNI=$SNI
PORT=$PORT
TAG=$TAG
DEPLOY_DATE=$(date -u +%FT%TZ)
EOF
    chmod 600 "$STATE_FILE"
    ok "密钥已生成并保存到 $STATE_FILE"
  fi

  cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$REALITY_DEST",
          "xver": 0,
          "serverNames": ["$SNI"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$SHORT_ID"]
        },
        "sockopt": {
          "tcpFastOpen": true,
          "tcpNoDelay": true,
          "tcpKeepAliveInterval": 30,
          "mark": 255
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": { "domainStrategy": "UseIPv4v6" }
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF

  xray -test -config /usr/local/etc/xray/config.json 2>&1 | grep -q "Configuration OK" \
    || die "Xray 配置验证失败"

  # systemd 文件描述符上限
  mkdir -p /etc/systemd/system/xray.service.d
  cat > /etc/systemd/system/xray.service.d/limits.conf <<'EOF'
[Service]
LimitNOFILE=1048576
EOF
  systemctl daemon-reload
  systemctl enable xray > /dev/null 2>&1
  systemctl restart xray
  sleep 2
  systemctl is-active xray > /dev/null || die "Xray 启动失败"
  ok "Xray 运行在 :$PORT (VLESS + Reality + Vision + sockopt)"
}

# ─── 阶段 3: 防火墙 ─────────────────────────────────────────────────────────
setup_firewall(){
  info "[3/5] 配置防火墙"
  ufw --force reset > /dev/null 2>&1
  ufw default deny incoming > /dev/null 2>&1
  ufw default allow outgoing > /dev/null 2>&1
  ufw allow "$SSH_PORT"/tcp > /dev/null 2>&1
  ufw allow "$PORT"/tcp > /dev/null 2>&1
  ufw allow "$PORT"/udp > /dev/null 2>&1
  ufw --force enable > /dev/null 2>&1
  ok "UFW: 仅放行 $SSH_PORT(SSH) 和 $PORT(代理)"
}

# ─── 阶段 4: 网络优化 ───────────────────────────────────────────────────────
optimize_network(){
  info "[4/5] 网络优化 (tcpfit + 补充项)"

  # 4a. 安装 tcpfit
  if [ ! -x /usr/local/bin/tcpfit ]; then
    curl -fsSL "$TCPFIT_URL" -o /usr/local/bin/tcpfit \
      || die "tcpfit 下载失败"
    chmod +x /usr/local/bin/tcpfit
    ok "tcpfit v${TCPFIT_VERSION} 已安装"
  else
    info "tcpfit 已安装: $(tcpfit version 2>&1)"
  fi

  # 4b. tcpfit 基础调优
  local iface; iface=$(detect_iface)
  [ -n "$iface" ] || die "找不到默认路由网卡"
  tcpfit tune --role proxy --bw "$BANDWIDTH" 2>&1 | grep -E "^\[" || true

  # 4c. 补充项（tcpfit 没管的）
  cat > /etc/sysctl.d/99-deploy-extra.conf <<'EOF'
# 部署脚本补充项 — 与 tcpfit 互补
net.core.netdev_max_backlog = 250000
net.ipv4.ip_forward = 1
net.netfilter.nf_conntrack_max = 524288
net.nf_conntrack_max = 524288
EOF
  sysctl -p /etc/sysctl.d/99-deploy-extra.conf > /dev/null 2>&1 || true
  ok "补充 sysctl: backlog=250000, conntrack=524288, ip_forward=1"

  # 4d. virtio_net 多队列
  if ethtool -l "$iface" 2>/dev/null | grep -q "Combined:.*2"; then
    local cur; cur=$(ethtool -l "$iface" 2>/dev/null | awk '/^Current/{f=1} f && /Combined/{print $2}')
    if [ "$cur" = "1" ]; then
      ethtool -L "$iface" combined 2 2>/dev/null \
        && ok "virtio_net 队列: 1 → 2" \
        || warn "virtio_net 多队列设置失败（不影响使用）"
    fi
  fi

  # 4e. 时间同步（Reality 握手必需）
  timedatectl set-ntp true 2>/dev/null || true

  # 4f. 限速器扫描 + HTB 整形
  if [ "$SKIP_SWEEP" = 0 ]; then
    if ! command -v iperf3 > /dev/null 2>&1; then
      apt-get install -y -qq iperf3 > /dev/null 2>&1
    fi
    if command -v iperf3 > /dev/null 2>&1; then
      local peer="$SWEEP_PEER"
      if [ -z "$peer" ]; then
        # 根据 ping 延迟自动选最近的公共节点
        local candidates="speedtest.lax12.us.leaseweb.net speedtest.sfo12.us.leaseweb.net speedtest.hkg12.hk.leaseweb.net speedtest.tyo11.jp.leaseweb.net speedtest.sin1.sg.leaseweb.net"
        local best_rtt=9999 best_peer=""
        for c in $candidates; do
          local r; r=$(ping -4 -c 2 -q -W 2 "$c" 2>/dev/null | awk -F'/' '/rtt|round-trip/{printf "%d", $5}')
          if [ -n "$r" ] && [ "$r" -lt "$best_rtt" ]; then best_rtt="$r"; best_peer="$c"; fi
        done
        peer="$best_peer"
      fi
      if [ -n "$peer" ]; then
        info "限速器扫描: 对端 $peer (RTT ~${best_rtt:-?}ms), 预计消耗 10-20 GB 流量"
        tcpfit sweep --peer "$peer" --nominal "$BANDWIDTH" 2>&1 | tail -15
        local rate; rate=$(awk -F= '/^RECOMMEND/{print $2}' /var/lib/tcpfit/sweep.result 2>/dev/null)
        if [ -n "$rate" ]; then
          tcpfit shape --rate "$rate" 2>&1 | grep -E "^\[" || true
          ok "HTB 整形: ${rate} Mbit"
        else
          warn "未检测到限速器, 跳过整形"
        fi
      else
        warn "未找到可用的 iperf3 对端, 跳过扫描"
      fi
    fi
  else
    info "跳过限速器扫描 (--skip-sweep)"
  fi
}

# ─── 阶段 5: 输出 ────────────────────────────────────────────────────────────
print_result(){
  echo
  echo "${B}════════════════════════════════════════════════════════${P}"
  echo "${B}  部署完成${P}"
  echo "${B}════════════════════════════════════════════════════════${P}"
  cmd_show_config

  echo "${B}── 验证 ──${P}"
  printf '  %-14s %s\n' "Xray:"      "$(systemctl is-active xray)"
  printf '  %-14s %s\n' "Port $PORT:"  "$(ss -tlnp 2>/dev/null | grep -c ":$PORT ") listener(s)"
  printf '  %-14s %s\n' "BBR:"       "$(sysctl -n net.ipv4.tcp_congestion_control)"
  printf '  %-14s %s\n' "qdisc:"     "$(tc qdisc show dev "$(detect_iface)" 2>/dev/null | head -1 | awk '{print $2}')"
  local shaper; shaper=$(tcpfit status 2>/dev/null | grep "Egress shaper" | awk '{print $NF}')
  printf '  %-14s %s\n' "整形:"      "${shaper:-none}"
  printf '  %-14s %s\n' "conntrack:" "$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null)"
  echo
  echo "${B}── 管理命令 ──${P}"
  echo "  tcpfit status        # 查看当前调优状态"
  echo "  tcpfit verify --peer <iperf3服务器>  # 验证端口吞吐"
  echo "  tcpfit rollback      # 回滚所有网络优化"
  echo "  bash $0 --show-config  # 重新打印客户端配置"
  echo
}

# ─── 入口 ────────────────────────────────────────────────────────────────────
[ "${SHOW_CONFIG:-0}" = 1 ] && { need_root; cmd_show_config; exit 0; }

need_root

if [ "$OPTIMIZE_ONLY" = 1 ]; then
  optimize_network
  ok "网络优化完成"
  exit 0
fi

install_xray
configure_xray
setup_firewall
optimize_network
print_result
