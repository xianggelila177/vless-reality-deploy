#!/usr/bin/env bash
# vless-reality-deploy — VLESS + Reality + Vision 一键部署与线路优化
#
# 在裸 Debian/Ubuntu VPS 上从零部署 Xray VLESS-Reality 代理，
# 并应用经过实测的 TCP 内核优化（含 tcpfit BDP 推导 + 限速器整形），
# 外加系统 housekeeping：zRAM 压缩交换 / 时区 / 定时清理。
#
# 用法:
#   bash vless-reality-deploy.sh                 # 完整部署（推荐）
#   bash vless-reality-deploy.sh --skip-sweep    # 跳过限速器扫描（省 10-20GB 流量）
#   bash vless-reality-deploy.sh --optimize-only # 只做网络优化，不重装 Xray
#   bash vless-reality-deploy.sh --extras-only   # 只做系统附加项（zRAM/时区/定时清理）
#   bash vless-reality-deploy.sh --clean         # 立即清理系统垃圾（日志/缓存）
#   bash vless-reality-deploy.sh --show-config   # 打印当前客户端配置
#
# 选项:
#   --bw <Mbps>         标称带宽，tcpfit 用它推导 BDP（默认 500）
#   --sweep-peer <主机> iperf3 测速对端（默认按 ping 自动选最近公共节点）
#   --port <端口>       代理监听端口（默认 443）
#   --dest <host:443>   Reality 伪装目标（默认 www.amazon.com:443）
#   --tz <时区>         系统时区（默认 Asia/Shanghai；--no-tz 跳过）
#   --zram              强制部署 zRAM（默认 auto：无 swap 且内存 ≤4GB 时自动部署）
#   --no-zram           禁用 zRAM
#   --no-cleanup-cron   不部署每周定时清理
#   --no-warp           不部署 Cloudflare WARP 分流（默认自动部署）
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
#   7. UFW 防火墙: 仅放行 SSH/代理端口
#   8. zRAM 压缩交换区（lz4，无 swap 的小内存机自动部署）
#   9. 系统时区设置（默认 Asia/Shanghai）
#  10. 每周定时清理 journald/apt/docker 垃圾，防止磁盘撑爆
#
# 安全说明:
#   - UUID / 密钥对 / shortId 全部在运行时由 Xray 生成，不写死在脚本里
#   - Reality 伪装目标默认 www.amazon.com:443（可改 REALITY_DEST）
#   - tcpfit 快照保存在 /var/lib/tcpfit/，随时可 tcpfit rollback
#   - 清理逻辑刻意不 pkill apt/dpkg —— 强杀包管理器可能损坏 dpkg 数据库，
#     清理失败就等下周，比搞坏系统便宜

set -euo pipefail

VERSION="1.2.0"

# ─── 可配置项 ────────────────────────────────────────────────────────────────
XRAY_PORT="${XRAY_PORT:-443}"
SSH_PORT="${SSH_PORT:-22}"
REALITY_DEST="${REALITY_DEST:-www.amazon.com:443}"
REALITY_SNI="${REALITY_SNI:-www.amazon.com}"
BANDWIDTH="${BANDWIDTH:-500}"          # Mbps, 用于 tcpfit 推导 BDP
SWEEP_PEER="${SWEEP_PEER:-}"           # iperf3 对端, 留空则自动选
DEPLOY_TZ="${DEPLOY_TZ:-Asia/Shanghai}"

SKIP_SWEEP=0
OPTIMIZE_ONLY=0
EXTRAS_ONLY=0
SHOW_CONFIG=0
DO_CLEAN=0
WITH_TZ=1
WITH_CRON=1
WITH_ZRAM=auto                         # auto / force / no
WITH_WARP=1                            # 默认部署 WARP 分流

STATE_FILE="/usr/local/etc/xray/.deploy-info"
CLEAN_SCRIPT="/usr/local/sbin/vless-deploy-clean.sh"
CRON_MARK="vless-deploy-clean"
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

