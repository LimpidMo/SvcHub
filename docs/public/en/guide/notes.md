# Notes

- Verify the safety of services and commands yourself before adding them to the module; you are responsible for your own actions and their results
- Termux services require the installed Termux app; install the matching package:
  - e.g. for openlist: `pkg update && pkg install -y openlist`
  - To update: run `pkg update && pkg upgrade -y` in Termux to update everything, or `pkg update && pkg install -y <service1> <service2>` for specific ones
- Download binaries for binary services from trusted sources, e.g. GitHub
- All scripts are POSIX sh, compatible with Android `/system/bin/sh`
- Modding has risks — back up your data. The code is fully public; review it before flashing
