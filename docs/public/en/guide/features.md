# Start/Stop Services

**Priority** (when all features are on — not recommended): Scheduled window > Screen on/off > Wi-Fi > regular patrol.

## Scheduled Stop Window

All services stop within a daily time window and normal patrol resumes afterwards.

- Stop time ~ start time: saved automatically once chosen; overnight windows are supported (e.g. stop at 22:00, start at 07:00 — that span is the stop window)

## Screen On/Off Services

After the screen is unlocked, whitelisted services run; with an empty whitelist, normal patrol resumes. On screen off, all non-whitelisted services stop (a lock-screen whitelist can be set).

- Screen state is checked in 10-second slices for fast response to unlock; lock-state checks follow the slice sleep interval

## Wi-Fi Based Start/Stop

Once enabled, services start/stop by the selected group; the two groups are mutually exclusive.

- **Connect group**: runs when connected to a listed Wi-Fi, stops when leaving
- **Disconnect group**: runs when leaving a listed Wi-Fi, stops when connecting
- **SSID**: shared by both groups, one Wi-Fi name per line; empty = any Wi-Fi
- Best paired with services without the start tag

> Note: no WakeLock is held by default. Enable Wake Lock in Basic Settings to reduce Doze delays or CPU sleep in feature resume (unsupported on some kernels).
