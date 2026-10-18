# Troubleshooting

## The installer says `TUNNEL FAILED`

Look at the tunnel log first:

```bash
tail -40 /var/log/cf-tunnel.log
```

The tunnel is healthy when you see both a line with `https://<words>.trycloudflare.com` and
`Registered tunnel connection`. If so, just run `cf-show`. The installer may simply have stopped waiting too early.

Otherwise run these checks:

```bash
curl -sS -m 8 -o /dev/null -w "api: %{http_code}\n" https://api.trycloudflare.com/
timeout 5 bash -c '</dev/tcp/region1.v2.argotunnel.com/7844' && echo "7844 open" || echo "7844 BLOCKED"
```

| Symptom | Cause | Fix |
|---------|-------|-----|
| `api: 000` | Server cannot reach Cloudflare's tunnel API | Use a server/provider without that restriction |
| `7844 BLOCKED` | Outbound TCP/UDP 7844 filtered | Allow outbound 7844 or change provider |
| `429` / `failed to request quick Tunnel` | Rate limit after many restarts | Wait 10-30 minutes, then `systemctl restart cf-tunnel` |
| Domain never appears, no errors | Slow start | Wait a minute, run `cf-show` |

## `tput: unknown terminal "xterm-ghostty"` (or similar)

Your terminal type is unknown on the server. The installer exports `TERM=xterm` itself, but you can also fix the session:

```bash
export TERM=xterm
```

Permanently: `echo 'export TERM=xterm' >> ~/.bashrc`

## The link imports but nothing loads

1. **Wait ~1 minute.** Quick Tunnels can take a moment to become reachable.
2. **Check which link works:** run `cf-show`. Use the one marked `WORKS`.
3. **Wrong IP for your ISP.** Run `scripts/cf-scan.sh` from your own device and apply a working IP with `cf-setip`.
4. **Stale link.** The hostname changes on every tunnel restart. Run `cf-show` and re-import.
5. **Allow Insecure.** Only link A needs it. If your client ignores the link's flag, enable it manually.
6. **Server logs:**
   ```bash
   journalctl -u xray -f
   journalctl -u cf-tunnel -f
   ```

## Both links say `REJECTED`

`cf-show` tests with the Cloudflare IP currently configured. Try another one:

```bash
cf-setip 104.17.1.1
```

If every IP is rejected from the server, check that the tunnel is registered (see the first section).

## I entered a website instead of an IP

The address must be a plain IPv4 such as `104.17.1.1`, not a URL, hostname, or CIDR range (`104.16.0.0/13` is a range, not an address).
Fix it without reinstalling:

```bash
cf-setip 104.17.1.1
```

## Fronting with `speedtest.net` does not work

Expected. Cloudflare rejects requests where SNI and Host belong to different zones. See
[How it works](HOW-IT-WORKS.md#link-a-vs-link-b). Use link B.

## Add more users

Edit `/usr/local/etc/xray/config.json` and add entries to the `clients` array (generate IDs with `uuidgen`), then:

```bash
systemctl restart xray
```

The helper commands only print a link for the original UUID; for extra users, copy link B and replace the UUID.

## Reinstalling

Running `install.sh` again is safe. It generates a new UUID, path and local port, and replaces the previous setup.
To start completely clean: `sudo ./uninstall.sh --purge`.
