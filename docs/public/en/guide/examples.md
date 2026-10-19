# Service Examples

## Termux Service

Using OpenList as an example. Termux services default to the working directory `/data/data/com.termux/files/home`:

- Option 1: **fill in exactly how you start it in Termux**
  - For openlist, just enter `openlist server` — same as starting it inside Termux
- Option 2: **use a dedicated folder (keep service files organized)**
  - Create an `openlist` folder under the home directory yourself
  - If openlist lives at `/data/data/com.termux/files/home/openlist`, enter `cd ./openlist;openlist server` or `openlist server --data ./openlist/data` as the start command
- Enter 5244 as the port; once running, you can open the service page from the port
- On first launch of openlist, check the logs for the `password` field

## Binary Service

Using [Memos](https://github.com/usememos/memos) as an example. Binary services default to the working directory `/data/media/0/Server` (external storage `/storage/emulated/0/Server`):

- Create a `memos` folder under `Server`, extract the downloaded `memos_0.xx.0_linux_arm64.tar.gz`, and put the executable `memos` inside
- The binary must already be executable (`chmod +x ./memos`, i.e. permission `755`). This module does not change binary file permissions — handle it yourself, and place dependent libraries and resources in the same folder
- Enter `cd ./memos;./memos` as the start command: `cd ./xxx` switches into the folder, `./xxx` launches the binary
- memos listens on 8081 by default; add `--port 5230` to use port 5230 instead (see the official docs for other flags). Entering 8081 in the port field enables the jump link on the service page
