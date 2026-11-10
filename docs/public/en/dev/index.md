# Local Development

Drive the WebUI from a desktop browser while the real scripts run in the default sandbox `.mock-sandbox/modules/SvcHub` — no real device needed, repository `config/` untouched.

## Bridge

`tools/mock-server.js` (Node built-ins only, zero dependencies; script execution requires Git Bash) exposes two channels:

| Channel | URL | Nature |
|---|---|---|
| Manager | `http://127.0.0.1:8090` | Serves index.html with a ksu shim injected: sync XHR → `POST /__exec` → runs `sh action.sh <subcommand>` inside the sandbox (subcommands pass a whitelist) |
| External | `http://127.0.0.1:5555` | Sandbox starts busybox httpd + CGI; login / sessions / audit / lockout are all real |

On startup the sandbox `service.sh` runs once: supervisor patrol and httpd come up, and sample config is generated (8 demo services, `webui_enabled=1`, default password `admin`, forced change on first login).

## Commands

```powershell
node tools/mock-server.js          # start the bridge → http://127.0.0.1:8090
node tools/mock-server.js reflash  # bridge alive → hot-update scripts; not alive → full start (accepts --wifi on --ssid Home)
node tools/mock-server.js stop     # stop bridge + all sandbox services (same as Ctrl+C)
node tools/mock-server.js reset    # factory reset: delete sandbox config/run/log, rebuild samples

sh tools/check.sh                  # fast checks: syntax + duplicate functions + lib unit tests + i18n + pack list
node tools/smoke.js                # end-to-end smoke: temporary isolated sandbox, auto cleanup; suites listed in the file header
```

## Simulating device state

Writes mock files; takes effect on the supervisor's next slice:

- Wi-Fi: `curl "http://127.0.0.1:8090/__wifi?state=on&ssid=Home"`
- Screen/lock: `curl "http://127.0.0.1:8090/__screen?screen=off&lock=lock"` with `screen=on|off`, `lock=lock|unlock`

## Isolated instances

Add `--sandbox-root <dir> --bridge-port <port> --web-port <port>` (`stop`/`reflash` accept the same flags) to run alongside your daily setup; `tools/smoke.js` uses its own sandbox and ports this way.

## Notes

- No CGI route on 8090: `/cgi-bin/api.cgi` always returns 404 — use the external channel on 5555
- `reflash` only replaces files and does not restart running processes: after editing `supervisor.sh`/`service.sh` run `stop` then start again (same for `mock-server.js` itself)
- `web.conf` port changes do not take effect via `reflash` (httpd is not restarted; the port is written on cold start only)
- Running `sh action.sh <subcommand>` without a path fails: `$0` has no slash, `MODDIR` is empty, the script exits 1
- The sandbox sets `SVCHUB_MOCK=1` to bypass dumpsys/su; verify passwords by hashing offline instead of retrying the login endpoint (which triggers lockout)
