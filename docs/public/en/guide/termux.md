# Termux Service

Termux services run as the Termux user (with an optional per-service "run as root" switch), with the working directory `/data/data/com.termux/files/home`. Starting a service does not launch the Termux background app — no autostart helper is needed.

## General conventions

- **Run install commands manually in the Termux terminal**
- **Service commands** go into the WebUI and run exactly as saved — do not mix the two.
    - Service commands run under the home directory by default; prefer `cd` with a relative path into the service folder instead of hardcoded absolute paths.
    - The examples here create a dedicated folder per service so config files do not scatter across the Termux home directory. You can drop the `mkdir -p xxx && cd xxx` part and use exactly the command you would run inside Termux.
- The **port field** is only a label; the actual listening port is decided by the service's own config. Not every port serves a web page.
- Check port conflicts with: `ss -ltnp | grep <port>`.

## OpenList file listing service

- **About**: OpenList is a fork of AList that aggregates multiple cloud drives and local storage into one unified file listing service.
- **Install**: `pkg update && pkg install openlist`.
- **Name**: `openlist`
- **Port**: `5244`
- **Service command**:

```shell
mkdir -p openlist && cd openlist
openlist server
```

::: warning
**Note**: On first launch, find the `password` field in the service log for the initial login password, and change it right away. The default port can be adjusted in `~/openlist/data/config.json`.
:::

## Aria2 downloader

- **About**: a lightweight multi-protocol downloader; with RPC enabled it can be managed remotely from frontends such as AriaNg.
- **Install**: `pkg update && pkg install aria2`
- **Name**: `aria2`
- **Port**: `6800`
- **Service command**:

```shell
mkdir -p aria2 && cd aria2
aria2c --enable-rpc --rpc-listen-port=6800 --rpc-secret=replace-with-your-own-strong-secret
```

::: warning
**Note**: the sample secret **must** be replaced with your own strong secret — do not copy it as-is. RPC listens on localhost only by default; add `--rpc-listen-all=true` for LAN access, but any public exposure must use a strong secret and should not stay exposed long-term.
:::

## Cloudflared tunnel

- **About**: the Cloudflare Tunnel client — expose a local service port to the internet without a public IP.
- **Install**: `pkg update && pkg install cloudflared`
- **Name**: `cloudflared`
- **Port**: leave empty
- **Service command**:

```shell
cloudflared tunnel run --protocol http2 --token <YOUR_TUNNEL_TOKEN>
```

Or start it from a token file: create a text file `token.txt` inside the `cloudflared` folder and paste your token into it.

```shell
mkdir -p cloudflared && cd cloudflared
cloudflared tunnel run --protocol http2 --token-file ./token.txt
```

::: warning
**Note**: `<YOUR_TUNNEL_TOKEN>` is obtained from Cloudflare Zero Trust → Networks → Tunnels after creating a tunnel; configure a Public Hostname in that tunnel pointing to `http://localhost:5244` (or the matching service port) first. `--protocol http2` is more stable for long-lived connections; `auto` is the default. For a quick temporary test, use a quick tunnel:

```shell
cloudflared tunnel --url http://localhost:5244
```

The public URL of a quick tunnel is printed to **stderr** — look for a line like `https://xxxx.trycloudflare.com` in the WebUI log. The URL is random and changes on restart.
:::

## Nginx static server

- **About**: a high-performance HTTP server for static file hosting and reverse proxying.
- **Install**: `pkg update && pkg install nginx`
- **Name**: `nginx`
- **Port**: `8080`
- **Service command**:

```shell
mkdir -p $PREFIX/var/run $PREFIX/var/log/nginx
nginx -g 'daemon off;'
```

::: warning
**Note**: Termux's default nginx config writes to `$PREFIX/var/run/nginx.pid` and `$PREFIX/var/log/nginx/error.log`; these directories may not exist yet, and startup fails without them. It listens on 8080 by default; edit `$PREFIX/etc/nginx/nginx.conf` to change the port or add sites, and update the WebUI port field accordingly.
:::

## Sing-box proxy service

- **About**: a universal proxy core supporting multiple protocols and rule-based routing.
- **Install**: `pkg update && pkg install sing-box`.
- **Name**: `sing-box`
- **Port**: `9090` (as configured for the dashboard)
- **Service command**:

```shell
mkdir -p sing-box && cd sing-box
sing-box run -c config.json
```

::: warning
**Note**: put your configuration at `~/sing-box/config.json` first, and validate it with `sing-box check -c config.json`. For TUN mode, enable "run as root" for this service and make sure root can read `~/sing-box/config.json` — a non-root process cannot create a TUN device.
:::
