# 本地开发联调

电脑浏览器直接调 WebUI，脚本在默认沙盒 `.mock-sandbox/modules/SvcHub` 里真实执行，不需要真机、不碰仓库 `config/`。

## 联调桥

`tools/mock-server.js`（Node 内置模块零依赖，脚本执行依赖 Git Bash）提供两条通道：

| 通道 | 地址 | 性质 |
|---|---|---|
| 管理器 | `http://127.0.0.1:8090` | 桥下发 index.html 并注入 ksu 垫片：页面同步 XHR → `POST /__exec` → 沙盒内真实执行 `sh action.sh <子命令>`（子命令过白名单） |
| 外部访问 | `http://127.0.0.1:5555` | 沙盒自起 busybox httpd + CGI，登录 / 会话 / 审计 / 锁定全真实 |

启动时执行一次沙盒的 `service.sh`：拉起 supervisor 巡检与 httpd，并生成示例配置（8 个示例服务，`webui_enabled=1`，默认密码 `admin`，首次登录强制改密）。

## 常用命令

```powershell
node tools/mock-server.js          # 启动联调桥 → http://127.0.0.1:8090
node tools/mock-server.js reflash  # 沙盒在跑→热更新脚本；不在跑→完整启动（可带 --wifi on --ssid Home）
node tools/mock-server.js stop     # 停桥 + 停全部沙盒服务（同 Ctrl+C）
node tools/mock-server.js reset    # 恢复出厂：删沙盒 config/run/log 重建示例

sh tools/check.sh                  # 快速校验：语法 + 重复函数 + lib 单测 + i18n + 打包清单
node tools/smoke.js                # 端到端冒烟：临时隔离沙盒自动清理，套件与顺序见文件头注释
```

## 模拟设备状态

写 mock 文件，supervisor 下一分片生效：

- Wi-Fi：`curl "http://127.0.0.1:8090/__wifi?state=on&ssid=Home"`
- 屏幕/锁屏：`curl "http://127.0.0.1:8090/__screen?screen=off&lock=lock"`，参数 `screen=on|off`、`lock=lock|unlock`

## 隔离实例

加 `--sandbox-root <目录> --bridge-port <端口> --web-port <端口>`（`stop`/`reflash` 同样接受），与日常联调互不干扰；`tools/smoke.js` 即用独立沙盒与独立端口。

## 注意

- 8090 无 CGI 路由：访问 `/cgi-bin/api.cgi` 一律 404，外部通道走 5555
- `reflash` 只替换文件，不重启已在运行的进程：改 `supervisor.sh`/`service.sh` 须 `stop` 再启动，改 `mock-server.js` 本身同理
- 改 `web.conf` 端口后 `reflash` 不生效（httpd 不重启，端口只在冷启动时写回）
- 直接 `sh action.sh <子命令>` 不带路径会因 `$0` 无斜杠导致 `MODDIR` 为空而 `exit 1`
- 沙盒以 `SVCHUB_MOCK=1` 绕开 dumpsys/su；验证密码请离线算哈希比对，别在登录接口试错触发锁定
