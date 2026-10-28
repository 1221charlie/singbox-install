#!/usr/bin/env bash
#=============================================================================
#  sing-box 一键部署:AnyTLS + Reality 服务端   (Debian 13 · root)
#
#  用法:
#    bash install-singbox.sh          安装 / 重新生成配置(已有密码、密钥会复用)
#    bash install-singbox.sh update   升级 sing-box(走官方 APT 源)
#    bash install-singbox.sh sni      重新扫描并更换 Reality 伪装域名
#    bash install-singbox.sh info     再次打印连接信息
#    bash install-singbox.sh regen    密码 / 密钥 / shortid / SNI 全部重新生成
#
#  可选环境变量:
#    SB_CHANNEL=stable|beta|testing   版本通道(testing = alpha);不设则沿用已装通道,全新安装为 stable
#    LISTEN_PORT=443   API_PORT=9090
#    SNI=www.example.com              手动指定伪装域名(跳过扫描)
#    NO_SCAN=1                        不扫描,直接从内置备选域名里挑
#    API_ALLOW_IP=1.2.3.4             ufw 只对该 IP 放行 API 端口(默认对所有人放行)
#=============================================================================
set -Eeuo pipefail

LISTEN_PORT="${LISTEN_PORT:-443}"
API_PORT="${API_PORT:-9090}"
SNI_FORCE="${SNI:-}"
NO_SCAN="${NO_SCAN:-0}"
API_ALLOW_IP="${API_ALLOW_IP:-}"
FORCE_REGEN=0

CONF=/etc/sing-box/config.json
STATE=/root/.sing-box-anytls.env      # 机器可读:SNI、密码、密钥等(复用 / 记录)
INFO=/root/sing-box-info.txt          # 人类可读:连接信息 + 客户端片段
SCANNER=/usr/local/bin/RealiTLScanner

SERVER_IP=""
PKG=""
SNI=""; PASSWORD=""; PRIVATE_KEY=""; PUBLIC_KEY=""; SHORT_ID=""; API_SECRET=""
ST_LISTEN_PORT=""; ST_API_PORT=""

# 扫描不到结果时的备选域名(均为大站,支持 TLS1.3 + h2),会实测后挑延迟最低的
FALLBACK_SNIS=(www.microsoft.com www.apple.com addons.mozilla.org www.asus.com
               www.amd.com www.nvidia.com www.samsung.com dl.google.com)
DOMAIN_RE='^([a-z0-9-]+\.)+[a-z][a-z0-9-]+$'

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; N=$'\e[0m'
msg()  { echo -e "${G}[+]${N} $*" >&2; }
warn() { echo -e "${Y}[!]${N} $*" >&2; }
die()  { echo -e "${R}[x]${N} $*" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
trap 'echo -e "${R}[x]${N} 脚本在第 $LINENO 行异常退出" >&2' ERR

usage() {
  cat <<'EOF'
用法: bash install-singbox.sh [install|update|sni|info|regen]
  install  安装 / 重新生成配置(默认,已有凭据会复用)
  update   升级 sing-box
  sni      重新扫描并更换 Reality 伪装域名
  info     打印连接信息
  regen    全部凭据重新生成
EOF
}

#------------------------------ 基础检查 -------------------------------------
need_root() { [ "${EUID:-$(id -u)}" -eq 0 ] || die "请使用 root 运行"; }

check_os() {
  local id ver
  id=$(. /etc/os-release && echo "${ID:-}")
  ver=$(. /etc/os-release && echo "${VERSION_ID:-}")
  [ "$id" = debian ] || die "本脚本只支持 Debian(当前: ${id:-unknown})"
  if [ "$ver" != 13 ]; then warn "脚本按 Debian 13 编写,当前为 Debian $ver,继续尝试..."; fi
  case "$(uname -m)" in x86_64|aarch64) ;; *) die "不支持的 CPU 架构: $(uname -m)";; esac
  command -v systemctl >/dev/null || die "需要 systemd"
}

pkg_installed() {
  [ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || true)" = installed ]
}