# apt/dpkg 锁等待：unattended-upgrades 等后台任务会短暂持有锁，
# 直接装包会拿锁失败。最多等 120 秒，超时就返回失败让调用方决定。
apt_install(){
  local i
  for i in $(seq 1 12); do
    if ! fuser /var/lib/dpkg/lock-frontend > /dev/null 2>&1; then
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" > /dev/null 2>&1
      return $?
    fi
    [ "$i" = 1 ] && info "等待 apt/dpkg 锁释放（unattended-upgrades 正在运行）…"
    sleep 10
  done
  return 1
}
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-sweep)       SKIP_SWEEP=1; shift ;;
    --optimize-only)    OPTIMIZE_ONLY=1; shift ;;
    --extras-only)      EXTRAS_ONLY=1; shift ;;
    --clean)            DO_CLEAN=1; shift ;;
    --show-config)      SHOW_CONFIG=1; shift ;;
    --bw)               BANDWIDTH="$2"; shift 2 ;;
    --sweep-peer)       SWEEP_PEER="$2"; shift 2 ;;
    --port)             XRAY_PORT="$2"; shift 2 ;;
    --dest)             REALITY_DEST="$2"; REALITY_SNI="${2%%:*}"; shift 2 ;;
    --tz)               DEPLOY_TZ="$2"; shift 2 ;;
    --no-tz)            WITH_TZ=0; shift ;;
    --zram)             WITH_ZRAM=force; shift ;;
    --no-zram)          WITH_ZRAM=no; shift ;;
    --no-cleanup-cron)  WITH_CRON=0; shift ;;
    --no-warp)          WITH_WARP=0; shift ;;
    -h|--help)          sed -n '2,/^set /{/^set /!{s/^# \?//;p}}' "$0"; exit 0 ;;
    *)                  die "未知参数: $1" ;;
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
  info "[1/6] 安装 Xray-core"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt_install curl unzip ufw jq || die "基础依赖安装失败（apt 锁被占用超过 2 分钟）"

  if ! command -v xray >/dev/null 2>&1; then
    bash -c "$(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install 2>&1 | tail -3
  else
    info "Xray 已安装: $(xray version 2>&1 | head -1)"
  fi
}

# ─── 阶段 2: 生成密钥并写入配置 ─────────────────────────────────────────────

# 安装 Cloudflare WARP 并设为 SOCKS5 代理模式（不改全局路由）。
# 受限域名（OpenAI/Grok/Netflix 等）通过 Xray 路由规则分流到 WARP 出口，
# 其余流量保持直连。WARP 出口是 Cloudflare 高信誉 IP，能过大部分 WAF。
setup_warp(){
  [ "$WITH_WARP" = 1 ] || return 0
  if command -v warp-cli > /dev/null 2>&1 && warp-cli --accept-tos status 2>&1 | grep -q "Connected"; then
    info "WARP 已安装并连接"
    return 0
  fi
  info "安装 Cloudflare WARP (SOCKS5 代理模式, 不改路由)…"
  apt_install gnupg2 || { warn "gnupg2 安装失败，跳过 WARP"; return 0; }
  curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
    | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null \
    || { warn "WARP GPG key 导入失败，跳过"; return 0; }
  local codename; codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $codename main" \
    > /etc/apt/sources.list.d/cloudflare-client.list
  apt-get update -qq 2>/dev/null
  apt_install cloudflare-warp || { warn "WARP 安装失败，跳过"; return 0; }
  warp-cli --accept-tos registration new 2>/dev/null || true
  warp-cli --accept-tos mode proxy > /dev/null 2>&1
  warp-cli --accept-tos proxy port 40000 > /dev/null 2>&1
  warp-cli --accept-tos connect > /dev/null 2>&1
  sleep 3
  if warp-cli --accept-tos status 2>&1 | grep -q "Connected"; then
    local warp_ip; warp_ip=$(curl -s4 --max-time 8 --socks5-hostname 127.0.0.1:40000 ifconfig.co 2>/dev/null)
    ok "WARP 已连接: SOCKS5 127.0.0.1:40000, 出口 IP ${warp_ip:-unknown} (Cloudflare)"
  else
    warn "WARP 连接失败，分流不生效（不影响代理主功能）"
  fi
}

