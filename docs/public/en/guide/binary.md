# Binary Service

::: danger Disclaimer
Most binary service files on this page come from GitHub repositories or other trusted sources. The configurations are for learning reference only — evaluate the safety of the files and configurations yourself before use, and you are responsible for your own configuration and results.
:::

## General conventions

- Service commands run by default in the working directory `/data/media/0/Server`, i.e. the external storage folder `/storage/emulated/0/Server`; prefer `cd` with a relative path into the service folder instead of hardcoded absolute paths.
- After downloading, extract the files into the matching folder under `/storage/emulated/0/Server/xxx`, where `xxx` is a folder you create — usually named after the service. You can set the binary's permission to executable `755` in a file manager under `/data/media/0/Server/xxx`; if you do, the `chmod +x ./binary` line can be dropped from the service command.
- Flags like `--port` or `--data` do not work for every service — check the project's own documentation.
- **The port field is only a label** — the actual listening port is decided by the service's own configuration; not every port serves a web page.
- **Service configurations may change between versions; the examples here can therefore age or become incompatible — trust the live project and treat this page as reference only.**
- Some services need DNS resolution; enable it during SvcHub installation as needed. For SSL certificates you can use Termux's CA bundle: `pkg update && pkg install ca-certificates -y`, then prepend `export SSL_CERT_FILE=/data/data/com.termux/files/usr/etc/tls/cert.pem` to the service command, or obtain a trusted certificate yourself.
- Download files from the corresponding repository's Releases.
- If you find a service useful, consider giving its repository a Star ⭐ to support its releases.

## Memos notes app

