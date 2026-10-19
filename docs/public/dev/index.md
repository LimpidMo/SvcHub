# 本地开发联调

电脑浏览器直接调 WebUI，脚本在固定沙盒 `.mock-sandbox/` 里真实执行，不需要真机、不碰仓库 `config/`。

```powershell
node tools/mock-server.js          # 启动联调桥 → http://127.0.0.1:8090
node tools/mock-server.js stop     # 停桥 + 清理沙盒服务
node tools/mock-server.js reset    # 恢复出厂配置：删沙盒 config/run/log 重建示例
node tools/mock-server.js reflash  # 改脚本后热更新文件
```

- Wi-Fi 模拟：`curl "http://127.0.0.1:8090/__wifi?state=on&ssid=Home"`
  - 冷启动可带参数：`node tools/mock-server.js --wifi on --ssid Home`
- 亮屏锁屏模拟：`curl "http://127.0.0.1:8090/__screen?screen=off&lock=lock"`
  - 其参数还可为 `screen=on&lock=lock` 亮屏未解锁，或 `screen=on&lock=unlock` 亮屏已解锁
- shell 命令依赖 Git Bash（mock-server 自动探测安装路径，尽量配置系统环境变量）
