# 简介

SvcHub 是一个 KernelSU / Magisk / APatch 通用 Root 模块，用于**开机自启与保活两类服务**（Termux 服务 + 二进制服务），并提供 WebUI 聚合管理。

初衷就是为了裸核运行一些服务，省得一个服务装一个模块，聚合管理服务。

## 两类服务

| | Termux 服务 | 二进制服务 |
|---|---|---|
| 运行环境 | Termux 环境 | 系统 root 环境 |
| 运行身份 | Termux 用户，可单独开启「root 运行」 | root 用户 |
| 工作目录 | `/data/data/com.termux/files/home` | 可配置，默认 `/data/media/0/Server` |

> 注：启动 Termux 中的服务不会启动 Termux 后台，无需自启动软件挂后台。

## 界面概览

| 服务状态 | 服务配置 | 功能设置 |
|---------|---------|---------|
| ![服务状态](../images/01-status.png) | ![服务配置](../images/02-config.png) | ![功能设置](../images/03-settings.png) |
| 启停功能 | 服务日志页 | 网页登录页 |
| ![启停功能](../images/04-start_stop.png) | ![服务日志页](../images/05-log.png) | ![网页登录页](../images/06-login.png) |

## 快速开始

1. 在 [Releases](https://github.com/LimpidMo/SvcHub/releases/) 下载模块 ZIP
2. 在 Root 管理器中 → 模块 → 从本地安装，选择对应 ZIP 文件刷入；音量键可选是否挂载 DNS 解析配置，默认不挂载
3. 安装完成后重启设备，升级时自动保留已有配置
4. 在 KernelSU 或 APatch 等管理器 → 模块 → 点击打开 SvcHub → 进入 WebUI，页面可左右滑动查看

> Magisk 用户无管理器 WebUI 入口，开启外部访问（默认开启）后浏览器访问 `http://127.0.0.1:5555`，默认密码 `admin`。

两类服务的配置说明见 [Termux 服务](/guide/termux) 与 [二进制服务](/guide/binary)，完整示例见 [服务配置示例](/guide/examples)。

更多功能细节见 [启停功能](/guide/features)、[巡检保活](/guide/keepalive)、使用前必读见 [注意事项](/guide/notes)。
