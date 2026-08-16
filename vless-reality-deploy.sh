#!/usr/bin/env bash
# vless-reality-deploy — VLESS + Reality + Vision 一键部署与线路优化
#
# 一键命令（推荐）:
#   bash <(curl -fsSL https://raw.githubusercontent.com/xianggelila177/vless-reality-deploy/main/vless-reality-deploy.sh)
#
# 装完后脚本会自动复制到 /usr/local/bin/vless-deploy，以后敲 vless-deploy 即可。
#
# 子命令:
#   vless-deploy --skip-sweep      # 跳过限速器扫描（省 10-20GB 流量）
#   vless-deploy --optimize-only   # 只做网络优化，不重装 Xray
#   vless-deploy --extras-only     # 只做系统附加项（zRAM/时区/定时清理）
#   vless-deploy --clean           # 立即清理系统垃圾
#   vless-deploy --show-config     # 打印当前客户端配置
#
# 选项:
#   --bw <Mbps>         标称带宽，tcpfit 用它推导 BDP（默认 500）
#   --sweep-peer <主机> iperf3 测速对端（默认按 ping 自动选最近公共节点）
#   --port <端口>       代理监听端口（默认 443）
#   --dest <host:443>   Reality 伪装目标（默认 auto：按 RTT 自动选最近的大站）
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
#  10. 每周定时清理 journald/apt/docker 垃圾
#  11. Cloudflare WARP SOCKS5 分流（Grok/Netflix/Disney+/Hulu/Claude 走 CF 出口）
#  12. Reality SNI 自动选择：从 45 个全球大站中实测筛选（TLS1.3+H2+不跳转+低RTT）
#
# 安全说明:
#   - UUID / 密钥对 / shortId 全部在运行时由 Xray 生成，不写死在脚本里
#   - tcpfit 快照保存在 /var/lib/tcpfit/，随时可 tcpfit rollback
#   - 清理逻辑刻意不 pkill apt/dpkg —— 强杀包管理器可能损坏 dpkg 数据库
#   - Reality SNI 候选池刻意排除了 Google/Cloudflare/YouTube/Facebook 等
#     在部分国家不可用的域名，只保留全球可达的大站

set -euo pipefail

VERSION="1.3.0"

# ─── 可配置项 ────────────────────────────────────────────────────────────────
XRAY_PORT="${XRAY_PORT:-443}"
SSH_PORT="${SSH_PORT:-22}"
REALITY_DEST="${REALITY_DEST:-auto}"   # auto = 自动选择
REALITY_SNI="${REALITY_SNI:-auto}"
BANDWIDTH="${BANDWIDTH:-500}"
SWEEP_PEER="${SWEEP_PEER:-}"
DEPLOY_TZ="${DEPLOY_TZ:-Asia/Shanghai}"

SKIP_SWEEP=0
OPTIMIZE_ONLY=0
EXTRAS_ONLY=0
SHOW_CONFIG=0
DO_CLEAN=0
WITH_TZ=1
WITH_CRON=1
WITH_ZRAM=auto
WITH_WARP=1

STATE_FILE="/usr/local/etc/xray/.deploy-info"
SELF_PATH="/usr/local/bin/vless-deploy"
CLEAN_SCRIPT="/usr/local/sbin/vless-deploy-clean.sh"
CRON_MARK="vless-deploy-clean"
TCPFIT_VERSION="0.5.6"
TCPFIT_URL="https://raw.githubusercontent.com/Kylin010/tcpfit/v${TCPFIT_VERSION}/tcpfit.sh"
SCRIPT_URL="https://raw.githubusercontent.com/xianggelila177/vless-reality-deploy/v${VERSION}/vless-reality-deploy.sh"

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

