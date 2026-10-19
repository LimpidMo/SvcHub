# 服务配置示例

## Termux 服务配置

以 OpenList 为例，Termux 服务默认工作目录 `/data/data/com.termux/files/home`：

- 方案 1：**在 Termux 怎么启动就怎么填**
  - openlist 直接填写 `openlist server`，跟在 Termux 中启动 openlist 相同
- 方案 2：**建目录统一管理（防止服务文件混杂）**
  - 可自行在该目录下再创建一个 `openlist` 文件夹
  - 如 openlist 放在 `/data/data/com.termux/files/home/openlist`，则启动命令填 `cd ./openlist;openlist server`，或 `openlist server --data ./openlist/data`
- 端口填写 5244，启动后即可打开所对应服务页
- 若是首次启动 openlist，记得去日志中查看登录密码 password 字段

## 二进制服务配置

以 [Memos](https://github.com/usememos/memos) 为例，二进制服务默认工作目录 `/data/media/0/Server`，即外部存储目录 `/storage/emulated/0/Server`：

- 在 `Server` 文件夹下创建 `memos` 文件夹，将下载的 `memos_0.xx.0_linux_arm64.tar.gz` 解压获得可执行的 `memos` 放入该文件夹内
- 相关二进制文件已设置可执行权限（`chmod +x ./memos`，即将文件权限设为 `755`）。本模块不提供对二进制文件权限修改，请自行处理；并将依赖的库文件和相关资源文件与二进制放在同一目录
- 启动命令填写 `cd ./memos;./memos`：前面 `cd ./xxx` 是切换工作目录进入目录，后面 `./xxx` 是启动二进制文件
- memos 启动后默认端口 8081，也可以加 `--port 5230` 指定端口 5230，其他参数请看官方文档。将 8081 填入端口输入框中即可在服务页打开跳转
