# FAQ

## A Termux service fails to start with Permission denied when not running as root

Two cases: either the service genuinely needs root privileges, or the file ownership is wrong — fix it as follows.

Termux services run as the full Termux user (user and group). If the service folder is still owned by root, the service cannot access it and fails to start. Fix: run the following command as root

```bash
chown -R $(stat -c %u /data/data/com.termux):$(stat -c %g /data/data/com.termux) <service-folder>
```


## A binary service fails to start

Binary services run as root, and the cause of a failed start is almost always written in the service log. Match your log output against the entries below.

### `exec: Exec format error` (architecture mismatch)

The downloaded binary targets a different CPU architecture than your device. Most phones are `aarch64` — download the `linux_arm64` / `arm64` build, not `amd64`, `x86_64` or `armv7`.

Self-check:

```bash
file ./xxx        # should say ELF 64-bit LSB executable, ARM aarch64 or arm64, Static or statically linked
uname -m          # should say aarch64
```

### `error while loading shared libraries` (missing shared libraries)

This binary is dynamically linked and its `.so` dependencies are not on the device or not on the loader path. Two options, pick either:

1. Use the official **statically linked** build (the filename often contains `static`, or has no `-musl`/`-glibc` suffix; prefer `linux_arm64_static`)
2. Put all dependent `.so` files in the same folder as the binary and start it with `export LD_LIBRARY_PATH=./; ./xxx`

Self-check:

```bash
readelf -d ./xxx | grep NEEDED       # lists all shared library dependencies; anything not found is missing
```

### `no such file or directory` (wrong path) or `inaccessible or not found` (not found)

Binary services default to the working directory `/data/media/0/Server`, i.e. the external storage folder `/storage/emulated/0/Server`. If you put the binary in a `test` subfolder, the start command must first `cd test` to switch into it and then run `./xxx` — that is, `cd test;./xxx`.

### `Permission denied` (not executable)

This module does not change binary file permissions. Run `chmod +x ./xxx` yourself (executable permission `755`), and keep dependent libraries and resources in the same folder as the binary.



## Magisk users cannot find the WebUI entry

Magisk has no manager Action entry. With external access enabled (on by default), visit `http://127.0.0.1:5555` in a browser; the default password is `admin` — change it right after the first login.

## Services do not auto-start on boot after turning off "Patrol keep-alive"

The patrol keep-alive switch only controls periodic revival, not the first boot round — boot startup is not governed by that switch. If services still do not start on boot, check whether they carry the green `start` tag (editable on the config page) and whether a stop window, screen-off whitelist or Wi-Fi strategy is suppressing the start.

## My manually started service was killed automatically

Patrol keep-alive never performs stop operations and never kills `stop`-tagged services, precisely so temporarily started services are not killed by mistake. If it was killed, check whether a scheduled stop window, screen-off (outside the whitelist) or the Wi-Fi disconnect group matched.

## The new patrol interval does not take effect

Interval changes apply within one minute and interrupt the old interval immediately. Intervals above 60 seconds are split into slices of ≤60 seconds so configuration hot-reload and feature checks stay responsive.

## I filled in a port but the service page will not open

The port field only drives the jump link on the status page; it must be a number between 1 and 65535 for the "open" button to appear. Non-numeric text is displayed as a plain label with no link. Whether the service actually listens on that port is shown in its log.


## Configuration is gone after upgrading the module

Upgrades preserve the three files in `config/` automatically. If configuration is missing, check whether you performed a fresh install instead of an upgrade, or manually cleaned the module directory.


## Does a Termux service need the Termux app kept in the background

No. Starting a service inside Termux does not launch the Termux background app, and no autostart helper is needed. The module only uses the packages installed by Termux to start the service — it does not start the Termux app itself.

## Services respond slowly or do not run after the screen turns off or the device locks

This module does not force a WakeLock (anti-sleep lock) by default and relies on the system's own scheduling; enable Wake Lock in Basic Settings to mitigate (unsupported on some kernels). Some customized systems (such as MIUI, ColorOS) suspend background scripts during deep sleep (Doze).