apt_install(){
  local i
  for i in $(seq 1 12); do
    if ! fuser /var/lib/dpkg/lock-frontend > /dev/null 2>&1; then
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" > /dev/null 2>&1
      return $?
    fi
    [ "$i" = 1 ] && info "等待 apt/dpkg 锁释放…"
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

# ─── 自安装（curl-pipe-bash 模式） ─────────────────────────────────────────
# bash <(curl ...) 时 $0 是 /dev/fd/63，脚本一退出就没了。
# 把同一版本装到 /usr/local/bin/vless-deploy，以后想回滚/查状态还能找到。
self_install(){
  [ "$(id -u)" = 0 ] || return 0
  case "$0" in "$SELF_PATH") return 0 ;; esac
  command -v curl >/dev/null || return 0
  curl -fsSL "$SCRIPT_URL" -o "$SELF_PATH.tmp" 2>/dev/null || { rm -f "$SELF_PATH.tmp"; return 0; }
  if [ -s "$SELF_PATH.tmp" ] && head -1 "$SELF_PATH.tmp" | grep -q '^#!' \
     && grep -q "^VERSION=\"$VERSION\"" "$SELF_PATH.tmp"; then
    mv "$SELF_PATH.tmp" "$SELF_PATH"; chmod +x "$SELF_PATH"
    ok "已安装到 $SELF_PATH，以后敲 vless-deploy 即可"
  else
    rm -f "$SELF_PATH.tmp"
  fi
}

# ─── Reality SNI 自动选择 ──────────────────────────────────────────────────
# 基础池：全球知名大站，TLS1.3+H2 大概率支持，且在全球主要国家均可用。
# 刻意排除了 Google/Cloudflare/YouTube/Facebook 等在部分国家不可用的域名。
SNI_CANDIDATES="
www.amazon.com www.apple.com www.microsoft.com www.bing.com gateway.icloud.com
www.nvidia.com www.intel.com www.amd.com www.adobe.com www.oracle.com
www.ibm.com www.cisco.com www.salesforce.com www.dell.com www.hp.com
www.tesla.com www.walmart.com www.ebay.com www.costco.com www.target.com
www.samsung.com www.sony.com www.nintendo.com www.bmw.com www.volkswagen.com
www.toyota.com www.honda.com www.softbank.jp www.yahoo.co.jp www.rakuten.co.jp
www.asus.com www.tsmc.com www.lg.com www.canon.com www.fujitsu.com
www.panasonic.com www.sap.com www.siemens.com www.philips.com www.bosch.com
www.shell.com www.airbus.com www.gov.uk www.ericsson.com www.nokia.com
"

# 按 VPS 所在国家/地区补充本地大站候选。
# 只放知名企业的官网，流量画像合理。
pick_regional_sni(){
  local cc; cc=$(curl -s4 --max-time 5 ipinfo.io/country 2>/dev/null | tr -d '[:space:]')
  case "$cc" in
    JP) echo "www.nec.com www.ntt.com www.recruit.co.jp www.dmm.com www.mitsubishi.com www.bridgestone.com" ;;
    MY) echo "www.maybank.com www.maxis.com.my www.celcom.com.my www.cimb.com www.petronas.com www.airasia.com" ;;
    SG) echo "www.dbs.com www.ocbc.com www.uob.com.sg www.singtel.com www.starhub.com" ;;
    HK) echo "www.hsbc.com.hk www.hangseng.com www.cathaypacific.com www.mtr.com.hk www.hkex.com.hk" ;;
    TW) echo "www.cht.com.tw www.taiwanmobile.com www.umc.com www.mediatek.com www.foxconn.com" ;;
    KR) echo "www.samsung.com www.lg.com www.hyundai.com www.kia.com www.naver.com www.kakao.com" ;;
    DE) echo "www.sap.com www.siemens.com www.bmw.com www.volkswagen.com www.bosch.com www.basf.com" ;;
    GB|UK) echo "www.gov.uk www.bbc.com www.hsbc.com www.barclays.com www.bp.com www.vodafone.com" ;;
    FR) echo "www.orange.com www.bnpparibas.com www.airbus.com www.renault.com www.totalenergies.com" ;;
    NL) echo "www.philips.com www.shell.com www.ing.com www.klm.com www.heineken.com" ;;
    AU) echo "www.anz.com.au www.commbank.com.au www.telstra.com.au www.woolworths.com.au www.bhp.com" ;;
    CA) echo "www.rbc.com www.td.com www.scotiabank.com www.shopify.com www.aircanada.com" ;;
    IN) echo "www.reliance.com www.tcs.com www.infosys.com www.airtel.in www.icicibank.com" ;;
    BR) echo "www.petrobras.com.br www.vale.com www.embraer.com www.bancobradesco.com.br www.ambev.com.br" ;;
    US) echo "www.amazon.com www.walmart.com www.apple.com www.tesla.com www.costco.com www.dell.com" ;;
    *)  echo "" ;;
  esac
}