resolve_pkg() {
  local p
  if [ -n "${SB_CHANNEL:-}" ]; then
    case "$SB_CHANNEL" in
      stable)         PKG=sing-box ;;
      beta)           PKG=sing-box-beta ;;
      testing|alpha)  PKG=sing-box-testing ;;
      *) die "SB_CHANNEL 只能是 stable / beta / testing" ;;
    esac
  else
    PKG=sing-box
    for p in sing-box-testing sing-box-beta sing-box; do
      if pkg_installed "$p"; then PKG=$p; break; fi
    done
  fi
}

#------------------------------ 安装 sing-box --------------------------------
install_singbox() {
  export DEBIAN_FRONTEND=noninteractive
  msg "安装依赖..."
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates openssl iproute2 unzip tar >/dev/null

  msg "添加 sing-box 官方 APT 源(后续 apt upgrade 即可更新)..."
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL --max-time 30 https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
  chmod a+r /etc/apt/keyrings/sagernet.asc
  rm -f /etc/apt/sources.list.d/sagernet.list
  cat > /etc/apt/sources.list.d/sagernet.sources <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF
  apt-get update -qq

  local cand o
  cand=$(apt-cache policy "$PKG" | awk '/Candidate:/{print $2}')
  if [ -z "$cand" ] || [ "$cand" = "(none)" ]; then die "APT 源里找不到软件包 $PKG"; fi

  for o in sing-box sing-box-beta sing-box-testing; do
    if [ "$o" != "$PKG" ] && pkg_installed "$o"; then
      warn "移除另一通道的 $o(配置文件保留)"
      apt-get remove -y -qq "$o" >/dev/null
    fi
  done

  msg "安装 $PKG $cand ..."
  apt-get install -y -qq -o Dpkg::Options::=--force-confold "$PKG" >/dev/null
}

check_version() {
  local ver major minor
  ver=$(sing-box version 2>/dev/null | awk 'NR==1{print $3}')
  [ -n "$ver" ] || die "无法获取 sing-box 版本"
  msg "sing-box 版本: $ver ($PKG)"
  major=${ver%%.*}; minor=${ver#*.}; minor=${minor%%.*}
  if [ "$major" -lt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -lt 14 ]; }; then
    die "版本 $ver 过低:配置里的 api 服务、dns.timeout / optimistic 需要 sing-box ≥ 1.14。请加 SB_CHANNEL=beta 或 testing 重新运行"
  fi
}

#------------------------------ 公网 IP / 扫描器 ------------------------------
get_ip() {
  local u ip
  for u in https://api.ipify.org https://ipv4.icanhazip.com https://checkip.amazonaws.com https://ifconfig.me/ip; do
    ip=$(curl -4 -fsS --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]' || true)
    if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then echo "$ip"; return 0; fi
  done
  return 1
}

ip_to_cidr() {   # $1=IPv4  $2=前缀长度(≤24)
  local a b c d n mask
  IFS=. read -r a b c d <<<"$1"
  n=$(( (a << 24) | (b << 16) | (c << 8) | d ))
  mask=$(( (0xFFFFFFFF << (32 - $2)) & 0xFFFFFFFF ))
  n=$(( n & mask ))
  echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))/$2"
}

fetch_scanner() {   # 成功时输出可执行文件路径
  local pat api url f bin
  case "$(uname -m)" in
    x86_64)  pat='linux[-_.](64|amd64|x86_64|x64)' ;;
    aarch64) pat='linux[-_.](arm64|aarch64)' ;;
    *) return 1 ;;
  esac
  api=$(curl -fsS --max-time 20 https://api.github.com/repos/XTLS/RealiTLScanner/releases/latest) || return 1
  url=$(grep -oE '"browser_download_url": *"[^"]+"' <<<"$api" | cut -d'"' -f4 \
        | grep -iE "$pat" | grep -viE '\.(dgst|sha256|sha1|md5|txt|sig|asc)$' | head -n1 || true)
  [ -n "$url" ] || return 1
  f="$WORK/${url##*/}"
  curl -fsSL --max-time 180 -o "$f" "$url" || return 1
  mkdir -p "$WORK/x"
  case "$f" in
    *.zip)         unzip -qo "$f" -d "$WORK/x" ;;
    *.tar.gz|*.tgz) tar -xzf "$f" -C "$WORK/x" ;;
    *)             cp "$f" "$WORK/x/RealiTLScanner" ;;
  esac
  bin=$(find "$WORK/x" -type f -iname 'RealiTLScanner*' ! -iname '*.md' | head -n1 || true)
  [ -n "$bin" ] || return 1
  [ "$(head -c4 "$bin" | tail -c3)" = "ELF" ] || return 1
  chmod +x "$bin"
  echo "$bin"
}

