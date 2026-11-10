# 二进制服务

::: danger 事先申明
本页二进制服务文件多为来源自 GitHub 仓库，或从其他可信渠道下载相关资源。本篇配置仅供学习参考，请自行斟酌文件及配置安全性后按需配置，对自己配置和操作结果负责。
:::

## 通用约定

- 服务命令默认在工作目录 `/data/media/0/Server`，即外部存储目录 `/storage/emulated/0/Server`下运行，建议用相对路径 `cd` 到服务目录，避免依赖具体绝对路径。
- 手动下载文件后自行解压放在`/storage/emulated/0/Server/xxx`对应文件夹后放入，`xxx`为自己所创建文件夹,一般创建与服务名称同名即可。可手动在文件管理器中`/data/media/0/Server/xxx`下修改二进制文件权限为可执行权限 `755`,则可去掉服务命令中的`chmod +x ./二进制文件`命令
- `--port` 或 `--data`等命令并非对所有服务均有效，具体查看相关项目文档
- **端口字段仅用于标识** ，实际监听以服务自身配置为准；并非所有端口均为服务的 Web 页
- **部分服务配置可能会随版本更新而改变，配置因此可能会有时效性、兼容性问题，以实际情况为准，本篇仅作参考**
- 部分服务需要 DNS 解析，安装 SvcHub 时按需开启，若需 SSL 证书可使用 Termux 的CA证书 `pkg update && pkg install ca-certificates -y`，服务命令前加`export SSL_CERT_FILE=/data/data/com.termux/files/usr/etc/tls/cert.pem`，或自行获取可信的证书
- 下载文件前往对应仓库的 Release 中下载
- 若觉得服务好用也可以为他们仓库点点 Star ⭐， 助力更新发版

## Memos 备忘录

