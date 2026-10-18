#!/usr/bin/env bash
#
# Removes everything install.sh created.
#   sudo ./uninstall.sh           # remove tunnel, config, helpers
#   sudo ./uninstall.sh --purge   # also uninstall Xray itself
#
set -uo pipefail

[ "$EUID" -eq 0 ] || { echo "Run as root"; exit 1; }

echo "Stopping services..."
systemctl disable --now cf-tunnel 2>/dev/null || true
systemctl stop xray 2>/dev/null || true

echo "Removing files..."
rm -f /etc/systemd/system/cf-tunnel.service
rm -f /usr/local/bin/cloudflared /usr/local/bin/cf-link /usr/local/bin/cf-show /usr/local/bin/cf-setip
rm -f /etc/xray-cf.env /var/log/cf-tunnel.log
rm -f /usr/local/etc/xray/config.json
rm -f /root/qr-A.png /root/qr-B.png /root/link-A.txt /root/link-B.txt
systemctl daemon-reload

if [ "${1:-}" = "--purge" ]; then
  echo "Uninstalling Xray..."
  curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o /tmp/xray-install.sh \
    && bash /tmp/xray-install.sh remove --purge >/dev/null 2>&1 || true
else
  systemctl disable xray 2>/dev/null || true
  echo "Xray itself was kept. Use --purge to remove it too."
fi

echo "Done."
