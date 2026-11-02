# 二进制服务

::: danger 事先申明
本页二进制服务文件多为来源自 GitHub 仓库，或从其他可信渠道下载相关资源。配置仅供学习参考，请自行斟酌文件安全性后按需配置，对自己配置和操作结果负责。
:::

## 通用约定

- **服务命令**填入 WebUI，保存后按原样执行，不要混填。
- 服务命令默认在工作目录 `/data/media/0/Server`，即外部存储目录 `/storage/emulated/0/Server`下运行，建议用相对路径 `cd` 到服务目录，避免依赖具体绝对路径。
- 手动下载文件后自行解压放在`/storage/emulated/0/Server/xxx`对应文件夹后放入，`xxx`为自己所创建文件夹,一般创建与服务名称同名即可。可手动在文件管理器中`/data/media/0/Server/xxx`下修改二进制文件权限为可执行权限 `755`,则可去掉服务命令中的`chmod +x ./二进制文件`命令
- `--port` 或 `--data`等命令并非对所有服务均有效，具体查看相关项目文档
- **端口字段** 仅用于标识，实际监听以服务自身配置为准；并非所有端口均为服务的Web页。

## Memos 备忘录

- **介绍**：一个开源、轻量、可自托管的备忘录/碎片化记录工具
- **下载**：[usememos/memos](https://github.com/usememos/memos/releases)，下载最新 `memos_xxx_linux_arm64.tar.gz`
- **名称**：`memos`
- **端口**：`5230`
- **服务命令**：

```shell
cd memos
chmod +x ./memos
./memos --port 5230
```

## Magpie 本地AI网关路由

- **介绍**：一个本地 AI 网关，用于集中管理和无缝切换各类 AI Agent 的底层模型。
- **下载**：[yetone/magpie](https://github.com/yetone/magpie/releases/)，下载最新 `magpie-cli-android-arm64`，无需解压
  - 若需使用插件服务需使用 bun，则需下载[oven-sh/bun/](https://github.com/oven-sh/bun/releases)只最新的`bun-linux-aarch64.zip`解压放到 magpie 同一文件夹
- **名称**：`magpie`
- **端口**：`3430`
- **服务命令**：

```shell
# 进入你的目录
cd magpie
chmod +x ./magpie-cli-android-arm64
# 设置环境变量（把配置写到当前目录下的）
export HOME=$PWD
export XDG_CONFIG_HOME=$PWD/.config
export XDG_DATA_HOME=$PWD/.local/share
export XDG_CACHE_HOME=$PWD/.cache
export MAGPIE_WEB_KEY="你的16位网页登录长密码"
# 若要下载插件时需使用bun，无则去掉
chmod +x ./bun
export MAGPIE_BUN="$PWD/bun"
# 重新运行
./magpie-cli-android-arm64 web --lan --no-open
```

## 敬请期待