- **介绍**：一个开源、轻量、可自托管的备忘录/碎片化记录工具
- **下载**：[usememos/memos](https://github.com/usememos/memos)，下载最新 `memos_xxx_linux_arm64.tar.gz`
- **名称**：`memos`
- **端口**：`5230`
- **服务命令**：

```shell
cd memos
chmod +x ./memos
# 无 --port 参数时默认8081
./memos --port 5230
```

## Magpie 本地 AI 网关路由

- **介绍**：一个本地 AI 网关，用于集中管理和无缝切换各类 AI Agent 的底层模型，且支持插件、自动签到。
- **下载**：[yetone/magpie](https://github.com/yetone/magpie)，下载最新 `magpie-cli-android-arm64`，无需解压
  - 若需使用插件服务需使用 bun，则需下载[oven-sh/bun/](https://github.com/oven-sh/bun) 下载最新的`bun-linux-aarch64.zip`解压放到 magpie 同一文件夹
- **名称**：`magpie`
- **端口**：`3430`
- **服务命令**：

```shell
cd magpie
chmod +x ./magpie-cli-android-arm64
# 设置环境变量（把配置写到当前目录下的）
export HOME=$PWD
export XDG_CONFIG_HOME=$PWD/.config
export XDG_DATA_HOME=$PWD/.local/share
export XDG_CACHE_HOME=$PWD/.cache
export MAGPIE_WEB_KEY="你的16位网页登录长密码"
# 若要下载插件时需使用bun，无则去掉这两行
chmod +x ./bun
export MAGPIE_BUN="$PWD/bun"
# 若需局域网使用加 --lan 参数并自行配置证书
./magpie-cli-android-arm64 web --no-open
```

## WorkBuddy2API 网关面板

- **介绍**：把腾讯 CodeBuddy 账号包装为 OpenAI 兼容 API 的多账号网关，自带 Web 管理面板
- **下载**：[linguo2625469/workbuddy2api-panel 已停更](https://github.com/linguo2625469/workbuddy2api-panel) 或使用其Fork下游[misakano7545/workbuddy2api-panel](https://github.com/misakano7545/workbuddy2api-panel)，下载最新 `wb2api-panel-X.X.X-linux-arm64.tar.gz`（内含 `wb2api` 二进制与 `config.example.json`）
- **名称**：`wb2api`
- **端口**：`7863`
- **服务命令**：

```shell
# 使用 Termux 的CA证书解决登录问题
export SSL_CERT_FILE=/data/data/com.termux/files/usr/etc/tls/cert.pem
cd wb2api
chmod +x ./wb2api
./wb2api
```

::: warning
**注意**：WorkBuddy2API 所属反代，因使用非官方客户端肯可能导致账号风控 / 封禁 ！！！请自行评估风险使用。首次启动会在同目录自动生成 `config.json`（含随机 `api_key`）日志中亦会展示。服务所需DNS配置，SvcHub 安装选择挂载 dns 解析配置
:::

## Mihomo 代理内核

- **介绍**：Clash Meta 内核，支持多协议代理与规则路由，配置文件驱动
- **下载**：[MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo)，下载最新 `mihomo-android-arm64-v8-vX.X.X.gz`（gzip 压缩，解压后重命名为 `mihomo`；另有 `mihomo-linux-arm64-vX.X.X.gz` 可用）
- **名称**：`mihomo`
- **端口**：`9090`（外部控制器；代理端口以 `config.yaml` 的 `mixed-port` 为准）
- **服务命令**：

```shell
cd mihomo
chmod +x ./mihomo
# 设置当前为mihomo的工作目录，自动查找 config.yaml、缓存等文件
./mihomo -d ./ 
# 亦可使用 -f 指定配置文件
# mihomo -f config.yaml
```

## Stash 个人媒体库

- **介绍**：本地媒体内容管理服务器，支持生成缩略图、视频预览、整理、标记与元数据刮削
- **下载**：[stashapp/stash](https://github.com/stashapp/stash)，下载最新 `stash-linux-arm64v8`（无后缀的原始二进制，约 87MB，无需解压）
  - [ffbinaries/ffbinaries-prebuilt](https://github.com/ffbinaries/ffbinaries-prebuilt)，下载`ffmpeg-6.1-linux-arm-64.zip`和`ffprobe-6.1-linux-arm-64.zip` 解压放入stash文件夹
- **名称**：`stash`
- **端口**：`9999`
- **服务命令**：  

```shell
# 若无法检查更新，可尝试使用 Termux 的CA证书
export SSL_CERT_FILE=/data/data/com.termux/files/usr/etc/tls/cert.pem
export PATH=$PWD
cd stash
chmod +x ./stash-linux-arm64v8 ./ffmpeg ./ffprobe
./stash-linux-arm64v8
```



## Fast Note Sync 笔记同步服务端

- **介绍**：Obsidian 多端实时同步插件 Fast Note Sync 的私有部署服务端，支持历史版本、备份与 REST/MCP 接口
- **下载**：[haierkeys/fast-note-sync-service](https://github.com/haierkeys/fast-note-sync-service)（服务端独立仓库；Obsidian 端装 [haierkeys/obsidian-fast-note-sync](https://github.com/haierkeys/obsidian-fast-note-sync) 的 `fast-note-sync-vX.X.X.zip` 插件，亦可在插件市场安装），下载最新 `fast-note-sync-service-vX.X.X-linux-arm64.tar.gz`
- **名称**：`fast-note-sync-service`
- **端口**：`9000`
- **服务命令**：

```shell
cd fast-note-sync-service
chmod +x ./fast-note-sync-service
./fast-note-sync-service run
```

## EasyTier 异地组网

- **介绍**：去中心化 Mesh VPN 内核，P2P 打洞组建虚拟局域网，支持多协议与公共中继节点
- **下载**：[EasyTier/EasyTier](https://github.com/EasyTier/EasyTier)，下载最新 `easytier-linux-aarch64-vX.X.X.zip`（内含 `easytier-core` 内核与 `easytier-cli` 管理工具）
- **名称**：`easytier`
- **端口**：`11010`（TCP/UDP 监听，无 Web 页，端口仅作标识，也可不填）
- **服务命令**：

启动命令填

```shell
cd easytier
chmod +x ./easytier-core
# 配置文件生成可用 https://gen.qtet.cn/ ，或使用程序默认生成再保存
./easytier-core -c config.toml && sh easytier-core.sh route
```

结尾命令填

```shell
sh easytier-core.sh clear
```

若运程设备开启子网代理在在脚本中填写`EXTRA_ROUTES`字段

::: details easytier-core.sh 放同文件夹下，点击查看完整脚本代码

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



## Syncthing 文件同步

- **介绍**：开源多端文件实时同步，P2P 直连、无需公网 IP，自带 Web 管理界面 （也可用 Termux 版，见 [Termux 服务](/guide/termux)）
- **下载**：[syncthing/syncthing](https://github.com/syncthing/syncthing)，下载最新 `syncthing-linux-arm64-vX.X.X.tar.gz`
- **名称**：`syncthing`
- **端口**：`8384`（Web 管理界面）
- **服务命令**：

```shell
cd syncthing
chmod +x ./syncthing
./syncthing --home ./
```

## OpenList 网盘服务

- **介绍**：AList 的分支，把多家网盘与本地存储聚合为一个统一文件列表服务（也可用 Termux 版，见 [Termux 服务](/guide/termux)）
- **下载**：[OpenListTeam/OpenList](https://github.com/OpenListTeam/OpenList)，下载最新 `openlist-android-arm64.tar.gz`（Android 专用构建，解压得 `openlist`）
- **名称**：`openlist`
- **端口**：`5244`
- **服务命令**：

```shell
cd openlist
chmod +x ./openlist
./openlist server
```

## Daidai Panel 定时任务面板

- **介绍**：Go + Vue3 的轻量定时任务管理面板呆呆面板，多语言脚本托管、订阅管理、环境变量，兼容青龙
- **下载**：[linzixuanzz/daidai-panel](https://github.com/linzixuanzz/daidai-panel)，下载最新 `daidai-linux-arm64.tar.gz`；解压
  - 使用 termux 环境补齐 python、nodejs 环境
  - nodejs：`pkg update && pkg install nodejs`
  - python 3.12 稳定版本：`pkg update && pkg install tur-repo -y` 再 `pkg update && pkg install python3.12 -y`
- **名称**：`daidai-panel`
- **端口**：`5701`
- **服务命令**：

```shell
# 使用 Termux 所含的python、nodejs 环境
export PATH=/data/data/com.termux/files/usr/bin;
cd daidai-panel
chmod +x ./daidai-panel-arm64
./daidai-panel-arm64
```

## DDNS-Go 动态域名

- **介绍**：自动把动态公网 IP 更新到域名解析记录，支持阿里云、腾讯云、Cloudflare 等多家服务商
- **下载**：[jeessy2/ddns-go](https://github.com/jeessy2/ddns-go)，下载最新 `ddns-go_X.X.X_linux_arm64.tar.gz`
- **名称**：`ddns-go`
- **端口**：`9876`（Web 配置界面）
- **服务命令**：

```shell
cd ddns-go
chmod +x ./ddns-go
[ -f ddns_go_config.yaml ] || touch ddns_go_config.yaml
# 若需跳过证书验证添加 -skipVerify 参数
./ddns-go -c ddns_go_config.yaml -dns 223.5.5.5 -d
```

## Beszel 轻量监控面板

- **介绍**：极轻量的服务器监控面板（CPU/内存/磁盘/网络），单文件部署，可配 agent 监控多机
- **下载**：[henrygd/beszel](https://github.com/henrygd/beszel)，下载最新 `beszel_X.X.X_linux_arm64.tar.gz`
- **名称**：`beszel`
- **端口**：`8090`
- **服务命令**：

```shell
cd beszel
chmod +x ./beszel
# 若需
./beszel serve
```

## 敬请期待