pick_sni(){
  [ "$REALITY_DEST" = auto ] || return 0
  info "自动选择 Reality 伪装域名（检测 TLS1.3 + H2 + 重定向 + RTT）…"

  local regional; regional=$(pick_regional_sni)
  local all="$SNI_CANDIDATES $regional"
  local cc; cc=$(curl -s4 --max-time 5 ipinfo.io/country 2>/dev/null | tr -d '[:space:]')
  [ -n "$regional" ] && info "地区: $cc, 补充候选: $(echo $regional | tr ' ' ', ')"

  local tmpd; tmpd=$(mktemp -d)
  local d
  for d in $all; do
    (
      code=$(curl -sI -o /dev/null --connect-timeout 3 --max-time 5 \
             --tlsv1.3 --tls-max 1.3 -w "%{http_code}" "https://$d/" 2>/dev/null)
      [ "$code" != "000" ] && [ -n "$code" ] || exit 1
      h2=$(curl -sI --http2 --connect-timeout 3 --max-time 5 -o /dev/null \
           -w "%{http_version}" "https://$d/" 2>/dev/null)
      [ "$h2" = "2" ] || exit 1
      loc=$(curl -sI --connect-timeout 3 --max-time 5 "https://$d/" 2>/dev/null \
            | grep -i '^location:' | head -1 | tr -d '\r')
      if [ -n "$loc" ]; then
        target=$(echo "$loc" | awk '{print $2}' | sed 's|https\?://||;s|/.*||')
        [ "$target" = "$d" ] || [ -z "$target" ] || exit 1
      fi
      times=$(curl -sI -o /dev/null --connect-timeout 3 --max-time 5 \
              -w "%{time_connect} %{time_namelookup}" "https://$d/" 2>/dev/null)
      [ -n "$times" ] || exit 1
      ms=$(awk -v c=$(echo "$times" | awk '{print $1}') -v n=$(echo "$times" | awk '{print $2}') \
           'BEGIN{printf "%d", (c-n)*1000}')
      echo "$ms $d" > "$tmpd/$d"
    ) &
  done
  wait

  local top5; top5=$(cat "$tmpd"/* 2>/dev/null | sort -n | head -5)
  if [ -n "$top5" ]; then
    echo "$top5" | while read -r ms d; do
      printf "    %4d ms  %s\n" "$ms" "$d"
    done
    local best; best=$(echo "$top5" | head -1)
    REALITY_SNI=$(echo "$best" | awk '{print $2}')
    REALITY_DEST="${REALITY_SNI}:443"
    ok "选定: $REALITY_SNI (RTT $(echo "$best" | awk '{print $1}')ms)"
  else
    REALITY_SNI="www.amazon.com"
    REALITY_DEST="www.amazon.com:443"
    warn "所有候选域名检测失败，回退到 $REALITY_SNI"
  fi
  rm -rf "$tmpd"
}


# ─── 打印客户端配置 ─────────────────────────────────────────────────────────
cmd_show_config(){
  [ -f "$STATE_FILE" ] || die "未找到部署信息，请先运行完整部署"
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
  apt_install curl unzip ufw jq python3 || die "基础依赖安装失败"

  if ! command -v xray >/dev/null 2>&1; then
    bash -c "$(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install 2>&1 | tail -3
  else
    info "Xray 已安装: $(xray version 2>&1 | head -1)"
  fi
}

# ─── 阶段 2: WARP + Xray 配置 ──────────────────────────────────────────────

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
    ok "WARP 已连接: SOCKS5 127.0.0.1:40000, 出口 ${warp_ip:-unknown} (Cloudflare)"
  else
    warn "WARP 连接失败，分流不生效（不影响代理主功能）"
  fi
}

configure_xray(){
  info "[2/6] 配置 VLESS + Reality + Vision (SNI: $REALITY_SNI)"

  if [ -f "$STATE_FILE" ]; then
    . "$STATE_FILE"
    info "复用已有密钥 (UUID: ${UUID:0:8}...)"
    # 如果 SNI 重新选了不同的，更新 state
    if [ "$SNI" != "$REALITY_SNI" ]; then
      SNI="$REALITY_SNI"
      sed -i "s|^SNI=.*|SNI=$SNI|" "$STATE_FILE"
      info "SNI 已更新: $SNI"
    fi
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
" || die "Xray 配置生成失败"

  xray -test -config /usr/local/etc/xray/config.json 2>&1 | grep -q "Configuration OK" \
    || die "Xray 配置验证失败"

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
  ok "Xray 运行在 :$PORT (VLESS + Reality + Vision, SNI=$SNI)"
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

  if [ ! -x /usr/local/bin/tcpfit ]; then
    curl -fsSL "$TCPFIT_URL" -o /usr/local/bin/tcpfit \
      || die "tcpfit 下载失败"
    chmod +x /usr/local/bin/tcpfit
    ok "tcpfit v${TCPFIT_VERSION} 已安装"
  else
    info "tcpfit 已安装: $(tcpfit version 2>&1)"
  fi

  local iface; iface=$(detect_iface)
  [ -n "$iface" ] || die "找不到默认路由网卡"
  tcpfit tune --role proxy --bw "$BANDWIDTH" 2>&1 | grep -E "^\[" || true

  cat > /etc/sysctl.d/99-deploy-extra.conf <<'EOF'
net.core.netdev_max_backlog = 250000
net.ipv4.ip_forward = 1
net.netfilter.nf_conntrack_max = 524288
net.nf_conntrack_max = 524288
EOF
  sysctl -p /etc/sysctl.d/99-deploy-extra.conf > /dev/null 2>&1 || true
  ok "补充 sysctl: backlog=250000, conntrack=524288, ip_forward=1"

  if ethtool -l "$iface" 2>/dev/null | grep -q "Combined:.*2"; then
    local cur; cur=$(ethtool -l "$iface" 2>/dev/null | awk '/^Current/{f=1} f && /Combined/{print $2}')
    if [ "$cur" = "1" ]; then
      ethtool -L "$iface" combined 2 2>/dev/null \
        && ok "virtio_net 队列: 1 → 2" \
        || warn "virtio_net 多队列设置失败（不影响使用）"
    fi
  fi

  timedatectl set-ntp true 2>/dev/null || true

  if [ "$SKIP_SWEEP" = 0 ]; then
    if ! command -v iperf3 > /dev/null 2>&1; then
      apt_install iperf3 || true
    fi
    if command -v iperf3 > /dev/null 2>&1; then
      local peer="$SWEEP_PEER" best_rtt=""
      if [ -z "$peer" ]; then
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

# ─── 阶段 5: 系统附加项 ─────────────────────────────────────────────────────

setup_timezone(){
  [ "$WITH_TZ" = 1 ] || return 0
  local cur; cur=$(timedatectl show -p Timezone --value 2>/dev/null)
  [ "$cur" = "$DEPLOY_TZ" ] && { info "时区已是 $DEPLOY_TZ"; return 0; }
  timedatectl set-timezone "$DEPLOY_TZ" 2>/dev/null \
    && ok "时区: ${cur:-未知} → $DEPLOY_TZ" \
    || warn "时区设置失败（不影响代理）"
}

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

  apt_install zram-tools || { warn "zram-tools 安装失败，跳过 zRAM"; return 0; }

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

write_clean_script(){
  cat > "$CLEAN_SCRIPT" <<'CLEANEOF'
#!/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
if command -v apt-get >/dev/null 2>&1; then
  apt-get autoremove --purge -y >/dev/null 2>&1
  apt-get clean >/dev/null 2>&1
fi
if command -v journalctl >/dev/null 2>&1; then
  journalctl --rotate >/dev/null 2>&1
  journalctl --vacuum-time=7d --vacuum-size=200M >/dev/null 2>&1
fi
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
    apt_install cron || { warn "cron 安装失败，跳过定时清理"; return 0; }
  fi
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
  echo "  vless-deploy --show-config     # 重新打印客户端配置"
  echo "  vless-deploy --clean           # 立即清理系统垃圾"
  echo "  vless-deploy --extras-only     # 补跑 zRAM/时区/定时清理"
  echo "  tcpfit status                  # 查看当前调优状态"
  echo "  tcpfit rollback                # 回滚所有网络优化"
  echo
}

# ─── 入口 ────────────────────────────────────────────────────────────────────
[ "$SHOW_CONFIG" = 1 ] && { need_root; cmd_show_config; exit 0; }
[ "$DO_CLEAN" = 1 ]    && { need_root; cmd_clean; exit 0; }

need_root
self_install
pick_sni

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
