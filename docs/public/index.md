---
layout: home

hero:
  name: SvcHub
  text: 服务启动与保活管理
  tagline:  KernelSU / Magisk / APatch 模块 · 裸核运行服务 Termux 和二进制服务 · 多类启停策略 · 服务更新 · WebUI 聚合管理
  image:
    src: /images/icon.png
    alt: SvcHub
  actions:
    - theme: brand
      text: 快速开始
      link: /guide/
    - theme: alt
      text: GitHub
      link: https://github.com/LimpidMo/SvcHub

features:
  - title: 🗂️ 聚合管理
    details: 一个模块管理全部服务，WebUI 统一启停、配置、查看日志，省得一个服务装一个模块；网页访问支持 PWA 安装
  - title: 🧩 两类服务
    details: Termux 服务以 Termux 用户运行、无需 Termux 挂后台，可按名单以 root 执行；二进制服务以 root 运行，服务目录可配置
  - title: 🚦 多类启停功能
    details: 定时启停窗口（支持跨夜）、亮屏熄屏白名单启停、Wi-Fi 连接组 / 断开组启停，可组合使用；优先级 定时 > 亮屏 > Wi-Fi > 巡检
  - title: 🔄 二进制更新
    details: 支持来源于 GitHub 仓库的二进制文件更新，可按每小时 / 天 / 周检查版本，可开启自动更新，替换失败自动回滚
---
