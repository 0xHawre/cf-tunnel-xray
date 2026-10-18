#!/usr/bin/env bash
#
# cf-tunnel-xray installer
# Xray (VLESS or VMess over WebSocket) published through a Cloudflare Quick
# Tunnel (trycloudflare.com). No domain, no open inbound ports, no nginx.
#
# Usage:
#   sudo ./install.sh                         # interactive
#   sudo ./install.sh -p vmess -i 104.19.55.12 -n myconfig
#   curl -fsSL <raw-url>/install.sh | sudo bash -s -- -p vless
#
set -uo pipefail
export TERM=xterm DEBIAN_FRONTEND=noninteractive

VERSION="1.0.0"
DEFAULT_IP="104.16.1.1"
DEFAULT_FRONT="www.speedtest.net"

usage() {
  cat <<EOF
cf-tunnel-xray installer v${VERSION}

Options:
  -p, --protocol  vless | vmess            (default: vless)
  -i, --ip        Cloudflare IPv4 used as the client address (default: ${DEFAULT_IP})
  -f, --front     SNI for the "fronting" link A (default: ${DEFAULT_FRONT})
  -n, --name      Name shown in the client app  (default: CF-Tunnel)
  -h, --help      Show this help

Any option you leave out is asked interactively (when a terminal is available).
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

valid_ipv4() {
  local ip=$1 o
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -ra octets <<<"$ip"
  for o in "${octets[@]}"; do (( o <= 255 )) || return 1; done
}

# ask "Prompt" "default"  -> echoes the answer (default when empty / no tty)
ask() {
  local prompt=$1 default=$2 ans=""
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    read -rp "$prompt [$default]: " ans </dev/tty || true
  fi
  echo "${ans:-$default}"
}

PROTO="" CF_IP="" FRONT="" NAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p|--protocol) PROTO=${2:-}; shift 2 ;;
    -i|--ip)       CF_IP=${2:-}; shift 2 ;;
    -f|--front)    FRONT=${2:-}; shift 2 ;;
    -n|--name)     NAME=${2:-};  shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *) usage; die "unknown option: $1" ;;
  esac
done

[ "$EUID" -eq 0 ] || die "run as root (sudo ./install.sh)"
command -v systemctl >/dev/null || die "systemd is required"
command -v apt-get   >/dev/null || die "only Debian/Ubuntu (apt) is supported"

# --- collect settings ---------------------------------------------------------
if [ -z "$PROTO" ]; then
  PROTO=$(ask "Protocol (vless/vmess)" "vless")
fi
PROTO=$(echo "$PROTO" | tr '[:upper:]' '[:lower:]')
case "$PROTO" in vless|vmess) ;; *) die "protocol must be vless or vmess" ;; esac

if [ -z "$CF_IP" ]; then
  while true; do
    CF_IP=$(ask "Cloudflare IPv4 for the client address" "$DEFAULT_IP")
    valid_ipv4 "$CF_IP" && break
    echo "  '$CF_IP' is not a plain IPv4 address (example: 104.17.1.1)"
    [ -r /dev/tty ] || die "invalid IP"
  done
fi
valid_ipv4 "$CF_IP" || die "invalid IPv4: $CF_IP"

[ -n "$FRONT" ] || FRONT=$(ask "Fronting SNI for link A" "$DEFAULT_FRONT")
[ -n "$NAME"  ] || NAME=$(ask "Config name" "CF-Tunnel")

# --- 1. packages --------------------------------------------------------------
echo "[1/6] Installing packages..."
apt-get update -y >/dev/null 2>&1
apt-get install -y curl openssl uuid-runtime qrencode >/dev/null 2>&1 \
  || die "apt-get install failed"

# --- 2. xray ------------------------------------------------------------------
echo "[2/6] Installing Xray..."
curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh \
  -o /tmp/xray-install.sh || die "could not download the Xray installer"
bash /tmp/xray-install.sh install >/dev/null 2>&1 || true
command -v xray >/dev/null || die "Xray install failed"

# --- 3. cloudflared -----------------------------------------------------------
echo "[3/6] Installing cloudflared..."
case "$(uname -m)" in
  x86_64)  ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  armv7l)  ARCH=arm ;;
  *) die "unsupported CPU architecture: $(uname -m)" ;;
esac
systemctl stop cf-tunnel 2>/dev/null || true
curl -fsSL -o /usr/local/bin/cloudflared \
  "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}" \
  || die "cloudflared download failed"
chmod +x /usr/local/bin/cloudflared

UUID=$(uuidgen)
HEX=$(openssl rand -hex 6)
XPORT=$(( RANDOM % 20000 + 20000 ))

# --- 4. xray config -----------------------------------------------------------
echo "[4/6] Writing Xray config..."
if [ "$PROTO" = "vless" ]; then
  CLIENTS="\"clients\": [ { \"id\": \"${UUID}\" } ], \"decryption\": \"none\""
else
  CLIENTS="\"clients\": [ { \"id\": \"${UUID}\" } ]"
fi

mkdir -p /usr/local/etc/xray
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "127.0.0.1",
    "port": ${XPORT},
    "protocol": "${PROTO}",
    "settings": { ${CLIENTS} },
    "streamSettings": {
      "network": "ws",
      "wsSettings": { "path": "/${HEX}" }
    }
  }],
  "outbounds": [
    { "protocol": "freedom",   "tag": "direct" },
    { "protocol": "blackhole", "tag": "block"  }
  ]
}
EOF

umask 077
cat > /etc/xray-cf.env <<EOF
PROTO=${PROTO}
UUID=${UUID}
HEX=${HEX}
CF_IP=${CF_IP}
NAME=${NAME}
FRONT=${FRONT}
EOF
umask 022