install_scanner() {
  local bin
  if [ "$NO_SCAN" = 1 ]; then return 0; fi
  if [ -x "$SCANNER" ]; then return 0; fi
  msg "下载 XTLS/RealiTLScanner ..."
  bin=$(fetch_scanner) || return 1
  install -m 755 "$bin" "$SCANNER"
  msg "RealiTLScanner 已安装到 $SCANNER"
}

#------------------------------ 挑选 Reality 伪装域名 ------------------------
# 对单个域名做实测:解析 → TLS1.3 → h2 → 证书与域名匹配;输出 "分数 延迟ms 域名 IP"
# 分数: 0=解析IP与本机同 /24,1=同 /16,2=其它(越小越好,Reality 目标越"近"越自然)
verify_sni() {
  local d=$1 ip t0 t1 out sc=2
  ip=$(getent ahostsv4 "$d" 2>/dev/null | awk 'NR==1{print $1}')
  [ -n "$ip" ] || return 1
  [ "$ip" != "${SERVER_IP:-}" ] || return 1          # 不能指回自己
  t0=$(date +%s%N)
  out=$(timeout 8 openssl s_client -connect "$d:443" -servername "$d" -tls1_3 -alpn h2 \
        -verify_hostname "$d" -verify_return_error </dev/null 2>&1) || return 1
  t1=$(date +%s%N)
  grep -q 'TLSv1.3' <<<"$out" || return 1
  grep -qi 'ALPN protocol: h2' <<<"$out" || return 1
  if [ -n "${SERVER_IP:-}" ]; then
    if [ "${ip%.*}" = "${SERVER_IP%.*}" ]; then sc=0
    elif [ "${ip%.*.*}" = "${SERVER_IP%.*.*}" ]; then sc=1; fi
  fi
  echo "$sc $(( (t1 - t0) / 1000000 )) $d $ip"
}

rank_candidates() {   # 参数:域名列表;输出已排序的实测结果
  export -f verify_sni
  export SERVER_IP
  printf '%s\n' "$@" | xargs -P 8 -I{} bash -c 'verify_sni "$1"' _ {} 2>/dev/null \
    | sort -k1,1n -k2,2n || true
}

scan_candidates() {   # 输出候选域名(每行一个,靠近本机的在前)
  local p cidr csv="$WORK/scan.csv" all="" n
  warn "说明:扫描量很小(≤1024 个相邻 IP、24 线程),但部分服务商可能不喜欢 VPS 上跑扫描;介意请用 NO_SCAN=1 或 SNI=域名"
  for p in 24 22; do
    cidr=$(ip_to_cidr "$SERVER_IP" "$p")
    msg "扫描 $cidr 内支持 TLS1.3 + h2 的站点(最多约 3 分钟)..."
    rm -f "$csv"
    timeout 200 "$SCANNER" -addr "$cidr" -port 443 -thread 24 -timeout 4 -out "$csv" >/dev/null 2>&1 || true
    if [ -s "$csv" ]; then
      all+=$'\n'"$(tail -n +2 "$csv" | tr ',' '\n' | tr -d '"\r' | tr 'A-Z' 'a-z' | grep -E "$DOMAIN_RE" || true)"
    fi
    n=$(grep -cE "$DOMAIN_RE" <<<"$all" || true)
    if [ "${n:-0}" -ge 5 ]; then break; fi
  done
  grep -E "$DOMAIN_RE" <<<"$all" | awk '!s[$0]++' || true
}