- **About**: an open-source, lightweight, self-hostable notes / memo tool
- **Download**: [usememos/memos](https://github.com/usememos/memos) — get the latest `memos_xxx_linux_arm64.tar.gz`
- **Name**: `memos`
- **Port**: `5230`
- **Service command**:

```shell
cd memos
chmod +x ./memos
# defaults to 8081 without --port
./memos --port 5230
```

## Magpie local AI gateway

- **About**: a local AI gateway for centrally managing and seamlessly switching the underlying models of various AI agents, with plugin and auto check-in support.
- **Download**: [yetone/magpie](https://github.com/yetone/magpie) — get the latest `magpie-cli-android-arm64`; no extraction needed
  - If you need the plugin service, which requires bun, download the latest `bun-linux-aarch64.zip` from [oven-sh/bun](https://github.com/oven-sh/bun) and put the extracted `bun` in the same folder as magpie
- **Name**: `magpie`
- **Port**: `3430`
- **Service command**:

```shell
cd magpie
chmod +x ./magpie-cli-android-arm64
# set environment variables (write the config into the current folder)
export HOME=$PWD
export XDG_CONFIG_HOME=$PWD/.config
export XDG_DATA_HOME=$PWD/.local/share
export XDG_CACHE_HOME=$PWD/.cache
export MAGPIE_WEB_KEY="your-16-char-web-login-password"
# keep these two lines only if you need bun for plugins
chmod +x ./bun
export MAGPIE_BUN="$PWD/bun"
# for LAN use add --lan and configure the certificate yourself
./magpie-cli-android-arm64 web --no-open
```

## WorkBuddy2API account gateway

- **About**: wraps Tencent CodeBuddy accounts into an OpenAI-compatible multi-account API gateway, with a built-in web panel
- **Download**: [linguo2625469/workbuddy2api-panel (no longer maintained)](https://github.com/linguo2625469/workbuddy2api-panel) or its downstream fork [misakano7545/workbuddy2api-panel](https://github.com/misakano7545/workbuddy2api-panel) — get the latest `wb2api-panel-X.X.X-linux-arm64.tar.gz` (contains the `wb2api` binary and `config.example.json`)
- **Name**: `wb2api`
- **Port**: `7863`
- **Service command**:

```shell
# use Termux's CA certificate to solve login issues
export SSL_CERT_FILE=/data/data/com.termux/files/usr/etc/tls/cert.pem
cd wb2api
chmod +x ./wb2api
./wb2api
```

::: warning
**Note**: WorkBuddy2API is a reverse proxy for an unofficial client — the account may be risk-controlled or banned!!! Evaluate the risk yourself before use. The first launch generates `config.json` in the same folder (with a random `api_key`, also shown in the log). The service needs DNS: choose to mount the DNS resolver config during SvcHub installation.
:::

## Mihomo proxy core

- **About**: the Clash Meta core with multi-protocol proxying and rule-based routing, driven by config files
- **Download**: [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo) — get the latest `mihomo-android-arm64-v8-vX.X.X.gz` (gzip-compressed; extract and rename to `mihomo`; `mihomo-linux-arm64-vX.X.X.gz` also works)
- **Name**: `mihomo`
- **Port**: `9090` (external controller; the proxy port follows `mixed-port` in `config.yaml`)
- **Service command**:

```shell
cd mihomo
chmod +x ./mihomo
# use the current directory as mihomo's working dir, auto-discovering config.yaml, cache, etc.
./mihomo -d ./ 
# alternatively use -f to specify a config file
# mihomo -f config.yaml
```

## Stash personal media library

- **About**: a local media content management server with thumbnail generation, video preview, organization, tagging and metadata scraping
- **Download**: [stashapp/stash](https://github.com/stashapp/stash) — get the latest `stash-linux-arm64v8` (raw binary without suffix, about 87 MB, no extraction needed)
  - [ffbinaries/ffbinaries-prebuilt](https://github.com/ffbinaries/ffbinaries-prebuilt) — download `ffmpeg-6.1-linux-arm-64.zip` and `ffprobe-6.1-linux-arm-64.zip`, extract them into the stash folder
- **Name**: `stash`
- **Port**: `9999`
- **Service command**:

```shell
# if update checks fail, try Termux's CA certificate
export SSL_CERT_FILE=/data/data/com.termux/files/usr/etc/tls/cert.pem
export PATH=$PWD
cd stash
chmod +x ./stash-linux-arm64v8 ./ffmpeg ./ffprobe
./stash-linux-arm64v8
```

## Fast Note Sync sync server

- **About**: the self-hosted server for the Obsidian multi-device realtime sync plugin Fast Note Sync, with history, backups and REST/MCP APIs
- **Download**: [haierkeys/fast-note-sync-service](https://github.com/haierkeys/fast-note-sync-service) (a separate server repository; on the Obsidian side install the `fast-note-sync-vX.X.X.zip` plugin from [haierkeys/obsidian-fast-note-sync](https://github.com/haierkeys/obsidian-fast-note-sync), also available in the plugin marketplace) — get the latest `fast-note-sync-service-vX.X.X-linux-arm64.tar.gz`
- **Name**: `fast-note-sync-service`
- **Port**: `9000`
- **Service command**:

```shell
cd fast-note-sync-service
chmod +x ./fast-note-sync-service
./fast-note-sync-service run
```

## EasyTier mesh network

- **About**: a decentralized mesh VPN core with P2P hole punching, multi-protocol and public relay node support
- **Download**: [EasyTier/EasyTier](https://github.com/EasyTier/EasyTier) — get the latest `easytier-linux-aarch64-vX.X.X.zip` (contains the `easytier-core` core and the `easytier-cli` admin tool)
- **Name**: `easytier`
- **Port**: `11010` (TCP/UDP listener, no web page; the port is only a label and can be left empty)
- **Service command**:

Start command:

```shell
cd easytier
chmod +x ./easytier-core
# generate a config at https://gen.qtet.cn/ , or save the defaults the program generates
./easytier-core -c config.toml && sh easytier-core.sh route
```

End command:

```shell
sh easytier-core.sh clear
```

If the remote device enables subnet proxy, fill the `EXTRA_ROUTES` field in the script.

::: details Put easytier-core.sh in the same folder — click to view the full script

```shell
#!/system/bin/sh

# 用法：
# ./easytier-core.sh add     启动 easytier-core 并添加路由，然后脚本退出
# ./easytier-core.sh route    只添加路由，不启动进程
# ./easytier-core.sh clear    只清理本脚本添加的规则，不停进程
# ./easytier-core.sh stop     停止 easytier-core 并清理规则
# ./easytier-core.sh status   查看状态

ACTION="${1:-add}"

MODDIR=$(pwd)

EASYTIER="${MODDIR}/easytier-core"
CONFIG_FILE="${MODDIR}/config/public_config.toml"
LOG_FILE="${MODDIR}/easytier.log"

# 自定义路由表编号
TABLE=9001

# 远端设备开启的子网代理。192.168.31.0/24，则 EXTRA_ROUTES="192.168.31.0/24"
# 如果手机当前就在 192.168.31.0/24，脚本添加时会自动跳过，避免破坏本地局域网。
EXTRA_ROUTES=""

[ "$(id -u)" = "0" ] || {
    echo "需要 root 运行"
    exit 1
}

[ -f "$EASYTIER" ] || {
    echo "找不到：$EASYTIER"
    exit 1
}

[ -f "$CONFIG_FILE" ] || {
    echo "找不到：$CONFIG_FILE"
    exit 1
}

chmod +x "$EASYTIER" 2>/dev/null

if [ ! -e /dev/net/tun ]; then
    mkdir -p /dev/net 2>/dev/null
    ln -s /dev/tun /dev/net/tun 2>/dev/null
fi

log() {
    echo "[easytier] $(date '+%F %T') $*" >> "$LOG_FILE"
}

get_et_iface() {
    sed -n 's/^[[:space:]]*dev_name[[:space:]]*=[[:space:]]*"\{0,1\}\([^",[:space:]]*\)"\{0,1\}.*/\1/p' \
        "$CONFIG_FILE" 2>/dev/null | head -n1
}

detect_tun_iface() {
    ip -o link show 2>/dev/null | awk -F': ' '$2 ~ /^tun[0-9A-Za-z_]+$/ {print $2; exit}'
}

get_config_cidr() {
    sed -n 's/^[[:space:]]*ipv4[[:space:]]*=[[:space:]]*"\{0,1\}\([^",[:space:]]*\)"\{0,1\}.*/\1/p' \
        "$CONFIG_FILE" 2>/dev/null | head -n1
}

cidr_to_subnet() {
    CIDR="$1"
    [ -n "$CIDR" ] || return 1

    case "$CIDR" in
        */*)
            ;;
        *)
            CIDR="${CIDR}/24"
            ;;
    esac

    case "$CIDR" in
        */24)
            echo "${CIDR%.*}.0/24"
            ;;
        */16)
            echo "${CIDR%%.*}.0.0.0/16"
            ;;
        */8)
            echo "${CIDR%%.*}.0.0.0/8"
            ;;
        */32)
            echo "${CIDR%/*}/32"
            ;;
        *)
            return 1
            ;;
    esac
}

is_local_subnet() {
    SUBNET="$1"

    case "$SUBNET" in
        */24)
            PREFIX="${SUBNET%.*}"

            for addr in $(ip -4 -o addr show 2>/dev/null | awk '{print $4}'); do
                case "$addr" in
                    ${PREFIX}.*)
                        return 0
                        ;;
                esac
            done

            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

add_route_rule() {
    SUBNET="$1"
    DEV="$2"

    [ -n "$SUBNET" ] || return 0
    [ -n "$DEV" ] || return 0

    if ! ip rule show 2>/dev/null | grep -q "to ${SUBNET} lookup ${TABLE}"; then
        ip rule add to "${SUBNET}" lookup "${TABLE}" priority 100 2>/dev/null
        log "add rule: to ${SUBNET} lookup ${TABLE}"
    fi

    if ! ip route show table "${TABLE}" 2>/dev/null | grep -q "${SUBNET} dev ${DEV}"; then
        ip route replace "${SUBNET}" dev "${DEV}" table "${TABLE}" 2>/dev/null
        log "add route: ${SUBNET} dev ${DEV} table ${TABLE}"
    fi
}

ensure_routes() {
    ET_IFACE=$(get_et_iface)
    [ -n "$ET_IFACE" ] || ET_IFACE=$(detect_tun_iface)
    [ -n "$ET_IFACE" ] || return 1

    ip link show "$ET_IFACE" >/dev/null 2>&1 || return 1
    ip link set "$ET_IFACE" up 2>/dev/null

    CIDR=$(ip -4 -o addr show dev "$ET_IFACE" 2>/dev/null | awk '{print $4; exit}')
    [ -z "$CIDR" ] && CIDR=$(get_config_cidr)

    VIRTUAL_NET=$(cidr_to_subnet "$CIDR")
    if [ -n "$VIRTUAL_NET" ]; then
        add_route_rule "$VIRTUAL_NET" "$ET_IFACE"
    fi

    for r in $EXTRA_ROUTES; do
        if is_local_subnet "$r"; then
            continue
        fi
        add_route_rule "$r" "$ET_IFACE"
    done

    return 0
}

wait_and_add_routes() {
    i=0
    while [ $i -lt 20 ]; do
        if ensure_routes; then
            return 0
        fi
        sleep 1
        i=$((i+1))
    done

    return 1
}

ensure_easytier_running() {
    if pgrep -f "$EASYTIER" >/dev/null 2>&1; then
        return 0
    fi

    log "starting: $EASYTIER -c $CONFIG_FILE"

    if command -v nohup >/dev/null 2>&1; then
        nohup "$EASYTIER" -c "$CONFIG_FILE" >> "$LOG_FILE" 2>&1 &
    elif command -v setsid >/dev/null 2>&1; then
        setsid "$EASYTIER" -c "$CONFIG_FILE" >> "$LOG_FILE" 2>&1 &
    else
        "$EASYTIER" -c "$CONFIG_FILE" >> "$LOG_FILE" 2>&1 &
    fi

    sleep 2
}

get_managed_routes() {
    ROUTES=""

    ET_IFACE=$(get_et_iface)
    [ -n "$ET_IFACE" ] || ET_IFACE=$(detect_tun_iface)

    CIDR=""
    if [ -n "$ET_IFACE" ]; then
        CIDR=$(ip -4 -o addr show dev "$ET_IFACE" 2>/dev/null | awk '{print $4; exit}')
    fi

    [ -z "$CIDR" ] && CIDR=$(get_config_cidr)

    VIRTUAL_NET=$(cidr_to_subnet "$CIDR")
    [ -n "$VIRTUAL_NET" ] && ROUTES="$VIRTUAL_NET"

    for r in $EXTRA_ROUTES; do
        ROUTES="$ROUTES $r"
    done

    echo "$ROUTES"
}

clear_rules() {
    while ip rule del lookup "$TABLE" >/dev/null 2>&1; do
        :
    done

    for r in $(get_managed_routes); do
        while ip rule del to "$r" lookup "$TABLE" >/dev/null 2>&1; do
            :
        done
        ip route del "$r" table "$TABLE" >/dev/null 2>&1
    done

    ip route flush table "$TABLE" >/dev/null 2>&1

    log "rules cleared"
}

case "$ACTION" in
    add|start)
        ensure_easytier_running

        if wait_and_add_routes; then
            echo "EasyTier 已启动，规则已添加。"
            ip route show table "$TABLE" 2>/dev/null
            exit 0
        else
            echo "规则添加失败，请检查：$LOG_FILE"
            exit 1
        fi
        ;;

    route)
        if wait_and_add_routes; then
            echo "规则已添加。"
            ip route show table "$TABLE" 2>/dev/null
            exit 0
        else
            echo "规则添加失败。"
            exit 1
        fi
        ;;

    clear)
        clear_rules
        echo "规则已清理。"
        exit 0
        ;;

    stop)
        pkill -f "$EASYTIER" 2>/dev/null
        clear_rules
        echo "EasyTier 已停止，规则已清理。"
        exit 0
        ;;

    status)
        if pgrep -f "$EASYTIER" >/dev/null 2>&1; then
            echo "easytier-core: 运行中"
        else
            echo "easytier-core: 未运行"
        fi

        echo "rules:"
        ip rule show 2>/dev/null | grep "lookup ${TABLE}" || echo "  无"

        echo "routes table ${TABLE}:"
        ip route show table "$TABLE" 2>/dev/null || echo "  无"
        exit 0
        ;;

    *)
        echo "Usage: $0 [add|route|clear|stop|status]"
        exit 1
        ;;
esac
```
:::

## Syncthing file sync

- **About**: open-source multi-device realtime file sync with P2P direct connections and no public IP required, with a built-in web UI (a Termux version is also available — see [Termux Service](/en/guide/termux))
- **Download**: [syncthing/syncthing](https://github.com/syncthing/syncthing) — get the latest `syncthing-linux-arm64-vX.X.X.tar.gz`
- **Name**: `syncthing`
- **Port**: `8384` (web management UI)
- **Service command**:

```shell
cd syncthing
chmod +x ./syncthing
./syncthing --home ./
```

## OpenList file listing service

- **About**: a fork of AList that aggregates multiple cloud drives and local storage into one unified file listing service (a Termux version is also available — see [Termux Service](/en/guide/termux))
- **Download**: [OpenListTeam/OpenList](https://github.com/OpenListTeam/OpenList) — get the latest `openlist-android-arm64.tar.gz` (Android-specific build; extract to get `openlist`)
- **Name**: `openlist`
- **Port**: `5244`
- **Service command**:

```shell
cd openlist
chmod +x ./openlist
./openlist server
```

## Daidai Panel scheduled-task panel

- **About**: Daidai Panel — a lightweight scheduled-task panel built on Go + Vue3, with multi-language script hosting, subscription management and environment variables, Qinglong-compatible
- **Download**: [linzixuanzz/daidai-panel](https://github.com/linzixuanzz/daidai-panel) — get the latest `daidai-linux-arm64.tar.gz` and extract it
  - Use the Termux environment to supply python and nodejs
  - nodejs: `pkg update && pkg install nodejs`
  - python 3.12 stable: `pkg update && pkg install tur-repo -y` then `pkg update && pkg install python3.12 -y`
- **Name**: `daidai-panel`
- **Port**: `5701`
- **Service command**:

```shell
# use the python / nodejs provided by Termux
export PATH=/data/data/com.termux/files/usr/bin;
cd daidai-panel
chmod +x ./daidai-panel-arm64
./daidai-panel-arm64
```

## DDNS-Go dynamic DNS

- **About**: automatically updates dynamic public IP changes into DNS records, supporting Alibaba Cloud, Tencent Cloud, Cloudflare and more
- **Download**: [jeessy2/ddns-go](https://github.com/jeessy2/ddns-go) — get the latest `ddns-go_X.X.X_linux_arm64.tar.gz`
- **Name**: `ddns-go`
- **Port**: `9876` (web configuration UI)
- **Service command**:

```shell
cd ddns-go
chmod +x ./ddns-go
[ -f ddns_go_config.yaml ] || touch ddns_go_config.yaml
# add -skipVerify to skip certificate verification
./ddns-go -c ddns_go_config.yaml -dns 223.5.5.5 -d
```

## Beszel lightweight monitoring

- **About**: an extremely lightweight server monitoring panel (CPU / memory / disk / network), single-file deployment, with agents for multi-machine monitoring
- **Download**: [henrygd/beszel](https://github.com/henrygd/beszel) — get the latest `beszel_X.X.X_linux_arm64.tar.gz`
- **Name**: `beszel`
- **Port**: `8090`
- **Service command**:

```shell
cd beszel
chmod +x ./beszel
# if needed
./beszel serve
```

## Coming soon
