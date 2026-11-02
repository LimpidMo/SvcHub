# Binary Service

::: danger Disclaimer
Most binary files on this page are downloaded from GitHub repositories or other trusted sources. The configurations are for learning reference only — verify file safety yourself before use, and you are responsible for your own configuration and results.
:::

## General conventions

- **Service commands** go into the WebUI and run exactly as saved — do not mix them with shell commands run elsewhere.
- Service commands run in the working directory `/data/media/0/Server` (i.e. the external storage folder `/storage/emulated/0/Server`) by default; prefer `cd` with a relative path into the service folder instead of hardcoded absolute paths.
- After downloading and extracting manually, put the files into `/storage/emulated/0/Server/xxx`, where `xxx` is a folder you create — usually named after the service. You can set the binary's permission to executable `755` right in the file manager under `/data/media/0/Server/xxx`; if you do, the `chmod +x ./binary` line can be dropped from the service command.
- Flags like `--port` or `--data` do not work for every service — check the project's own documentation.
- The **port field** is only a label; the actual listening port is decided by the service's own config. Not every port serves a web page.

## Memos notes app

- **About**: an open-source, lightweight, self-hostable notes / memo tool
- **Download**: [usememos/memos](https://github.com/usememos/memos/releases) — get the latest `memos_xxx_linux_arm64.tar.gz`
- **Name**: `memos`
- **Port**: `5230`
- **Service command**:

```shell
cd memos
chmod +x ./memos
./memos --port 5230
```

## Magpie local AI gateway

- **About**: a local AI gateway for centrally managing and seamlessly switching the underlying models of various AI agents.
- **Download**: [yetone/magpie](https://github.com/yetone/magpie/releases/) — get the latest `magpie-cli-android-arm64`; no extraction needed
  - If you need the plugin service, which requires bun, download the latest `bun-linux-aarch64.zip` from [oven-sh/bun/](https://github.com/oven-sh/bun/releases) and put the extracted `bun` in the same folder as magpie
- **Name**: `magpie`
- **Port**: `3430`
- **Service command**:

```shell
# enter your folder
cd magpie
chmod +x ./magpie-cli-android-arm64
# set environment variables (write config into the current folder)
export HOME=$PWD
export XDG_CONFIG_HOME=$PWD/.config
export XDG_DATA_HOME=$PWD/.local/share
export XDG_CACHE_HOME=$PWD/.cache
export MAGPIE_WEB_KEY="your-16-char-web-login-password"
# keep these two lines only if you need bun for plugins
chmod +x ./bun
export MAGPIE_BUN="$PWD/bun"
# run
./magpie-cli-android-arm64 web --lan --no-open
```