choose_sni() {
  local cands=() res
  if [ -n "$SNI_FORCE" ]; then
    SNI=$SNI_FORCE
    msg "使用手动指定的 SNI: $SNI"
    if ! verify_sni "$SNI" >/dev/null; then warn "$SNI 未通过 TLS1.3 + h2 检测,请自行确认可用"; fi
    return 0
  fi

  if [ "$NO_SCAN" != 1 ] && [ -n "$SERVER_IP" ] && [ -x "$SCANNER" ]; then
    mapfile -t cands < <(scan_candidates)
  fi
  if [ "${#cands[@]}" -eq 0 ]; then
    warn "没有扫描结果,改用内置备选域名实测..."
    cands=("${FALLBACK_SNIS[@]}")
  fi
  cands=("${cands[@]:0:30}")

  msg "实测 ${#cands[@]} 个候选域名(TLS1.3 / h2 / 证书 / 延迟)..."
  res=$(rank_candidates "${cands[@]}")
  if [ -z "$res" ]; then
    warn "所有候选都未通过实测,退回 www.microsoft.com,请稍后手动确认"
    SNI=www.microsoft.com
    return 0
  fi
  msg "排名前 5(分数 延迟ms 域名 解析IP;分数 0=同/24 1=同/16 2=其它):"
  head -n 5 <<<"$res" | sed 's/^/      /' >&2
  SNI=$(awk 'NR==1{print $3}' <<<"$res")
  msg "已选定 Reality 伪装域名: ${G}${SNI}${N}"
}

#------------------------------ 凭据 / 状态 ----------------------------------
gen_secrets() {
  local kp
  kp=$(sing-box generate reality-keypair)
  PRIVATE_KEY=$(awk '/PrivateKey/{print $2}' <<<"$kp")
  PUBLIC_KEY=$(awk '/PublicKey/{print $2}' <<<"$kp")
  [ -n "$PRIVATE_KEY" ] && [ -n "$PUBLIC_KEY" ] || die "生成 Reality 密钥对失败"
  SHORT_ID=$(openssl rand -hex 8)                                       # 16 位十六进制
  PASSWORD=$(openssl rand -base64 36 | tr '+/' '-_' | tr -d '=\n')      # 48 字符 / 288 bit
  API_SECRET=$(openssl rand -hex 32)                                    # 64 位十六进制
}

save_state() {
  local v
  install -m 600 /dev/null "$STATE"
  {
    for v in SNI PASSWORD PRIVATE_KEY PUBLIC_KEY SHORT_ID API_SECRET; do
      printf '%s=%q\n' "$v" "${!v}"
    done
    printf 'ST_LISTEN_PORT=%q\nST_API_PORT=%q\n' "$LISTEN_PORT" "$API_PORT"
  } > "$STATE"
}

load_state() {
  [ -f "$STATE" ] || die "没有找到 $STATE,请先运行安装"
  # shellcheck disable=SC1090
  . "$STATE"
}

#------------------------------ 配置文件 -------------------------------------
write_config() {   # $1 = 输出路径
  cat > "$1" <<EOF
{
  "\$schema": "https://sing-box.sagernet.org/schema.json",
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "type": "udp",
        "tag": "local",
        "server": "1.1.1.1",
        "server_port": 53
      }
    ],
    "final": "local",
    "strategy": "prefer_ipv4",
    "timeout": "5s",
    "cache_capacity": 4096,
    "optimistic": {
      "enabled": true,
      "timeout": "72h0m0s"
    }
  },
  "inbounds": [
    {
      "type": "anytls",
      "tag": "Anytls-reality",
      "listen": "::",
      "listen_port": ${LISTEN_PORT},
      "tcp_fast_open": true,
      "users": [
        {
          "name": "user",
          "password": "${PASSWORD}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${SNI}",
            "server_port": 443
          },
          "private_key": "${PRIVATE_KEY}",
          "short_id": [
            "${SHORT_ID}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "urltest",
      "tag": "Urltst",
      "outbounds": [
        "direct"
      ],
      "url": "https://www.cloudflare.com/cdn-cgi/trace",
      "interval": "5m0s",
      "tolerance": 200,
      "idle_timeout": "5h0m0s",
      "interrupt_exist_connections": true
    }
  ],
  "route": {
    "rules": [
      {
        "action": "sniff",
        "sniffer": [
          "http",
          "tls",
          "quic",
          "dns"
        ]
      },
      {
        "type": "logical",
        "mode": "or",
        "rules": [
          {
            "port": 53
          },
          {
            "protocol": "dns"
          }
        ],
        "action": "hijack-dns"
      },
      {
        "ip_is_private": true,
        "outbound": "direct"
      }
    ],
    "final": "direct",
    "auto_detect_interface": true,
    "default_domain_resolver": "local"
  },
  "services": [
    {
      "type": "api",
      "tag": "api",
      "listen": "0.0.0.0",
      "listen_port": ${API_PORT},
      "secret": "${API_SECRET}",
      "dashboard": {
        "enabled": true,
        "path": "/var/lib/sing-box/dashboard"
      }
    }
  ],
  "experimental": {
    "cache_file": {
      "enabled": true,
      "path": "/var/lib/sing-box/cache.db"
    }
  }
}
EOF
}

