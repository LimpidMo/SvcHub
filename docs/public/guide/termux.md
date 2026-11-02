# Termux 服务

Termux 服务以 Termux 用户身份运行（可对单个服务开启「root 运行」），默认工作目录 `/data/data/com.termux/files/home`；启动服务不会拉起 Termux 后台，无需自启动软件挂后台。

## 通用约定

- **安装命令在 Termux 终端手动执行**
- **服务命令**填入 WebUI，保存后按原样执行，不要混填。
    - 服务命令默认在 home 下运行，建议用相对路径 `cd` 到服务目录，避免依赖具体绝对路径。
    - 本配置页参考多为创建服务配置文件夹，防止服务配置文件散乱在Termux的home目录下，亦可自行去掉如`mkdir -p openlist && cd openlist`，即可填在 termux 内启动时相同命令
- **端口字段**仅用于标识，实际监听以服务自身配置为准；并非所有端口均为服务的Web页。
- 端口冲突自查：`ss -ltnp | grep <端口>`。

## OpenList 网盘服务

- **介绍**：OpenList 是 AList 的分支，把多家网盘与本地存储聚合为一个统一文件列表服务。
- **安装**：`pkg update && pkg install openlist`。
- **名称**：`openlist`
- **端口**：`5244`
- **服务命令**：

```shell
mkdir -p openlist && cd openlist
openlist server
```

::: warning
**注意**：首次启动后到服务日志中查找 `password` 字段，获取初始登录密码；登录后及时修改。默认端口可在 `~/openlist/data/config.json` 中调整。
:::

## Aria2 下载器

- **介绍**：轻量多协议下载工具，开启 RPC 后可用 AriaNg 等前端远程管理。
- **安装**：`pkg update && pkg install aria2`
- **名称**：`aria2`
- **端口**：`6800`
- **服务命令**：

```shell
mkdir -p aria2 && cd aria2
aria2c --enable-rpc --rpc-listen-port=6800 --rpc-secret=请替换为你自己的强密钥
```

::: warning
**注意**：示例密钥**必须**改成自己的强密钥，不要直接照抄。RPC 默认仅监听本机；需要局域网访问时再加 `--rpc-listen-all=true`，但公网暴露务必配合强密钥，并避免长期裸奔。
:::

## Cloudflared 内网穿透

- **介绍**：Cloudflare Tunnel 客户端，无需公网 IP 即可把本机服务端口暴露到公网。
- **安装**：`pkg update && pkg install cloudflared`
- **名称**：`cloudflared`
- **端口**：留空
- **服务命令**：

```shell
cloudflared tunnel run --protocol http2 --token <你的TUNNEL_TOKEN>
```
或使用token文件启动，在 cloudflared 文件夹加中创建文本文件token.txt，并填入你的token
```shell
mkdir -p cloudflared && cd cloudflared
cloudflared tunnel run --protocol http2 --token-file ./token.txt
```


::: warning
**注意**：`<你的TUNNEL_TOKEN>` 在 Cloudflare Zero Trust → Networks → Tunnels 中创建隧道后获取，需先在该隧道里配置好 Public Hostname 指向 `http://localhost:5244`（或对应服务端口）。`--protocol http2` 在长连接更稳定或默认auto。若只是临时测试，可用快速隧道：

```shell
cloudflared tunnel --url http://localhost:5244
```

快速隧道的公网 URL 会打印在 **stderr 日志**中，形如 `https://xxxx.trycloudflare.com`，到 WebUI 日志里找这一行即可；URL 随机且重启后变化。
:::

## Nginx 静态服务

- **介绍**：高性能 HTTP 服务器，可用于静态文件托管与反向代理。
- **安装**：`pkg update && pkg install nginx`
- **名称**：`nginx`
- **端口**：`8080`
- **服务命令**：

```shell
mkdir -p $PREFIX/var/run $PREFIX/var/log/nginx
nginx -g 'daemon off;'
```

::: warning
**注意**：Termux 的 nginx 默认配置会写 `$PREFIX/var/run/nginx.pid` 和 `$PREFIX/var/log/nginx/error.log`，这些目录未必预先存在，不创建会导致启动失败。默认监听 8080；改端口或站点请编辑 `$PREFIX/etc/nginx/nginx.conf`，并把 WebUI 端口字段同步改掉。
:::

## Sing-box 代理服务

- **介绍**：通用代理内核，支持多种协议与规则路由。
- **安装**：`pkg update && pkg install sing-box`。
- **名称**：`sing-box`
- **端口**：`9090`（以配置文件 dashboard 端口为准）
- **服务命令**：

```shell
mkdir -p sing-box && cd sing-box
sing-box run -c config.json
```

::: warning
**注意**：先把配置文件放到 `~/sing-box/config.json`，可用 `sing-box check -c config.json` 先校验语法。需要 TUN 模式时，请开启该服务的「root 运行」，并确认 root 对 `~/sing-box/config.json` 可读，非 root 无法创建 TUN 设备。
:::

## 敬请期待