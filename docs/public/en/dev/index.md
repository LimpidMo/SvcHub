# Local Development

Run the real scripts in a fixed sandbox (`.mock-sandbox/`) and drive the WebUI from a desktop browser — no real device needed, repository `config/` untouched.

```powershell
node tools/mock-server.js          # start the bridge → http://127.0.0.1:8090
node tools/mock-server.js stop     # stop the bridge + clean sandbox services
node tools/mock-server.js reset    # factory reset: delete sandbox config/run/log and rebuild samples
node tools/mock-server.js reflash  # hot-update sandbox scripts after edits
```

- Wi-Fi simulation: `curl "http://127.0.0.1:8090/__wifi?state=on&ssid=Home"`
  - Cold start with arguments: `node tools/mock-server.js --wifi on --ssid Home`
- Screen/lock simulation: `curl "http://127.0.0.1:8090/__screen?screen=off&lock=lock"`
  - Other values: `screen=on&lock=lock` (screen on, locked) or `screen=on&lock=unlock` (screen on, unlocked)
- Shell commands rely on Git Bash (mock-server auto-detects the install path; adding it to PATH is recommended)
