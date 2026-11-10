# Termux Service

Termux services run as the Termux user (with an optional per-service "run as root" switch), with the working directory `/data/data/com.termux/files/home`. Starting a service does not launch the Termux background app — no autostart helper is needed.

## General conventions

- **Run install commands manually in the Termux terminal**: SELinux policy and network-group isolation make cross-environment calls easy to break networking — alternatively keep Termux open in the background and run the command from SvcHub.
- **Service commands**:
    - Service commands run under the home directory by default; prefer `cd` with a relative path into the service folder instead of hardcoded absolute paths.
    - The examples here create a dedicated folder per service so config files do not scatter across the Termux home directory. You can drop the `mkdir -p xxx && cd xxx` part and use exactly the command you would run inside Termux.
- **Port field**: a label only — the actual listening port is decided by the service's own config. Not every port serves a web page.
- **Port conflict check**: `ss -ltnp | grep <port>`.
- **Service updates**:
    - Update everything: `pkg update && pkg upgrade -y` (`-y` auto-confirms)
    - Update one or more: `pkg update && pkg install package1 package2`

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
**Note**: On first launch, find the `password` field in the service log for the initial login password, and change it right away. The config file can be adjusted in `~/openlist/data/config.json`.
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

## Sub-Store subscription manager

- **About**: an advanced subscription manager that merges, filters, de-duplicates, sorts and converts subscriptions from multiple providers (Clash / Surge / Loon and more), with a built-in Web UI and locally stored data.
- **Install**: run the following install commands in Termux
    - Create the folder: `mkdir -p sub-store`
    - Download tools: `pkg update && pkg install wget`
    - Frontend (optional): `wget https://github.com/sub-store-org/Sub-Store-Front-End/releases/latest/download/dist.zip && unzip dist.zip && rm dist.zip && mv dist frontend`
    - Backend: `wget https://github.com/sub-store-org/Sub-Store/releases/latest/download/sub-store.bundle.js`
- **Name**: `sub-store`
- **Port**: `3001` (Web frontend; the backend API defaults to 3000 — enable merged-port mode to expose a single port)
- **Service command**:

```shell
export SUB_STORE_DATA_BASE_PATH="$HOME/sub-store"
export SUB_STORE_FRONTEND_PATH="$SUB_STORE_DATA_BASE_PATH/frontend"
# for LAN access, change 127.0.0.1 below to 0.0.0.0
export SUB_STORE_BACKEND_API_HOST="127.0.0.1"
export SUB_STORE_BACKEND_API_PORT="3000"
export SUB_STORE_FRONTEND_HOST="$SUB_STORE_BACKEND_API_HOST"
export SUB_STORE_FRONTEND_PORT="3001"

export SUB_STORE_PUSH_SERVICE=""
# if the frontend is not installed, the official UI also works — leave this default
export SUB_STORE_CORS_ALLOWED_ORIGINS="https://sub-store.vercel.app,http://127.0.0.1:3000,http://127.0.0.1:3001"
export SUB_STORE_FRONTEND_BACKEND_PATH="/"
cd sub-store
node sub-store.bundle.js
```
> After opening the frontend, fill in the backend address `http://127.0.0.1:3000` in the backend connection dialog to start using it.

## MariaDB database

- **About**: an open-source relational database, a fork of MySQL and a high-performance alternative to it
- **Install**: `pkg update && pkg install mariadb`
- **Name**: `mariadb`
- **Port**: `3306`
- **Service command**:

```shell
mkdir -p $PREFIX/var/run/mysqld
mariadbd --datadir=$PREFIX/var/lib/mysql --socket=$PREFIX/var/run/mysqld/mysqld.sock --bind-address=127.0.0.1
```

::: warning
**Note**: initialize the data directory once in the Termux terminal with `mariadb-install-db` before starting. Run this service as the Termux user — do not enable "run as root", or the data files end up owned by the wrong user. It listens on localhost only; for LAN access change `--bind-address` to `0.0.0.0` and grant the account for the matching host. Public exposure is at your own risk.
:::

## Redis cache

- **About**: an in-memory key-value store commonly used as a cache, queue or lightweight message broker.
- **Install**: `pkg update && pkg install redis`
- **Name**: `redis`
- **Port**: `6379`
- **Service command**:

```shell
mkdir -p redis && cd redis
redis-server --port 6379 --bind 127.0.0.1 --appendonly yes
```

::: warning
**Note**: the example binds to localhost only and sets no password. Before any LAN or public use, add `--requirepass <strong-password>`, change `--bind` to the real address, and consider changing the port or adding a firewall. Persistent data lives in the current `redis/` directory — switching directories loses it.
:::

## Coming soon
