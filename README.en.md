<div align="center">
<img src="docs/public/images/icon.png" width="150"alt="Icon"/>
<h1>SvcHub</h1>
  <a href="./README.md">中文</a> | <a href="./README.en.md">English</a>

  <p>
    <b>A Termux/binary service start and keeplive management module, support a variety of start and stop policies, WebUI aggregation management</b>
  </p>

  <p>
    <a href="https://developer.android.com">
      <img src="https://img.shields.io/badge/Platform-Android-green?style=flat-square&logo=android" alt="Platform" /></a>
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
    Online docs: <a href="https://limpidmo.github.io/SvcHub">limpidmo.github.io/SvcHub<a>
  </p>
  <p>
    <b>Built to aggregate and manage services, so you don't need a separate module for each. If you find it useful, please give the repo a Star ⭐~</b>
  </p>
</div>

## Screenshots
<div align="center">

| Service Status | Service Config | Settings |
|---------|---------|---------|
| ![Service status](docs/public/images/01-status.png) | ![Service config](docs/public/images/02-config.png ) |![Settings](docs/public/images/03-settings.png)|
| Start/Stop Features | Service Logs | Web Login |
| ![Start/stop](docs/public/images/04-start_stop.png) | ![Logs](docs/public/images/05-log.png ) |![Login](docs/public/images/06-login.png)|
</div>

## Core Features

- **Two Service Types**: Manage startup and cleanup commands for **Termux services** and **binary services**. Termux services run without the app in the background and can optionally run as root.
- **Multiple start/stop strategies**: scheduled stop window, screen on/off control, Wi-Fi based start/stop and more, to meet diverse scheduling needs
- **Patrol keep-alive**: patrols every 60 seconds by default (configurable 10~84600), automatically revives services tagged `start`, and rotates logs automatically.
- **WebUI**: Chinese/English bilingual, with one interface for service start/stop, configuration and log viewing. Supports both the in-manager WebUI and direct browser access, plus PWA installation

## Getting Started

1. Download the module ZIP from [Releases](https://github.com/LimpidMo/SvcHub/releases/)
2. In your root manager → Modules → Install from local storage, flash the ZIP; volume keys offer an optional DNS resolve mount (skipped by default)
3. Reboot after installation; existing configuration is preserved on upgrade
4. In KernelSU or APatch manager → Modules → open SvcHub → enter the WebUI
   > Magisk users have no in-manager WebUI entry. With external access enabled (on by default), visit `http://127.0.0.1:5555` in a browser; default password is `admin`

## Notes

- Verify the safety of services and commands yourself before adding them to the module; you are responsible for your own actions and their results
- Termux services require the installed Termux app with the matching package installed via `pkg install`; download binaries for binary services from trusted sources only, and make them executable (`chmod +x`) yourself
- All scripts are POSIX sh, compatible with Android `/system/bin/sh`
- Modding has risks — back up your data. The code is fully public; review it before flashing


## License

[GNU General Public License v3.0](https://www.gnu.org/licenses/gpl-3.0.html) · See [LICENSE](LICENSE) for the full text

Copyright (C) 2026 LimpidMo
