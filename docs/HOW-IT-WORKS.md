# How it works

## Components

| Part | Role |
|------|------|
| **Xray** | Proxy server. One inbound (VLESS or VMess) on `127.0.0.1:<random port>` using WebSocket transport on a random path. |
| **cloudflared** | Opens an *outbound* connection to Cloudflare and asks for a Quick Tunnel. Cloudflare answers with a random `*.trycloudflare.com` hostname that forwards to `http://127.0.0.1:<port>`. |
| **Cloudflare edge** | Terminates TLS for the `trycloudflare.com` hostname and forwards WebSocket traffic down the tunnel. |
| **Helper scripts** | `cf-show`, `cf-link`, `cf-setip` build share links from the current tunnel hostname. |

Because the tunnel is outbound-only, the server needs **no public IP exposure, no certificate and no open ports**.
TLS is handled entirely by Cloudflare.

## Traffic path

```
client ──TLS(SNI=B)──► Cloudflare IPv4 ──► Cloudflare edge ──► tunnel ──► cloudflared ──► Xray ──► internet
```

1. The client connects to a **Cloudflare IPv4 address** (the address field of the link, the "clean IP").
2. It performs a TLS handshake presenting an **SNI**, then sends an HTTP request with a **Host** header and upgrades to WebSocket on the secret path.
3. Cloudflare routes the request by the **Host** header to your tunnel.
4. `cloudflared` hands it to Xray on localhost, which unwraps VLESS/VMess and connects to the destination.

The IP in the link only decides *which Cloudflare machine you talk to*. Cloudflare routes by hostname, so any Cloudflare IP can serve your tunnel. That is why you can pick whichever IP is fastest or unblocked on your ISP.

## Anatomy of the links

VLESS:

```
vless://<UUID>@<CLOUDFLARE_IP>:443
  ?encryption=none
  &security=tls
  &sni=<SNI>
  &fp=chrome
  &alpn=http%2F1.1
  &type=ws
  &host=<tunnel-domain>
  &path=%2F<random-hex>
  #<name>
```

VMess uses the same fields packed into a base64-encoded JSON object (`add`, `port`, `id`, `net`, `host`, `path`, `tls`, `sni`, ...).

| Field | Meaning |
|-------|---------|
| address | Cloudflare IPv4 you connect to |
| `sni` | Name sent in the TLS handshake |
| `host` | HTTP Host header, **must** be your tunnel hostname so Cloudflare finds the tunnel |
| `path` | Secret WebSocket path matched by Xray |
| `alpn=http/1.1` | Needed for WebSocket |

## Link A vs link B

- **Link B (normal):** `sni = host = <tunnel-domain>`. Everything is consistent, so Cloudflare accepts it.
- **Link A (fronting):** `sni = www.speedtest.net`, `host = <tunnel-domain>`. This is *domain fronting*: the TLS layer names one site while the HTTP layer asks for another.

Cloudflare (like most large CDNs) **rejects requests whose SNI and Host belong to different zones**, so link A is normally refused. It is kept in the project because behaviour can vary by network and over time, and `cf-show` tests it for you. If it says `REJECTED`, use link B.

Link A also sets `allowInsecure=1`, because the certificate presented for the fronting SNI will not match the tunnel hostname.

## Files created on the server

| Path | Purpose |
|------|---------|
| `/usr/local/etc/xray/config.json` | Xray configuration (UUID, path, local port) |
| `/etc/xray-cf.env` | Settings used by the helper commands (mode 600) |
| `/etc/systemd/system/cf-tunnel.service` | Runs `cloudflared` and restarts it if it dies |
| `/var/log/cf-tunnel.log` | `cloudflared` output; the tunnel hostname is read from here |
| `/usr/local/bin/{cloudflared,cf-show,cf-link,cf-setip}` | Binaries and helpers |
| `/root/qr-{A,B}.png`, `/root/link-{A,B}.txt` | Generated QR codes and links |

## Why the hostname changes

A Quick Tunnel is anonymous: no account, no stable identity. Each time `cloudflared` starts, Cloudflare allocates a fresh random name. For a permanent hostname you need a Cloudflare account, your own domain, and a *named* tunnel.
