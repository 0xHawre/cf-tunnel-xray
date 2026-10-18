#!/usr/bin/env bash
#
# cf-scan.sh - find Cloudflare IPv4 addresses that are reachable from YOUR network.
#
# Run this on your own PC / phone (Linux, macOS, WSL, Termux) - NOT on the server.
# Results only mean something from the network you will actually connect from.
#
# Usage:
#   ./cf-scan.sh <your-tunnel-domain> [count] [parallel]
#   ./cf-scan.sh calls-courage-primarily-adaptive.trycloudflare.com 80 20
#
# Prints "seconds  ip" for each reachable IP, fastest first.
#
set -uo pipefail

DOMAIN=${1:-}
COUNT=${2:-60}
PARALLEL=${3:-10}

if [ -z "$DOMAIN" ]; then
  echo "Usage: $0 <tunnel-domain> [count] [parallel]"
  echo "Get the domain on the server with: cf-show"
  exit 1
fi

# Official ranges: https://www.cloudflare.com/ips-v4  (check it occasionally)
RANGES=(
  173.245.48.0/20  103.21.244.0/22  103.22.200.0/22  103.31.4.0/22
  141.101.64.0/18  108.162.192.0/18 190.93.240.0/20  188.114.96.0/20
  197.234.240.0/22 198.41.128.0/17  162.158.0.0/15   104.16.0.0/13
  104.24.0.0/14    172.64.0.0/13    131.0.72.0/22
)

ip2int() { local a b c d; IFS=. read -r a b c d <<<"$1"; echo $(( (a<<24) + (b<<16) + (c<<8) + d )); }
int2ip() { echo "$(( ($1>>24)&255 )).$(( ($1>>16)&255 )).$(( ($1>>8)&255 )).$(( $1&255 ))"; }

random_ip() {
  local cidr=${RANGES[$(( RANDOM % ${#RANGES[@]} ))]}
  local base=${cidr%/*} bits=${cidr#*/}
  local size=$(( 1 << (32 - bits) ))
  local off=$(( ((RANDOM << 15) | RANDOM) % (size - 2) + 1 ))   # skip network/broadcast
  int2ip $(( $(ip2int "$base") + off ))
}

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

check() {
  local ip=$1 out code t
  out=$(curl -s -o /dev/null --connect-timeout 3 --max-time 5 \
        --resolve "${DOMAIN}:443:${ip}" \
        -w '%{http_code} %{time_total}' "https://${DOMAIN}/" 2>/dev/null)
  code=${out%% *}; t=${out##* }
  [ "$code" != "000" ] && [ -n "$code" ] && echo "$t $ip" >>"$tmp"
}

echo "Testing $COUNT random Cloudflare IPs against $DOMAIN ..." >&2
running=0
for _ in $(seq 1 "$COUNT"); do
  check "$(random_ip)" &
  running=$(( running + 1 ))
  if [ "$running" -ge "$PARALLEL" ]; then wait; running=0; fi
done
wait

if [ -s "$tmp" ]; then
  sort -n "$tmp" | head -15
  echo >&2
  echo "Use the fastest one on the server:  cf-setip <ip>" >&2
else
  echo "No reachable IPs found in this sample. Try a larger count." >&2
  exit 1
fi
