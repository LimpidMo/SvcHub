---
layout: home

hero:
  name: SvcHub
  text: Boot-start & keep-alive manager for Termux and binary services
  tagline: Run services on a bare kernel and manage them in one place — no more one module per service; aggregated management via WebUI
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
  - title: Aggregated Management
    details: Manage all services in one module — start/stop, configure and view logs in a single WebUI, with both in-manager WebUI and browser direct access
  - title: Two Service Types
    details: Termux services run as the Termux user without keeping Termux in background; binary services run as root with a configurable working directory
  - title: Multiple Start/Stop Features
    details: Scheduled stop window (overnight supported), screen on/off whitelist control, and Wi-Fi connect / disconnect groups — composable as needed
  - title: Patrol Keep-alive
    details: Periodic patrol revives killed services; logs rotate automatically when oversized; WebUI supports PWA installation
---
