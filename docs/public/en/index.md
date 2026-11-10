---
layout: home

hero:
  name: SvcHub
  text: Service Start & Keep-alive Management
  tagline: KernelSU / Magisk / APatch module · Run Termux and binary services on a bare kernel · Multiple start/stop strategies · Service updates · Aggregated WebUI management
  image:
    src: /images/icon.png
    alt: SvcHub
  actions:
    - theme: brand
      text: Get Started
      link: /en/guide/
    - theme: alt
      text: GitHub
      link: https://github.com/LimpidMo/SvcHub

features:
  - title: 🗂️ Aggregated Management
    details: Manage all services in one module — unified WebUI start/stop, configuration and log viewing, no need for one module per service; browser access supports PWA installation
  - title: 🧩 Two Service Types
    details: Termux services run as the Termux user without keeping Termux in background and can run as root per allowlist; binary services run as root with a configurable service directory
  - title: 🚦 Multiple Start/Stop Features
    details: Scheduled stop window (overnight supported), screen on/off whitelist control, and Wi-Fi connect / disconnect groups — composable; priority is schedule > screen > Wi-Fi > patrol
  - title: 🔄 Binary Update
    details: Binary updates from GitHub repositories with hourly / daily / weekly version checks and optional automatic updates; failed replacements roll back automatically
---