configure_xray(){
  info "[2/6] 配置 VLESS + Reality + Vision"

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

  python3 -c "
import json

warp_outbound = {
    'protocol': 'socks',
    'tag': 'warp',
    'settings': {'servers': [{'address': '127.0.0.1', 'port': 40000}]},
    'streamSettings': {'sockopt': {'mark': 255}}
}

warp_domains = [
    'domain:x.ai', 'domain:grok.x.ai',
    'domain:netflix.com', 'domain:nflxext.com', 'domain:nflximg.com',
    'domain:nflximg.net', 'domain:nflxso.net', 'domain:nflxvideo.net',
    'domain:disneyplus.com', 'domain:dssott.com', 'domain:bamgrid.com',
    'domain:hulu.com', 'domain:hulustream.com',
    'domain:claude.ai', 'domain:anthropic.com',
]

config = {
    'log': {'loglevel': 'warning'},
    'inbounds': [{
        'listen': '0.0.0.0',
        'port': int('$PORT'),
        'protocol': 'vless',
        'settings': {
            'clients': [{'id': '$UUID', 'flow': 'xtls-rprx-vision'}],
            'decryption': 'none'
        },
        'streamSettings': {
            'network': 'tcp',
            'security': 'reality',
            'realitySettings': {
                'show': False,
                'dest': '$REALITY_DEST',
                'xver': 0,
                'serverNames': ['$SNI'],
                'privateKey': '$PRIVATE_KEY',
                'shortIds': ['$SHORT_ID']
            },
            'sockopt': {
                'tcpFastOpen': True,
                'tcpNoDelay': True,
                'tcpKeepAliveInterval': 30,
                'mark': 255
            }
        },
        'sniffing': {
            'enabled': True,
            'destOverride': ['http', 'tls', 'quic'],
            'routeOnly': True
        }
    }],
    'outbounds': [
        {'protocol': 'freedom', 'tag': 'direct', 'settings': {'domainStrategy': 'UseIPv4v6'}},
        warp_outbound,
        {'protocol': 'blackhole', 'tag': 'block'}
    ],
    'routing': {
        'domainStrategy': 'IPIfNonMatch',
        'rules': [{
            'type': 'field',
            'outboundTag': 'warp',
            'domain': warp_domains
        }]
    }
}

json.dump(config, open('/usr/local/etc/xray/config.json', 'w'), indent=2, ensure_ascii=False)
print('Config written')
" || die "Xray 配置生成失败"

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
  info "[3/6] 配置防火墙"
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
  info "[4/6] 网络优化 (tcpfit + 补充项)"

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
  # 注意加载顺序：sysctl.d 按文件名排序，同名 key 后加载的覆盖先加载的。
  # 99-deploy-extra.conf < 99-tcpfit.conf，所以这里绝不能放 tcpfit 管着的 key。
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
      apt_install iperf3 || true
    fi
    if command -v iperf3 > /dev/null 2>&1; then
      local peer="$SWEEP_PEER"
      local best_rtt=""
      if [ -z "$peer" ]; then
        # 根据 ping 延迟自动选最近的公共节点
        local candidates="speedtest.lax12.us.leaseweb.net speedtest.sfo12.us.leaseweb.net speedtest.hkg12.hk.leaseweb.net speedtest.tyo11.jp.leaseweb.net speedtest.sin1.sg.leaseweb.net"
        local best_peer=""
        best_rtt=9999
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

# ─── 阶段 5: 系统附加项（内化自 vps99.sh 的实用部分） ────────────────────────

# 时区：只影响日志可读性，不影响 Reality（握手靠的是 NTP 授时）
setup_timezone(){
  [ "$WITH_TZ" = 1 ] || return 0
  local cur; cur=$(timedatectl show -p Timezone --value 2>/dev/null)
  [ "$cur" = "$DEPLOY_TZ" ] && { info "时区已是 $DEPLOY_TZ"; return 0; }
  timedatectl set-timezone "$DEPLOY_TZ" 2>/dev/null \
    && ok "时区: ${cur:-未知} → $DEPLOY_TZ" \
    || warn "时区设置失败（不影响代理）"
}

# zRAM 压缩交换：lz4 压内存当 swap 用，比磁盘 swap 快一个量级。
# 默认 auto：只在【没有活动 swap 且内存 ≤4GB】时部署 —— 有 swap 的机器
# （比如商家预装的）不动，避免两套 swap 优先级打架。
# swappiness 取 60-90（zRAM 语义和磁盘 swap 相反：越高越积极用压缩内存），
# 写在 99-deploy-extra.conf —— tcpfit 只在 harden --swap 时才碰 swappiness，
# 两者不会同时生效（有 zRAM 就不会跑 harden，反之亦然）。
setup_zram(){
  [ "$WITH_ZRAM" != no ] || return 0
  if [ "$WITH_ZRAM" = auto ]; then
    if swapon --show 2>/dev/null | grep -q .; then
      info "已有 swap ($(free -m | awk '/^Swap:/{print $2}')MB)，跳过 zRAM"
      return 0
    fi
    local ram; ram=$(awk '/^MemTotal:/{printf "%d",$2/1024}' /proc/meminfo)
    if [ "$ram" -gt 4096 ]; then
      info "内存 ${ram}MB 充足，跳过 zRAM"
      return 0
    fi
  fi

  apt_install zram-tools || { warn "zram-tools 安装失败（apt 锁被占用），跳过 zRAM"; return 0; }

  local ram size swp
  ram=$(awk '/^MemTotal:/{printf "%d",$2/1024}' /proc/meminfo)
  if [ "$ram" -le 1024 ]; then size="$ram";      swp=90
  else                        size=$((ram*60/100)); swp=60
  fi
  printf 'ALGO=lz4\nSIZE=%s\nPRIORITY=100\n' "$size" > /etc/default/zramswap
  systemctl enable zramswap > /dev/null 2>&1 || true
  systemctl restart zramswap > /dev/null 2>&1 \
    && ok "zRAM 已部署: ${size}MB (lz4, swappiness=$swp)" \
    || { warn "zRAM 启动失败"; return 0; }
  sysctl -qw vm.swappiness="$swp" 2>/dev/null || true
  grep -q '^vm.swappiness' /etc/sysctl.d/99-deploy-extra.conf 2>/dev/null \
    || echo "vm.swappiness = $swp" >> /etc/sysctl.d/99-deploy-extra.conf
}

# 每周定时清理：journald 保留 7 天/200MB，apt 缓存，docker dangling 镜像。
# vps99 的 vacuum-time=1s 太激进（等于清空全部日志），代理排障要看最近日志，
# 这里放宽到 7 天。docker 只清 dangling 镜像，不动用户未运行的命名镜像。
write_clean_script(){
  cat > "$CLEAN_SCRIPT" <<'CLEANEOF'
#!/bin/sh
# vless-deploy 每周清理：apt 缓存 / journald 旧日志 / docker 垃圾
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

if command -v apt-get >/dev/null 2>&1; then
  apt-get autoremove --purge -y >/dev/null 2>&1
  apt-get clean >/dev/null 2>&1
fi

if command -v journalctl >/dev/null 2>&1; then
  journalctl --rotate >/dev/null 2>&1
  journalctl --vacuum-time=7d --vacuum-size=200M >/dev/null 2>&1
fi

# docker 只在装了的时候才碰；只清 dangling 镜像和容器日志，不动命名镜像
if command -v docker >/dev/null 2>&1; then
  docker image prune -f >/dev/null 2>&1
  find /var/lib/docker/containers/ -name "*.log" -exec truncate -s 0 {} \; 2>/dev/null
fi
CLEANEOF
  chmod +x "$CLEAN_SCRIPT"
}

setup_cleanup_cron(){
  [ "$WITH_CRON" = 1 ] || return 0
  write_clean_script
  if ! command -v crontab > /dev/null 2>&1; then
    apt_install cron || { warn "cron 安装失败（apt 锁被占用），跳过定时清理"; return 0; }
  fi
  # 周一 06:06 —— 避开整点/半点，不和全互联网的 cron 撞车
  # crontab -l 在无 crontab 时返回 1，set -e 会把它当失败，用 || true 兜底
  ( crontab -l 2>/dev/null | grep -v "$CRON_MARK" || true; echo "6 6 * * 1 $CLEAN_SCRIPT # $CRON_MARK" ) | crontab -
  ok "定时清理已部署: 每周一 06:06 (journald 7d/200M + apt + docker dangling)"
}

cmd_clean(){
  write_clean_script
  info "执行系统清理…"
  local before after
  before=$(df -m / | awk 'NR==2{print $4}')
  sh "$CLEAN_SCRIPT"
  after=$(df -m / | awk 'NR==2{print $4}')
  ok "清理完成，可用空间 ${before}MB → ${after}MB（释放 $(( after - before ))MB）"
}

system_extras(){
  info "[5/6] 系统附加项"
  setup_timezone
  setup_zram
  setup_cleanup_cron
}

# ─── 阶段 6: 输出 ────────────────────────────────────────────────────────────
print_result(){
  echo
  echo "${B}════════════════════════════════════════════════════════${P}"
  echo "${B}  部署完成 (v${VERSION})${P}"
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
  printf '  %-14s %s\n' "Swap/zRAM:" "$(free -m | awk '/^Swap:/{if($2==0) print "none"; else print $2" MB"}')"
  printf '  %-14s %s\n' "时区:"      "$(timedatectl show -p Timezone --value 2>/dev/null)"
  printf '  %-14s %s\n' "定时清理:"  "$(crontab -l 2>/dev/null | grep -q "$CRON_MARK" && echo '每周一 06:06' || echo 未部署)"
  local warp_st; warp_st=$(warp-cli --accept-tos status 2>/dev/null | grep "^Status" | awk '{print $NF}')
  printf '  %-14s %s\n' "WARP:"     "${warp_st:-未安装}"
  echo
  echo "${B}── 管理命令 ──${P}"
  echo "  tcpfit status                          # 查看当前调优状态"
  echo "  tcpfit verify --peer <iperf3服务器>     # 验证端口吞吐"
  echo "  tcpfit rollback                        # 回滚所有网络优化"
  echo "  bash $0 --show-config                  # 重新打印客户端配置"
  echo "  bash $0 --clean                        # 立即清理系统垃圾"
  echo "  bash $0 --extras-only                  # 补跑 zRAM/时区/定时清理"
  echo
}

# ─── 入口 ────────────────────────────────────────────────────────────────────
[ "$SHOW_CONFIG" = 1 ] && { need_root; cmd_show_config; exit 0; }
[ "$DO_CLEAN" = 1 ]    && { need_root; cmd_clean; exit 0; }

need_root

if [ "$OPTIMIZE_ONLY" = 1 ]; then
  optimize_network
  ok "网络优化完成"
  exit 0
fi

if [ "$EXTRAS_ONLY" = 1 ]; then
  system_extras
  ok "系统附加项完成"
  exit 0
fi

install_xray
setup_warp
configure_xray
setup_firewall
optimize_network
system_extras
print_result
