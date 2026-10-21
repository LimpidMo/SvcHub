# 常见问题

## Termux 服务以非 root 身份启动时启动失败，提示 Permission denied

分两种情况，一种是该服务需要 root 权限运行，另一种则是文件属组问题，则按如下解决:

Termux 服务以完整 Termux 用户身份（用户与组）运行，若服务目录属组仍是 root，会因无权访问启动失败。修复：以root权限执行如下命令
```bash
chown -R $(stat -c %u /data/data/com.termux):$(stat -c %g /data/data/com.termux) <服务目录>
```


## 二进制服务启动失败

二进制服务以 root 身份运行，启动失败的原因几乎都写在服务日志里。以下按日志输出逐条对照。

### `exec: Exec format error`（架构没对上）

下载的二进制架构与设备 CPU 不一致。手机绝大多数是 `aarch64`，请下载 `linux_arm64` / `arm64` 版本，而不是 `amd64`、`x86_64`、`armv7`。

自查命令：

```bash
file ./xxx        # 应显示 ELF 64-bit LSB executable, ARM aarch64 或 arm64,Static 或 statically linked
uname -m            # 应显示 aarch64
```

### `error while loading shared libraries`（缺动态库）


该二进制是动态链接版本，依赖的 `.so` 不在设备上或不在加载路径。两种种处理方式，任选其一：

1. 换官方**静态编译**版本（文件名常带 `static` 或后缀无 `-musl`/`-glibc` 字样，优先选 `linux_arm64_static`）
2. 把依赖的 `.so` 全部放入二进制同目录，并用 `export LD_LIBRARY_PATH=./; ./xxx` 方式启动

自查命令：

```bash
readelf -d ./xxx | grep NEEDED       # 列出所有动态库依赖，标注 not found 的就是缺的
```

### `no such file or directory`（路径写错）或 `inaccessible or not found` (未找到)

二进制服务工作目录默认是 `/data/media/0/Server` 即外部存储目录`/storage/emulated/0/Server`，件若将二进制文件放在`test`子文夹下，则启动命令需先`cd test`切换工作目录，再输入 `./xxx` 启动二进制服务。即`cd test;./xxx`

### `Permission denied`（无可执行权限）

本模块不修改二进制文件权限。请自行 `chmod +x ./xxx`（即可执行权限 `755`），并确保依赖的库文件与资源文件与二进制在同一目录。



## Magisk 用户找不到 WebUI 入口

Magisk 无管理器 Action 入口。开启外部访问（默认开启）后，浏览器访问 `http://127.0.0.1:5555`，默认密码 `admin`，首次使用请立即改密。

## 关闭「巡检保活」后开机不启动服务

巡检保活开关只管周期拉起，不影响开机首轮启动——开机首轮不受该开关管辖。若开机仍不启动，检查服务是否带 `start` 绿色标签（配置页可改），以及模块是否处于停止窗/熄屏白名单外等启停策略抑制状态。

## 手动启动的服务被自动杀掉了

巡检保活不执行停止服务操作、不会杀死 `stop` 标签的服务，正是为避免误杀手动临时启动的服务。若被杀，请检查是否命中了定时停止窗、熄屏（非白名单）或 Wi-Fi 断开组等启停策略。

## 更改巡检间隔后不生效

间隔更改在一分钟内生效并打断原间隔；高于 60 秒的间隔会拆成 ≤60 秒的分片执行，以保证配置热更新与功能检查及时。

## 端口填了但服务页打不开

端口仅用于状态页的跳转链接，范围需为 1~65535 的数字才会显示「打开」按钮。填了非数字（如描述文字）则直显文本、不出链接。服务自身是否真的监听该端口，请以服务日志为准。


## 升级模块后配置没了

升级自动保留 `config/` 三文件。若配置丢失，检查是否刷入的是全新安装（而非覆盖升级），或曾手动清理过模块目录。


## Termux 服务需要 Termux 一直挂后台吗

不需要。启动 Termux 中的服务不会拉起 Termux 后台，也无需任何自启动软件挂后台，本模块只引用其下载后的软件包启动，不启动 Termux 自身软件服务。

## 息屏或锁屏后服务响应延迟、不执行

本模块默认不申请 WakeLock（防休眠锁），依赖系统自身调度；可在「基本设置」开启唤醒锁缓解（部分内核不支持）。部分定制系统（如 MIUI、ColorOS）在深度休眠（Doze）时会挂起后台脚本。