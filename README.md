

<div align="center">
<img src="docs/public/images/icon.png" width="150"alt="Icon"/>
<h1>SvcHub</h1>
  <a href="./README.md">中文</a> | <a href="./README.en.md">English</a> 
  
  <p>
    <b>一个 Termux / 二进制服务启动和保活的管理模块，支持多种启停策略，WebUI 聚合管理</b>
  </p>

  <p>
    <a href="https://developer.android.com">
      <img src="https://img.shields.io/badge/Platform-Android-green?style=flat-square&logo=android" alt="Platform" />
    </a>
    <a href="https://www.gnu.org/software/bash/">
      <img src="https://img.shields.io/badge/Language-Shell-green?style=flat-square&logo=gnubash&logoColor=white" alt="Shell" />
    </a>
    <a href="https://kernelsu.org">
      <img src="https://img.shields.io/badge/Root-KernelSU/Magisk/Apatch-blue?style=flat-square" alt="" />
    </a>
    <a href="https://github.com/LimpidMo/SvcHub/blob/master/LICENSE">
      <img src="https://img.shields.io/badge/License-GPL--3.0-blue?style=flat-square" alt="License" />
    </a>
    <a href="https://github.com/LimpidMo/SvcHub/releases">
      <img src="https://img.shields.io/github/downloads/LimpidMo/SvcHub/total?style=social" alt="Downloads" />
    </a>
    <a href="https://github.com/LimpidMo/SvcHub/releases">
      <img src="https://img.shields.io/github/v/release/LimpidMo/SvcHub?style=social" alt="Release" />
    </a>
    <a href="https://github.com/LimpidMo/SvcHub/stargazers">
      <img src="https://img.shields.io/github/stars/LimpidMo/SvcHub?style=social&label=Stars" alt="GitHub stars" />
    </a>
  </p>
  <p>
    在线文档：<a href="https://limpidmo.github.io/SvcHub">limpidmo.github.io/SvcHub<a>
  </p>
  <p>
    <b>初衷就是为了聚合运行一些服务，省得一个服务装一个模块，统一管理服务。若你觉得好用，欢迎给仓库来个 Star ⭐~</b>
  </p>
</div>

## 界面概览
<div align="center">

| 服务状态 | 服务配置 | 功能设置|
|---------|---------|---------|
| ![服务状态](docs/public/images/01-status.png) | ![服务配置](docs/public/images/02-config.png ) |![功能设置](docs/public/images/03-settings.png)|
| 启停功能 | 服务日志 | 网页登录|
| ![启停功能](docs/public/images/04-start_stop.png) | ![服务日志](docs/public/images/05-log.png ) |![网页登录](docs/public/images/06-login.png)|
</div>

## 核心功能

- **两类服务**：支持 **Termux 服务** 与 **二进制服务** 的启动配置及收尾命令管理。Termux 服务无需软件挂后台，可选以 root 执行。
- **多种启停策略**：支持定时启停、亮屏启停、Wi-Fi 启停等策略满足多样化启停需求
- **巡检保活**：默认 60 秒巡检一次（可选 10~84600 秒），自动拉起带有 `start` 标签的服务，日志自动轮转。
- **WebUI**：中英双语支持，统一界面管理服务启停、启动配置、查看日志。支持管理器内 WebUI 与浏览器网页直连双通道，支持 PWA 安装

## 快速开始

1. [Releases](https://github.com/LimpidMo/SvcHub/releases/) 中下载模块 ZIP
2. 在 Root 管理器中 → 模块 → 从本地安装，选择对应 ZIP 文件刷入，音量键可选是否挂载 DNS 解析配置，默认不挂载
3. 安装完成后重启设备，升级时自动保留已有配置
4. 在 KernelSU 或 APatch 等管理器 → 模块 → 点击打开 SvcHub → 进入 WebUI
   > Magisk 用户无管理器 WebUI 入口，开启外部访问（默认开启）后浏览器访问 `http://127.0.0.1:5555`，默认密码 `admin`

## 注意事项

- 请自行确认服务以及命令的安全性，再放到模块中应用和执行，自行对操作和处理结果负责
- Termux 服务依赖已安装的 Termux 应用并下载`pkg install`对应软件包，二进制服务自行从可信渠道下载使用，并赋权（`chmod +x`）使用。
- 所有脚本为 POSIX sh，兼容 Android `/system/bin/sh`
- 玩机有风险，请自行备份数据。代码全公开，请自行检阅后按需刷入

## 项目文档

完整使用说明与开发文档见 [https://limpidmo.github.io/SvcHub](https://limpidmo.github.io/SvcHub)。

## 许可证

[GNU General Public License v3.0](https://www.gnu.org/licenses/gpl-3.0.html) · 完整文本见 [LICENSE](LICENSE)

Copyright (C) 2026 LimpidMo