# --- 5. service + helper commands --------------------------------------------
echo "[5/6] Creating tunnel service and helper commands..."
cat > /etc/systemd/system/cf-tunnel.service <<EOF
[Unit]
Description=Cloudflare Quick Tunnel (cf-tunnel-xray)
After=network-online.target xray.service
Wants=network-online.target

[Service]
ExecStartPre=/bin/sh -c ': > /var/log/cf-tunnel.log'
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate --protocol http2 --edge-ip-version 4 --url http://127.0.0.1:${XPORT}
StandardOutput=append:/var/log/cf-tunnel.log
StandardError=append:/var/log/cf-tunnel.log
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# cf-link [A|B] : print one share link
cat > /usr/local/bin/cf-link <<'EOF'
#!/usr/bin/env bash
# usage: cf-link [A|B]
#   A = fronting link (SNI = FRONT)          - often rejected by Cloudflare
#   B = normal link   (SNI = tunnel domain)  - the one that normally works
source /etc/xray-cf.env
D=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /var/log/cf-tunnel.log 2>/dev/null \
    | tail -1 | sed 's#https://##')
[ -n "$D" ] || { echo "Tunnel domain not ready: tail -20 /var/log/cf-tunnel.log" >&2; exit 1; }
M=${1:-B}
if [ "$M" = "A" ]; then SNI=$FRONT; INS=1; TAG="${NAME}-front"
else                    SNI=$D;     INS=0; TAG="${NAME}"; fi
if [ "$PROTO" = "vless" ]; then
  echo "vless://${UUID}@${CF_IP}:443?encryption=none&security=tls&sni=${SNI}&fp=chrome&alpn=http%2F1.1&allowInsecure=${INS}&type=ws&host=${D}&path=%2F${HEX}#${TAG}"
else
  J="{\"v\":\"2\",\"ps\":\"${TAG}\",\"add\":\"${CF_IP}\",\"port\":\"443\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${D}\",\"path\":\"/${HEX}\",\"tls\":\"tls\",\"sni\":\"${SNI}\",\"alpn\":\"http/1.1\",\"fp\":\"chrome\",\"allowInsecure\":${INS}}"
  echo "vmess://$(printf '%s' "$J" | base64 -w0)"
fi
EOF

# cf-show : print both links + QR codes and test which one Cloudflare accepts
cat > /usr/local/bin/cf-show <<'EOF'
#!/usr/bin/env bash
# Prints link A and B with QR codes and tests which one Cloudflare accepts.
source /etc/xray-cf.env
D=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /var/log/cf-tunnel.log 2>/dev/null \
    | tail -1 | sed 's#https://##')
[ -n "$D" ] || { echo "Tunnel domain not ready: tail -20 /var/log/cf-tunnel.log"; exit 1; }

test_mode() { # $1 = SNI to present to Cloudflare
  curl -sk -o /dev/null -m 8 --resolve "$1:443:${CF_IP}" -H "Host: ${D}" \
    -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Version: 13" \
    -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
    -w '%{http_code}' "https://$1/${HEX}" 2>/dev/null
}

for M in A B; do
  if [ "$M" = "A" ]; then SNI=$FRONT; else SNI=$D; fi
  CODE=$(test_mode "$SNI")
  case "$CODE" in
    101|400|426) R="WORKS (code $CODE)" ;;
    *)           R="REJECTED by Cloudflare (code ${CODE:-none})" ;;
  esac
  L=$(cf-link "$M")
  echo; echo "=========== LINK $M  [SNI=$SNI]  -> $R ==========="
  echo "$L"; echo
  qrencode -t ansiutf8 "$L"
  qrencode -o "/root/qr-$M.png" -s 8 "$L"
  echo "$L" > "/root/link-$M.txt"
done
echo
echo "PNG QR codes: /root/qr-A.png /root/qr-B.png | links: /root/link-A.txt /root/link-B.txt"
echo "Use the link marked WORKS. Reprint anytime: cf-show"
EOF

# cf-setip <ip> : change the Cloudflare IP used in the links
cat > /usr/local/bin/cf-setip <<'EOF'
#!/usr/bin/env bash
ip=${1:-}
if [[ ! $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "Usage: cf-setip 104.19.55.12"; exit 1
fi
IFS=. read -ra o <<<"$ip"
for x in "${o[@]}"; do (( x <= 255 )) || { echo "Invalid IPv4"; exit 1; }; done
sed -i "s/^CF_IP=.*/CF_IP=$ip/" /etc/xray-cf.env && cf-show
EOF

chmod +x /usr/local/bin/cf-link /usr/local/bin/cf-show /usr/local/bin/cf-setip

# --- 6. start -----------------------------------------------------------------
echo "[6/6] Starting services..."
systemctl daemon-reload
systemctl enable xray       >/dev/null 2>&1; systemctl restart xray
systemctl enable cf-tunnel  >/dev/null 2>&1; systemctl restart cf-tunnel

echo "Waiting for Cloudflare to hand out your domain (up to 120s)..."
for _ in $(seq 1 120); do
  if grep -qE 'https://[a-z0-9-]+\.trycloudflare\.com' /var/log/cf-tunnel.log 2>/dev/null \
     && grep -q 'Registered tunnel connection' /var/log/cf-tunnel.log 2>/dev/null; then
    break
  fi
  sleep 1
done
sleep 5

if ! cf-show; then
  echo
  echo "TUNNEL FAILED. Last log lines:"
  tail -20 /var/log/cf-tunnel.log
  echo
  echo "See docs/TROUBLESHOOTING.md"
  exit 1
fi