apply_config() {
  local tmp="$WORK/config.json" out svc_user svc_group others
  write_config "$tmp"
  msg "校验配置..."
  if ! out=$(sing-box check -c "$tmp" 2>&1); then
    echo "$out" >&2
    die "配置校验失败,现有配置未被改动"
  fi
  install -d -m 0755 /etc/sing-box
  if [ -f "$CONF" ] && ! cmp -s "$tmp" "$CONF"; then
    cp -a "$CONF" "$CONF.bak.$(date +%Y%m%d-%H%M%S)"
    msg "旧配置已备份为 $CONF.bak.*"
  fi
  install -m 600 "$tmp" "$CONF"
  svc_user=$(systemctl show -p User --value sing-box 2>/dev/null || true)
  if [ -n "$svc_user" ]; then
    svc_group=$(id -gn "$svc_user" 2>/dev/null || echo "$svc_user")
    chown root:"$svc_group" "$CONF"
    chmod 640 "$CONF"
  fi
  others=$(find /etc/sing-box -maxdepth 1 -type f -name '*.json' ! -name config.json 2>/dev/null | head -n3 || true)
  if [ -n "$others" ]; then warn "/etc/sing-box 里还有其它 .json,服务可能会一并加载:$(echo $others)"; fi
  msg "配置已写入 $CONF"
}

#------------------------------ 防火墙 / 服务 --------------------------------
port_check() {
  local p line
  for p in "$LISTEN_PORT" "$API_PORT"; do
    line=$(ss -ltnpH "sport = :$p" 2>/dev/null | grep -v 'sing-box' || true)
    [ -z "$line" ] || die "TCP 端口 $p 已被其它程序占用:$line"
  done
}

setup_ufw() {
  if ! command -v ufw >/dev/null 2>&1; then
    msg "未检测到 ufw,跳过防火墙设置"
    return 0
  fi
  ufw allow "${LISTEN_PORT}/tcp" >/dev/null
  if [ -n "$API_ALLOW_IP" ]; then
    ufw allow from "$API_ALLOW_IP" to any port "$API_PORT" proto tcp >/dev/null
    msg "ufw 已放行 ${LISTEN_PORT}/tcp,以及 ${API_ALLOW_IP} → ${API_PORT}/tcp"
  else
    ufw allow "${API_PORT}/tcp" >/dev/null
    msg "ufw 已放行 ${LISTEN_PORT}/tcp 和 ${API_PORT}/tcp"
  fi
  if ufw status | grep -q '^Status: active'; then
    ufw reload >/dev/null || true
  else
    warn "ufw 当前未启用,规则已添加但暂不生效;脚本不会替你启用(避免把自己锁在 SSH 外)"
  fi
}

start_service() {
  systemctl daemon-reload
  systemctl enable sing-box >/dev/null 2>&1 || true
  systemctl restart sing-box
  sleep 3
  if ! systemctl is-active --quiet sing-box; then
    journalctl -u sing-box -n 30 --no-pager >&2 || true
    die "sing-box 启动失败,日志见上方(旧配置备份为 $CONF.bak.*)"
  fi
  if ss -ltnH "sport = :$LISTEN_PORT" | grep -q .; then
    msg "sing-box 运行中,TCP $LISTEN_PORT 已在监听"
  else
    warn "服务在运行但没看到 TCP $LISTEN_PORT 监听,请看 journalctl -u sing-box -e"
  fi
}

