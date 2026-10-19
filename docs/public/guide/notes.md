# 注意事项

- 请自行确认服务以及命令的安全性，再放到模块中应用和执行，自行对操作和处理结果负责
- Termux 服务依赖已安装的 Termux 应用，下载对应的包：
  - 如 openlist 使用 `pkg update && pkg install -y openlist`
  - 更新服务：在 Termux 使用 `pkg update && pkg upgrade -y` 更新全部，或 `pkg update && pkg install -y 服务名1 服务名2` 更新单个或多个
- 二进制服务自行从可信渠道下载使用，如 GitHub
- 所有脚本为 POSIX sh，兼容 Android `/system/bin/sh`
- 玩机有风险，请自行备份数据，防止数据丢失。代码全公开，请自行检阅后按需刷入