#------------------------------ 输出信息 -------------------------------------
render_info() {
  local host=${SERVER_IP:-你的服务器IP} port=${ST_LISTEN_PORT:-$LISTEN_PORT} api=${ST_API_PORT:-$API_PORT}
  cat <<EOF
==================== 连接信息 ====================
服务器地址    : ${host}
端口          : ${port}
协议          : AnyTLS + Reality
AnyTLS 密码   : ${PASSWORD}
伪装域名 SNI  : ${SNI}
Reality 公钥  : ${PUBLIC_KEY}
Reality 私钥  : ${PRIVATE_KEY}   (仅服务端使用,别外传)
Short ID      : ${SHORT_ID}
API 面板      : http://${host}:${api}/dashboard/
API 密钥      : ${API_SECRET}

---- 客户端 outbound(sing-box 格式)----
{
  "type": "anytls",
  "tag": "anytls-reality",
  "server": "${host}",
  "server_port": ${port},
  "password": "${PASSWORD}",
  "tls": {
    "enabled": true,
    "server_name": "${SNI}",
    "utls": { "enabled": true, "fingerprint": "chrome" },
    "reality": {
      "enabled": true,
      "public_key": "${PUBLIC_KEY}",
      "short_id": "${SHORT_ID}"
    }
  }
}

---- 管理 ----
状态: systemctl status sing-box     日志: journalctl -u sing-box -e
更新: bash install-singbox.sh update  (或 apt update && apt install --only-upgrade ${PKG:-sing-box})
换域名: bash install-singbox.sh sni
本信息已保存: ${INFO}
==================================================
EOF
}

show_info() {
  need_root
  load_state
  if [ -z "$SERVER_IP" ]; then SERVER_IP=$(get_ip || true); fi
  if [ -z "$PKG" ]; then resolve_pkg; fi
  ( umask 077; render_info > "$INFO" )
  cat "$INFO"
}

#------------------------------ 主流程 ---------------------------------------
do_install() {
  need_root
  check_os
  resolve_pkg
  install_singbox
  check_version
  if ! install_scanner; then warn "扫描器下载失败,将使用内置备选域名"; fi
  port_check

  SERVER_IP=$(get_ip || true)
  if [ -n "$SERVER_IP" ]; then msg "服务器公网 IPv4: $SERVER_IP"; else warn "未能获取公网 IPv4,跳过邻近扫描"; fi

  if [ "$FORCE_REGEN" != 1 ] && [ -f "$STATE" ]; then
    msg "检测到上次生成的凭据,复用(要全部重来请运行 regen)"
    load_state
  else
    gen_secrets
    SNI=""
  fi
  if [ -n "$SNI_FORCE" ]; then SNI=""; fi
  if [ -z "$SNI" ]; then choose_sni; fi

  save_state
  apply_config
  setup_ufw
  start_service
  show_info
}

do_sni() {
  need_root
  check_os
  command -v sing-box >/dev/null || die "尚未安装 sing-box,请先运行安装"
  load_state
  SERVER_IP=$(get_ip || true)
  if ! install_scanner; then warn "扫描器不可用,将使用内置备选域名"; fi
  SNI=""
  choose_sni
  save_state
  apply_config
  start_service
  show_info
}

do_update() {
  need_root
  check_os
  local p cur="" old new
  for p in sing-box sing-box-beta sing-box-testing; do
    if pkg_installed "$p"; then cur=$p; break; fi
  done
  [ -n "$cur" ] || die "没有找到已安装的 sing-box,请先运行安装"
  PKG=$cur
  old=$(sing-box version | awk 'NR==1{print $3}')
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --only-upgrade -o Dpkg::Options::=--force-confold "$PKG" >/dev/null
  new=$(sing-box version | awk 'NR==1{print $3}')
  if [ "$old" = "$new" ]; then msg "已是最新: $new"; else msg "sing-box $old → $new"; fi
  if [ "$NO_SCAN" != 1 ]; then rm -f "$SCANNER"; install_scanner || warn "扫描器未更新"; fi
  if ! sing-box check -c "$CONF" >/dev/null 2>&1; then
    sing-box check -c "$CONF" >&2 || true
    die "新版本下现有配置校验失败,未重启服务,请检查上面的报错"
  fi
  systemctl restart sing-box
  sleep 2
  systemctl is-active --quiet sing-box && msg "服务已重启并运行" || die "重启后服务未运行: journalctl -u sing-box -e"
}

main() {
  case "${1:-install}" in
    install) do_install ;;
    regen)   FORCE_REGEN=1; do_install ;;
    update)  do_update ;;
    sni)     do_sni ;;
    info)    show_info ;;
    -h|--help|help) usage ;;
    *) usage; exit 1 ;;
  esac
}

if [ "${SB_SOURCE_ONLY:-0}" != 1 ]; then main "$@"; fi
