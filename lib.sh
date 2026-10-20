#!/system/bin/sh
# SvcHub 公共库：配置读写（config/setting.conf 设置项 + config/services.conf 服务项）、进程 pid 管理、日志轮转与校验、Wi-Fi 策略控制、屏幕亮灭判定。
# 注意：调用方必须先设置 MODDIR=${0%/*} 再 source 本文件。

if [ -z "$MODDIR" ] || [ ! -d "$MODDIR" ]; then
	echo "lib.sh: MODDIR 未设置或不存在" >&2
	exit 1
fi

RUNDIR="$MODDIR/run"
LOG_DIR="$MODDIR/log"
SUPERLOG="$LOG_DIR/supervisor.log"
SPPID="$RUNDIR/supervisor.pid"
BOOTID_FILE="$RUNDIR/boot_id"
DISABLE_FILE="$MODDIR/disable"
CONFIG_DIR="$MODDIR/config"
SETTING_FILE="$CONFIG_DIR/setting.conf"
SERVICES_FILE="$CONFIG_DIR/services.conf"
WEB_CONF="$CONFIG_DIR/web.conf"
DEFAULT_SERVER_DIR="/data/media/0/Server"

# Termux 运行环境：TERMUX_HOME、TERMUX_UID、TERMUX_ENV、DNS_GID
# 沙盒中 TERMUX_HOME 为空跳过，对实机路径无影响 
[ -n "$SVCHUB_TERMUX_HOME" ] && TERMUX_HOME="$SVCHUB_TERMUX_HOME" || TERMUX_HOME="/data/data/com.termux/files/home"
TERMUX_UID=$(stat -c '%u' "$TERMUX_HOME" 2>/dev/null)
TERMUX_GID=$(stat -c '%g' "$TERMUX_HOME" 2>/dev/null)
# PATH 末段的 $PATH 不带反斜杠：由服务 shell 运行时展开为 su 继承的 PATH（带 \ 会变字面死串）；
# 再并上系统默认 PATH 保底，Termux 目录缺失时（如 PC 联调沙盒）仍能找到 sleep 等基础命令。
TERMUX_PATH_SYS='/system/bin:/system/xbin:/vendor/bin:/data/local/bin:/bin:/usr/bin'
TERMUX_ENV='export LANG=en_US.UTF-8;export LC_ALL=en_US.UTF-8; export PREFIX=/data/data/com.termux/files/usr; export PATH=$PREFIX/bin:$PREFIX/bin/applets:$PATH:'"$TERMUX_PATH_SYS"'; export TMPDIR=$PREFIX/tmp; export LD_LIBRARY_PATH=$PREFIX/lib;export LD_PRELOAD=$PREFIX/lib/libtermux-exec.so;'
# 联调沙盒：Termux 目录与 libtermux-exec.so 均不存在，去掉真机专用变量免每条 fork 报错
if [ "$SVCHUB_MOCK" = "1" ]; then
	TERMUX_ENV='export LANG=en_US.UTF-8;export LC_ALL=en_US.UTF-8; export PREFIX=/data/data/com.termux/files/usr; export PATH=$PREFIX/bin:$PREFIX/bin/applets:$PATH:'"$TERMUX_PATH_SYS"';'
fi
DNS_GID=$(stat -c '%g' /dev/socket/dnsproxyd 2>/dev/null)

# termux 服务完整以 termux 用户运行的 su 附加参数（惰性缓存）：uid + 主组 + inet 组（探测失败缺省回退）
termux_user_args() {
	[ -n "$TERMUX_UID" ] || TERMUX_UID=0
	[ -n "$TERMUX_GID" ] || TERMUX_GID=$TERMUX_UID
	[ -n "$DNS_GID" ] || DNS_GID=3003
	printf '%s\n' "-g $TERMUX_UID -G $DNS_GID $TERMUX_UID" 
}


# 日志统一上限（字节），默认1MB
LOG_MAX_BYTES=1048576

# Wi-Fi 策略相关全局变量
WIFI_POLICY=""
WIFI_POLICY_PREV=""
WIFI_SSID_CACHE=""
WIFI_SSID_NOW=""
WIFI_SSID_CACHE_TIME=0

# 亮屏启停全局变量（SCREEN_ON 初始为亮屏，首轮巡检前由 refresh_screen_gate 重算）
SCREEN_SERVICE_ENABLED=""
SCREEN_SERVICE_NAMES=""
SCREEN_ON="1"
SCREEN_WARNED=""
# 亮屏解锁判定：SCREEN_UNLOCK_OK=1 才放行启动（锁屏中亮屏=通知/抬手，不拉起）
SCREEN_UNLOCK_OK="1"

mkdir -p "$RUNDIR" "$LOG_DIR" "$RUNDIR/session"

# ---------- 配置（config/setting.conf 设置项 + config/services.conf 服务项） ----------
# 配置 schema 唯一定义全键：新增设置键需同步补全 load_settings / write_settings / action.sh cfg_apply_one 及前端字段；
# 新增服务类型只需在 load_services / write_services 加一个 type 分支。
SETTING_KEYS='sleep_interval server_dir boot_commands wifi_service_enabled wifi_service_names wifi_service_names_off wifi_ssids schedule_enabled schedule_stop schedule_start screen_service_enabled screen_service_names screen_resume_names termux_root_names patrol_enabled language webui_enabled webui_password_hash webui_token'

# JSON 字符串编码：\ " tab CR 转义、换行转字面 \n；逐字符拼接（gsub 替换串反斜杠 busybox/gawk 语义不一致，禁用）
enc_js() {
	awk 'function esc(s,   o, i, n, c) { o = ""; n = length(s); for (i = 1; i <= n; i++) { c = substr(s, i, 1); if (c == "\\") o = o "\\\\"; else if (c == "\"") o = o "\\\""; else if (c == "\t") o = o "\\t"; else if (c == "\r") o = o "\\r"; else o = o c } return o } { if (NR > 1) printf "\\n"; printf "%s", esc($0) }'
}

# JSON 字符串解码：左到右单遍，\n \t \r \" \\ 还原明文，孤立 \ 原样保留
dec_js() {
	awk 'function unesc(s,   o, i, n, c) { o = ""; n = length(s); for (i = 1; i <= n; i++) { c = substr(s, i, 1); if (c != "\\") { o = o c; continue } i++; c = substr(s, i, 1); if (c == "n") o = o "\n"; else if (c == "t") o = o "\t"; else if (c == "r") o = o "\r"; else if (c == "\"") o = o "\""; else if (c == "\\") o = o "\\"; else o = o "\\" c } return o } { printf "%s", unesc($0) }'
}

# ---------- 后端文案双语 ----------
# 界面语言（zh 默认 / en）：由 setting.conf 的 language 键驱动，load_cfg_sh 后同进程可见。
UI_LANG="zh"

# 取当前语言文案：$1=中文原文（%s 为占位），其余参数按位代入（不经 printf 格式串，值含 % 安全）。
# 英文态查英文表（键即中文原文），漏项回退中文模板（fail-open）。
ui_msg() {
	local tpl=$1
	shift
	case "$UI_LANG" in
	en)
		case "$tpl" in
	# ---- 巡检 / 开关机（supervisor.sh） ----
	'supervisor 已在运行 (old=%s)，退出') printf 'supervisor already running (old=%s), exiting' "$1" ;;
	'supervisor 启动 pid=%s') printf 'supervisor started pid=%s' "$1" ;;
	'mock 环境，跳过启动等待，直接巡检') printf 'mock env: skipping boot wait, patrolling now' ;;
	'系统启动完成') printf 'System boot completed' ;;
	'设备解锁，服务存储可访问') printf 'Device unlocked, service storage accessible' ;;
	'su 就绪：%s，开始巡检') printf 'su ready: %s, patrolling' "$1" ;;
	'等待系统启动/解锁/su 超时(300s)，继续巡检 (boot=%s anim=%s ce=%s su=%s)') printf 'Boot wait timed out (300s), patrolling anyway (boot=%s anim=%s ce=%s su=%s)' "$1" "$2" "$3" "$4" ;;
	'巡检完成') printf 'Patrol complete' ;;
	'巡检开始 开机启动') printf 'Patrol start: boot' ;;
	'巡检开始 启停功能策略') printf 'Patrol start: start/stop policy' ;;
	'巡检开始 interval=%ss') printf 'Patrol start interval=%ss' "$1" ;;
	'巡检开始 启停功能策略（定时停止窗内 %s~%s），暂停拉起') printf 'Patrol start: start/stop policy (in stop window %s~%s), starts paused' "$1" "$2" ;;
	'    跳过 %s') printf '    Skipped %s' "$1" ;;
	'    跳过 %s (%s)') printf '    Skipped %s (%s)' "$1" "$2" ;;
	'    跳过 %s (WIFI 已断开，连接组不启动)') printf '    Skipped %s (Wi-Fi disconnected, on-connect group stays stopped)' "$1" ;;
	'    跳过 %s (WIFI 已连接，断开组不启动)') printf '    Skipped %s (Wi-Fi connected, on-disconnect group stays stopped)' "$1" ;;
	'    已运行 %s') printf '    Already running %s' "$1" ;;
	'    已启动 %s') printf '    Started %s' "$1" ;;
	'    启动未生效 %s（请检查该服务日志/命令）') printf '    Start had no effect for %s (check the service log/command)' "$1" ;;
	'    启动失败 %s (服务目录不存在或命令错误)') printf '    Failed to start %s (service dir missing or bad command)' "$1" ;;
	'    亮屏白名单恢复：仅启动名单内服务') printf '    Unlock whitelist resume: only whitelisted services start' ;;
	' ------- Termux 服务 ------- ') printf ' ------- Termux services ------- ' ;;
	' ------- 二进制服务 ------- ') printf ' ------- Binary services ------- ' ;;
	'检查间隔更新为 %ss') printf 'Interval updated to %ss' "$1" ;;
	'检测到 disable，停止全部受管服务') printf 'Disable flag found, stopping all managed services' ;;
	# ---- 定时停止窗（schedule.log） ----
	'定时启停已关闭，恢复巡检') printf 'Schedule start/stop disabled, patrol resumed' ;;
	'进入定时停止窗（%s~%s），已停止全部服务') printf 'Entered stop window (%s~%s), all services stopped' "$1" "$2" ;;
	'退出定时停止窗（%s~%s），立即巡检恢复服务') printf 'Left stop window (%s~%s), patrolling immediately to restore services' "$1" "$2" ;;
	'定时时间配置无效（stop=%s start=%s），已暂停定时启停') printf 'Invalid schedule times (stop=%s start=%s), schedule start/stop paused' "$1" "$2" ;;
	'supervisor 启动时已在定时停止窗内（%s~%s），暂停拉起') printf 'Stop window already active at startup (%s~%s), starts paused' "$1" "$2" ;;
	# ---- 亮屏启停（screen.log） ----
	'亮屏且已解锁，定时停止窗内，暂停拉起') printf 'Screen on and unlocked, but inside stop window, starts paused' ;;
	'亮屏且已解锁，立即巡检恢复服务') printf 'Screen on and unlocked, patrolling immediately to restore services' ;;
	'亮屏（锁屏中，待解锁后恢复）') printf 'Screen on (still locked, waiting for unlock)' ;;
	'进入熄屏，停止非白名单服务') printf 'Screen off, stopping non-whitelisted services' ;;
	'亮屏已解锁，定时停止窗内，暂停拉起') printf 'Screen on and unlocked, but inside stop window, starts paused' ;;
	'亮屏已解锁，立即巡检恢复服务') printf 'Screen on and unlocked, patrolling immediately to restore services' ;;
	'亮屏又进入锁屏（不拉起，运行中服务保留）') printf 'Locked again (no starts, running services kept)' ;;
	'启动时熄屏，暂停非白名单拉起') printf 'Screen off at startup, non-whitelisted starts paused' ;;
	'启动时亮屏未解锁（锁屏中），暂停拉起') printf 'Screen on but locked at startup, starts paused' ;;
	'无法检测屏幕状态（dumpsys 无匹配字段），按亮屏处理') printf 'Cannot read screen state (no dumpsys match), assuming screen on' ;;
	# ---- Wi-Fi 策略（wifi.log） ----
	'Wi-Fi 启停已关闭') printf 'Wi-Fi start/stop disabled' ;;
	'WiFi %s（%s）') printf 'Wi-Fi %s (%s)' "$1" "$2" ;;
	'当前 Wi-Fi：%s') printf 'Current Wi-Fi: %s' "$1" ;;
	'%s（netId %s）') printf '%s (netId %s)' "$1" "$2" ;;
	'断开组') printf 'on-disconnect group' ;;
	'连接组') printf 'on-connect group' ;;
	'断开组服务%s 同时在连接组，已按连接组处理') printf 'On-disconnect service %s is also in the on-connect group, handled as on-connect' "$1" ;;
	'定时停止窗内，%s暂停启动') printf 'Inside stop window, %s stays stopped' "$1" ;;
	'按门控暂停启动：%s') printf 'Starts paused by gate: %s' "$1" ;;
	'启动%s：%s') printf 'Start %s: %s' "$1" "$2" ;;
	'停止%s：%s') printf 'Stop %s: %s' "$1" "$2" ;;
	'不在服务配置中，跳过：%s') printf 'Not in service config, skipped: %s' "$1" ;;
	'已连接') printf 'connected' ;;
	'已断开') printf 'disconnected' ;;
	'SSID匹配') printf 'SSID matched' ;;
	'无SSID匹配') printf 'no SSID match' ;;
	'SSID未检测') printf 'SSID not detected' ;;
	'(空)') printf '(empty)' ;;
	# ---- 启动禁令原因（supervisor 明细行内嵌） ----
	'定时停止窗内') printf 'inside stop window' ;;
	'亮屏未解锁，暂不拉起') printf 'screen on but locked, not starting yet' ;;
	'熄屏非白名单') printf 'screen off, not whitelisted' ;;
	# ---- 配置加载（services.conf 非法行） ----
	'services.conf 非法行(binary段数不足)：%s') printf 'services.conf invalid line (binary has too few fields): %s' "$1" ;;
	'services.conf 非法行(无|分隔)：%s') printf 'services.conf invalid line (no | separator): %s' "$1" ;;
	'services.conf 非法行(类型[%s])非termux/binary：%s') printf 'services.conf invalid line (type [%s] is not termux/binary): %s' "$1" "$2" ;;
	'services.conf 非法行(名称[%s]字节=%s)：%s') printf 'services.conf invalid line (name [%s] bytes=%s): %s' "$1" "$2" "$3" ;;
	# ---- 收尾命令（stop.log） ----
	'收尾 %s 跳过：su 不可用') printf 'Finish command for %s skipped: su unavailable' "$1" ;;
	'=== 执行 %s 收尾命令 %s ===') printf '=== Running finish command for %s at %s ===' "$1" "$2" ;;
	# ---- 开关日志（action.sh 保存设置） ----
	'自动巡检已%s') printf 'Auto patrol turned %s' "$1" ;;
	'Wi-Fi 启停服务已%s') printf 'Wi-Fi start/stop service turned %s' "$1" ;;
	'定时启停服务已%s') printf 'Schedule start/stop service turned %s' "$1" ;;
	'亮屏启停服务已%s') printf 'Screen start/stop service turned %s' "$1" ;;
	'开启') printf 'on' ;;
	'关闭') printf 'off' ;;
	# ---- 外部访问 httpd 生命周期（webui.log） ----
	'httpd 保活拉起（分片巡检）') printf 'httpd keep-alive start (patrol slice)' ;;
	'httpd 保活拉起失败，见 webui.log') printf 'httpd keep-alive start failed, see webui.log' ;;
	'启动失败：未找到可用 busybox（含 httpd）') printf 'Start failed: no busybox with httpd found' ;;
	'启动失败：api.cgi 无可执行权限（CGI 会 404）') printf 'Start failed: api.cgi is not executable (CGI would 404)' ;;
	'启动失败：端口 %s 被占用（若为旧实例残留，先关闭外部访问再重开）') printf 'Start failed: port %s in use (if a stale instance holds it, turn web access off then on)' "$1" ;;
	'httpd 已启动（%s:%s，pid=%s）') printf 'httpd started (%s:%s, pid=%s)' "$1" "$2" "$3" ;;
	'启动失败：httpd 进程存活但 %s:%s 无响应（CGI 链路不通）') printf 'Start failed: httpd process alive but %s:%s unresponsive (CGI chain broken)' "$1" "$2" ;;
	'启动失败：httpd 进程未存活，请查看 %s') printf 'Start failed: httpd process died, see %s' "$1" ;;
	'httpd 停止失败，进程仍存活') printf 'httpd stop failed, process still alive' ;;
	'httpd 已停止') printf 'httpd stopped' ;;
	'用法：httpd.sh start|stop|status') printf 'Usage: httpd.sh start|stop|status' ;;
	# ---- 开机启动（service.sh） ----
	'disable 标记存在，跳过启动') printf 'Disable flag present, skipping startup' ;;
	'开机命令') printf 'Boot commands' ;;
	# ---- 接口错误（action.sh JSON error / api.cgi cgi_fail） ----
	'外部访问配置请用专用接口修改') printf 'Web access settings must be changed via its dedicated endpoint' ;;
	'配置编码错误') printf 'Config encoding error' ;;
	'配置解码失败') printf 'Config decode failed' ;;
	'配置内容过大') printf 'Config content too large' ;;
	'名称不合法') printf 'Invalid name' ;;
	'不支持的服务类型') printf 'Unsupported service type' ;;
	'启动失败（可能是 Termux 目录不存在或命令错误）') printf 'Start failed (Termux dir missing or bad command)' ;;
	'启动失败（服务目录不存在或命令错误）') printf 'Start failed (service dir missing or bad command)' ;;
	'未在 Termux 服务中找到该名称') printf 'Name not found in Termux services' ;;
	'未在二进制服务中找到该名称') printf 'Name not found in binary services' ;;
	'日志文件不存在') printf 'Log file does not exist' ;;
	'包含高危命令，已拒绝执行：%s') printf 'Contains a dangerous command, refused: %s' "$1" ;;
	'开机命令包含高危命令，已拒绝执行：%s') printf 'Boot commands contain a dangerous command, refused: %s' "$1" ;;
	'模块已禁用，无法开启外部访问') printf 'Module disabled, cannot enable web access' ;;
	'请先设置密码') printf 'Set a password first' ;;
	'配置写入失败') printf 'Failed to write config' ;;
	'未找到可用 busybox（含 httpd）') printf 'No busybox with httpd found' ;;
	'端口 %s 被占用') printf 'Port %s in use' "$1" ;;
	'api.cgi 无可执行权限，请重装模块') printf 'api.cgi is not executable, reinstall the module' ;;
	'httpd 启动失败，请查看 webui 日志') printf 'httpd start failed, see the webui log' ;;
	'httpd 停止失败，进程仍存活，请查看 webui 日志') printf 'httpd stop failed, process still alive, see the webui log' ;;
	'未知参数') printf 'Unknown parameter' ;;
	'编码错误') printf 'Encoding error' ;;
	'解码失败') printf 'Decode failed' ;;
	'密码至少 6 位') printf 'Password must be at least 6 characters' ;;
	'密码过长') printf 'Password too long' ;;
	'旧密码错误') printf 'Wrong current password' ;;
	'随机数生成失败') printf 'Random generation failed' ;;
	'密码哈希失败') printf 'Password hashing failed' ;;
	'Token 生成失败') printf 'Token generation failed' ;;
	'配置写入校验不一致') printf 'Config write verification mismatch' ;;
	'间隔必须为数字') printf 'Interval must be a number' ;;
	'Wi-Fi 功能开关必须为 0 或 1') printf 'Wi-Fi toggle must be 0 or 1' ;;
	'Wi-Fi 服务名不合法: %s') printf 'Invalid Wi-Fi service name: %s' "$1" ;;
	'Wi-Fi SSID 列表过长') printf 'Wi-Fi SSID list too long' ;;
	'Wi-Fi SSID 数量过多(最多100个)') printf 'Too many Wi-Fi SSIDs (max 100)' ;;
	'定时功能开关必须为 0 或 1') printf 'Schedule toggle must be 0 or 1' ;;
	'定时时间格式错误(HH:MM)') printf 'Invalid schedule time format (HH:MM)' ;;
	'亮屏启停开关必须为 0 或 1') printf 'Screen toggle must be 0 or 1' ;;
	'锁屏白名单服务名不合法: %s') printf 'Invalid lock-whitelist service name: %s' "$1" ;;
	'亮屏白名单服务名不合法: %s') printf 'Invalid unlock-whitelist service name: %s' "$1" ;;
	'root 运行服务名不合法: %s') printf 'Invalid root-run service name: %s' "$1" ;;
	'巡检开关必须为 0 或 1') printf 'Patrol toggle must be 0 or 1' ;;
	'未知配置键') printf 'Unknown config key' ;;
	'配置内容为空') printf 'Config content is empty' ;;
	'停止时间与启动时间不能相同') printf 'Stop time and start time cannot be the same' ;;
	'服务配置格式错误（第 %s 行）') printf 'Service config format error (line %s)' "$1" ;;
	'端口不合法') printf 'Invalid port' ;;
	'端口超出范围') printf 'Port out of range' ;;
	'语言只支持 zh 或 en') printf 'Language must be zh or en' ;;
	# ---- CGI 网关（api.cgi） ----
	'请求体为空') printf 'Request body is empty' ;;
	'请求体过大') printf 'Request body too large' ;;
	'未知接口') printf 'Unknown endpoint' ;;
	'仅支持 POST') printf 'POST only' ;;
	'尝试过多，请 %s 秒后再试') printf 'Too many attempts, retry in %s seconds' "$1" ;;
	'密码或 Token 错误') printf 'Wrong password or Token' ;;
	'未登录') printf 'Not logged in' ;;
	'会话生成失败') printf 'Session generation failed' ;;
	'请在管理器内操作') printf 'Use the manager app instead' ;;
	'登录锁定：%s 连续失败 %s 次，锁定 %s 秒') printf 'Login locked: %s failed %s times in a row, locked for %s seconds' "$1" "$2" "$3" ;;
	'登录失败：%s') printf 'Login failed: %s' "$1" ;;
	'登录成功（会话复用）：%s') printf 'Login succeeded (session reused): %s' "$1" ;;
	'登录成功：%s') printf 'Login succeeded: %s' "$1" ;;
	'重新生成长期 Token') printf 'Regenerate long-term Token' ;;
	'修改访问密码') printf 'Change web access password' ;;
	'%s：%s') printf '%s: %s' "$1" "$2" ;;
	'保存设置项：%s') printf 'Save settings: %s' "$1" ;;
	'保存服务项：%s') printf 'Save services: %s' "$1" ;;
	'测试命令（普通）来源 %s：%s') printf 'Test command (normal) from %s: %s' "$1" "$2" ;;
	'测试命令（Termux）来源 %s：%s') printf 'Test command (Termux) from %s: %s' "$1" "$2" ;;
	'手动执行开机命令：%s') printf 'Run boot commands manually: %s' "$1" ;;
	'启动服务：%s（%s）') printf 'Start service: %s (%s)' "$1" "$2" ;;
	'停止服务：%s（%s）') printf 'Stop service: %s (%s)' "$1" "$2" ;;
	'清空日志：%s（%s）') printf 'Clear log: %s (%s)' "$1" "$2" ;;
	# ---- 交互执行 / 外部访问开关（action.sh） ----
	'(测试运行)') printf '(test run)' ;;
	'(Termux 测试运行)') printf '(Termux test run)' ;;
	'开机命令(手动)') printf 'Boot commands (manual)' ;;
	'高危命令已拦截：%s') printf 'Dangerous command blocked: %s' "$1" ;;
	'高危命令已拦截（开机命令）：%s') printf 'Dangerous command blocked (boot commands): %s' "$1" ;;
	'外部访问已开启') printf 'Web access enabled' ;;
	'外部访问已关闭') printf 'Web access disabled' ;;
	# ---- Manager Action 状态摘要（action.sh 默认分支） ----
	'SvcHub 状态摘要') printf 'SvcHub status summary' ;;
	'保活间隔: %ss | Termux 服务: %s | 二进制服务: %s') printf 'Keep-alive interval: %ss | Termux services: %s | Binary services: %s' "$1" "$2" "$3" ;;
	'Termux 服务:') printf 'Termux services:' ;;
	'二进制服务:') printf 'Binary services:' ;;
	*) printf '%s' "$(ui_fill "$tpl" "$@")" ;;
		esac
		;;
	*)
		printf '%s' "$(ui_fill "$tpl" "$@")"
		;;
	esac
}

# 按位代入 %s 占位：awk 逐段替换，值含 % 不当格式符；无占位时原样返回
ui_fill() {
	[ "$#" -gt 1 ] || { printf '%s' "$1"; return 0; }
	printf '%s\n' "$1" | awk -v a="$2" -v b="${3-}" -v c="${4-}" -v d="${5-}" '{
		sub(/%s/, a); sub(/%s/, b); sub(/%s/, c); sub(/%s/, d); print }'
}

# ---------- 校验 ----------

is_int() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;
	esac
	return 0
}

valid_name() {
	case "$1" in
		''|*[!A-Za-z0-9._-]*) return 1 ;;
	esac
	return 0
}

# 设置项写成 setting.conf（KEY=value 行格式，多行值经 enc_js 转义存单行；原子替换，600 权限）。
# 无参：直接从 load_cfg_sh 的同名全局变量读取。
write_settings() {
	local tmp="$SETTING_FILE.tmp"
	mkdir -p "$CONFIG_DIR" 2>/dev/null
	{
		printf 'sleep_interval=%s\n'          "$(printf '%s' "$SLEEP_INTERVAL" | enc_js)"
		printf 'server_dir=%s\n'              "$(printf '%s' "$SERVER_DIR" | enc_js)"
		printf 'boot_commands=%s\n'           "$(printf '%s' "$BOOT_COMMANDS" | enc_js)"
		printf 'wifi_service_enabled=%s\n'    "$(printf '%s' "$WIFI_SERVICE_ENABLED" | enc_js)"
		printf 'wifi_service_names=%s\n'      "$(printf '%s' "$WIFI_SERVICE_NAMES" | enc_js)"
		printf 'wifi_service_names_off=%s\n'  "$(printf '%s' "$WIFI_SERVICE_NAMES_OFF" | enc_js)"
		printf 'wifi_ssids=%s\n'              "$(printf '%s' "$WIFI_SSIDS" | enc_js)"
		printf 'schedule_enabled=%s\n'        "$(printf '%s' "$SCHEDULE_ENABLED" | enc_js)"
		printf 'schedule_stop=%s\n'           "$(printf '%s' "$SCHEDULE_STOP" | enc_js)"
		printf 'schedule_start=%s\n'          "$(printf '%s' "$SCHEDULE_START" | enc_js)"
		printf 'screen_service_enabled=%s\n'  "$(printf '%s' "$SCREEN_SERVICE_ENABLED" | enc_js)"
		printf 'screen_service_names=%s\n'    "$(printf '%s' "$SCREEN_SERVICE_NAMES" | enc_js)"
	printf 'screen_resume_names=%s\n'     "$(printf '%s' "$SCREEN_RESUME_NAMES" | enc_js)"
	printf 'termux_root_names=%s\n'       "$(printf '%s' "$TERMUX_ROOT_NAMES" | enc_js)"
		printf 'patrol_enabled=%s\n'          "$(printf '%s' "$PATROL_ENABLED" | enc_js)"
		printf 'language=%s\n'                "$(printf '%s' "$UI_LANG" | enc_js)"
		printf 'webui_enabled=%s\n'           "$(printf '%s' "$WEBUI_ENABLED" | enc_js)"
		printf 'webui_password_hash=%s\n'     "$(printf '%s' "$WEBUI_PASSWORD_HASH" | enc_js)"
		printf 'webui_token=%s\n'             "$(printf '%s' "$WEBUI_TOKEN" | enc_js)"
	} > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$SETTING_FILE"
	LOAD_CFG_DONE=""
}

# 服务项写成 services.conf（统一 6 段 type|name|port|auto|cmd|end_cmd，先全部 termux 再 # binary + 全部 binary；原子替换）。
# 首行 # svc-v1.4.0 为格式标记（附段序说明）：无标记按旧格式解析（旧 5 段补空 end_cmd、更旧 6 段丢 extra），写回即升级。
# 无参：直接从 load_cfg_sh 的 TERMUX_SERVICES / BINARY_SERVICES（内存统一 5 段 name|port|auto|cmd|end_cmd）读取。
write_services() {
	local tmp="$SERVICES_FILE.tmp" line
	mkdir -p "$CONFIG_DIR" 2>/dev/null
	{
		echo '# svc-v1.4.0 type|name|port|auto|cmd|end_cmd'
		printf '%s\n' "$TERMUX_SERVICES" | while IFS= read -r line || [ -n "$line" ]; do
			[ -n "$line" ] || continue
			printf 'termux|%s\n' "$line"
		done
		echo '# binary'
		printf '%s\n' "$BINARY_SERVICES" | while IFS= read -r line || [ -n "$line" ]; do
			[ -n "$line" ] || continue
			printf 'binary|%s\n' "$line"
		done
	} > "$tmp" && mv -f "$tmp" "$SERVICES_FILE"
	LOAD_CFG_DONE=""
}


# ---------- su 可用性检测（兼容 KernelSU / Magisk / APatch） ----------

# 只负责找 su 入口
get_su_bin() {
	local p

	# 联调覆盖：调试沙盒设置，设备上为空走正常探测，零影响
	if [ -n "$SVCHUB_SU_BIN" ] && [ -x "$SVCHUB_SU_BIN" ]; then
		printf '%s\n' "$SVCHUB_SU_BIN"
		return 0
	fi

	p=$(command -v su 2>/dev/null)
	if [ -n "$p" ] && [ -x "$p" ]; then
		printf '%s\n' "$p"
		return 0
	fi

	# 仅兜底 PATH 异常；Magic Mount 主入口
	for p in /system/bin/su; do
		if [ -x "$p" ]; then
			printf '%s\n' "$p"
			return 0
		fi
	done

	return 1
}

# ---------- 日志 ----------

# supervisor.log 统一日志行（supervisor.sh / service.sh 共用）
sup_log() {
	[ -n "$1" ] || return 0
	echo "[$(date '+%F %T')] $1" >> "$SUPERLOG"
}

# 巡检明细行：不带时间戳，轮次开始/结束仍由 sup_log 标注
sup_log_bare() {
	[ -n "$1" ] || return 0
	echo "$1" >> "$SUPERLOG"
}

# 日志超过上限时保留最近1/4，避免无限增长
rotate_log() {
	local log=$1 max=${2:-$LOG_MAX_BYTES} sz
	[ -f "$log" ] || return 0
	sz=$(wc -c < "$log" 2>/dev/null | tr -d ' ')
	[ "$sz" -le "$max" ] 2>/dev/null && return 0
	tail -c $((max / 4)) "$log" > "$log.tmp" 2>/dev/null || { : > "$log"; return 0; }
	cat "$log.tmp" > "$log"
	rm -f "$log.tmp"
	return 0
}

# 巡检时全量轮转：log/ 下所有日志套用统一上限
rotate_all_logs() {
	local f
	for f in "$LOG_DIR"/*.log; do
		[ -f "$f" ] || continue
		rotate_log "$f"
	done
	return 0
}

# 从 stdin 逐行执行并记录（不做 eval）。
# $1=日志文件 $2=标记 $3=runner（如 sh / su / "su 10000"，词分割展开） $4=命令前缀（Termux 注入 TERMUX_ENV）
run_lines() {
	local log=$1 mark=$2 runner=${3:-sh} env_prefix=${4:-} line
	{
		echo "=== $mark $(date '+%F %T') ==="
		# read 无尾随换行返回非零但变量有效（网页 POST body 不带换行），|| [ -n "$line" ] 兜底最后一行
		while IFS= read -r line || [ -n "$line" ]; do
			[ -z "$line" ] && continue
			echo "> $line"
			$runner -c "$env_prefix $line"
			echo "[exit=$?]"
		done
	} >> "$log" 2>&1
}

# ---------- 运行期清理 ----------
# 清 run 下残留 pid 文件（session 子目录保留，登录会话跨重启由 webui_clean_stale_sess 处理）；
# log 目录除开机命令日志全部删除。服务日志会在下次启动时重建。
clean_temp_files() {
	local f base
	if [ -d "$RUNDIR" ]; then
		for f in "$RUNDIR"/*; do
			[ -e "$f" ] || continue
			[ -d "$f" ] && continue
			rm -f "$f"
		done
	fi
	if [ -d "$LOG_DIR" ]; then
		for f in "$LOG_DIR"/*; do
			[ -f "$f" ] || continue
			base=${f##*/}
			[ "$base" = boot_commands.log ] && continue
			rm -f "$f"
		done
	fi
	return 0
}

# ---------- 进程管理（完全基于 pid 文件，杜绝按名模糊匹配） ----------
# 每个服务以 name 作为 $RUNDIR/<name>.pid 的索引，文件仅保存 setsid 进程组 leader 的 pid。

# pid 文件活性检查：存在且首行 pid 存活则输出该 pid 并返回 0；
# 进程已退出/文件损坏则顺手清理过期 pid 文件并返回 1。
# 注意：输出供 supervisor 单实例日志等场景取 pid 用，仅作布尔判定时须用 >/dev/null 吞掉。
pidfile_alive() {
	local pidf=$1 pid
	[ -f "$pidf" ] || return 1
	read -r pid < "$pidf" 2>/dev/null || { rm -f "$pidf"; return 1; }
	if kill -0 "$pid" 2>/dev/null; then
		printf '%s\n' "$pid"
		return 0
	fi
	rm -f "$pidf"
	return 1
}

# 检查服务是否在运行：pid 文件存在且首行 pid 存活即在运行
svc_running() {
	pidfile_alive "$RUNDIR/$1.pid" >/dev/null
}

# 成员判断：$1=name 是否存在于换行分隔的名单 $2 中（零 fork，供批量结果查询）
name_in_set() {
	nl='
'
	case "$nl$2$nl" in
		*"$nl$1$nl"*) return 0 ;;
	esac
	return 1
}

# 成员判断：$1=词是否存在于空格分隔的集合 $2 中（供键白名单等）
word_in_set() {
	case " $2 " in
		*" $1 "*) return 0 ;;
	esac
	return 1
}

# 从配置行列表提取 name 列（每行一个，跳过空行）
list_names() {
	awk -F'|' '$1 != "" { print $1 }'
}

# 批量运行状态检测：stdin 读候选名（每行一个），逐个走 svc_running 同源判定，
# 输出真正在运行的名字（无 pgrep 模糊匹配）。
detect_running() {
	local name
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		svc_running "$name" && printf '%s\n' "$name"
	done
}

# 批量检测全部配置内运行中的服务名（换行分隔输出）；依赖 load_cfg_sh 后的 TERMUX_SERVICES/BINARY_SERVICES
compute_runset() {
	{
		printf '%s\n' "$TERMUX_SERVICES" | list_names
		printf '%s\n' "$BINARY_SERVICES" | list_names
	} | detect_running
}

# 按服务类型启动：$1=kind(termux|binary) $2=名称 $3=命令文本。
# 统一启动收口（巡检/Wi-Fi/WebUI）：termux 默认以完整 Termux 用户身份运行，命中 termux_root_names 名单则
# 不注入 su 参数改以 root 运行（工作目录与 TERMUX_ENV 不变）；cmd 库存字面 \n，执行前还原为真换行。
launch_svc() {
	local cmdtext=$3
	case "$cmdtext" in *\\*) cmdtext=$(printf '%s' "$cmdtext" | dec_js) ;; esac
	case "$1" in
		termux)
			if name_in_set "$2" "$TERMUX_ROOT_NAMES"; then
				start_svc "$2" "$TERMUX_HOME" "" "$TERMUX_ENV $cmdtext"
			else
				start_svc "$2" "$TERMUX_HOME" "$(termux_user_args)" "$TERMUX_ENV $cmdtext"
			fi
			;;
		binary) start_svc "$2" "$SERVER_DIR" "" "$cmdtext" ;;
	esac
}

# 启动服务：$1=名称 $2=工作目录 $3=su 附加参数（binary 恒空） $4=命令文本
# setsid 让服务成为独立会话/进程组 leader，命令末尾补 wait 等待全部子进程。
start_svc() {
	local name=$1 dir=$2 extra=$3 cmdtext=$4 log="$LOG_DIR/$1.log" pidf="$RUNDIR/$1.pid" leader su_bin
	valid_name "$name" || return 1
	if svc_running "$name"; then
		return 0    # 已在运行则不重复启动
	fi
	# svc_running 已确认不在运行，残留 pid 文件直接清理后重新启动
	rm -f "$pidf"
	( cd "$dir" 2>/dev/null ) || return 2
	# 先找 su 入口，若不存在则直接返回失败（不尝试启动）
	su_bin=$(get_su_bin) || return 3
	(
		cd "$dir"
		: > "$log"
		setsid "$su_bin" $extra -c "$cmdtext; wait" </dev/null >>"$log" 2>&1 &
		leader=$!
		printf '%s\n' "$leader" > "$pidf"
	) >> "$log" 2>&1 &
	return 0
}

# 按 pid 文件终止：读取首行 pid，先向整个进程组发送 发送 SIGTERM 优雅终止再SIGKILL 强杀
kill_by_name() {
	local name=$1 pidf="$RUNDIR/$1.pid" pid
	[ -f "$pidf" ] || return 1
	read -r pid < "$pidf" || { rm -f "$pidf"; return 1; }
	# pid 合法性校验：必须是大于 1 的纯数字，防止 pid 文件损坏
	is_int "$pid" || { rm -f "$pidf"; return 1; }
	[ "$pid" -gt 1 ] || { rm -f "$pidf"; return 1; }

	# 1. 发送 SIGTERM (15) 优雅终止,让程序自行执行退出程序防止残留
	kill -15 -- -"$pid" 2>/dev/null || kill -15 "-$pid" 2>/dev/null

	# 2. 轮询等待退出（最多 2 秒，间隔 0.5 秒）
	local i=0
	while [ $i -lt 4 ] && kill -0 "$pid" 2>/dev/null; do
		sleep 0.5
		i=$((i + 1))
	done

	# 3. 若仍存活，发送 SIGKILL (9) 强杀
	if kill -0 "$pid" 2>/dev/null; then
		kill -9 -- -"$pid" 2>/dev/null || kill -9 "-$pid" 2>/dev/null
	fi

	return 0
}


# 停止服务：按 pid 文件终止进程组，清理 pid 文件与该服务日志；
# 停止前确在运行（was_running）才执行该服务配置的收尾命令。
stop_svc() {
	local name=$1 pidf="$RUNDIR/$1.pid" was_running=1 i=0
	valid_name "$name" || return 0
	# 布尔判定须吞 stdout（pidfile_alive 成功输出 pid）
	pidfile_alive "$pidf" >/dev/null || was_running=""
	kill_by_name "$name"
	rm -f "$LOG_DIR/$1.log"
	# 短等待直至进程消失（防 fork 竞争残留）
	while [ "$i" -lt 20 ]; do
		svc_running "$name" || break
		sleep 0.2
		i=$((i + 1))
	done
	rm -f "$pidf"
	[ -n "$was_running" ] && run_end_cmd "$name"
	return 0
}

# 服务停止后执行收尾命令：查服务行末段 end_cmd，整段 dec_js 还原真换行后一次 su -c 执行
# （与启动 cmd 同模型，函数/while/if 多行块合法；非常驻不追加 ; wait），身份与工作目录同 launch_svc。
run_end_cmd() {
	local name=$1 row endcmd="" extra="" su_bin rc
	[ -n "$LOAD_CFG_DONE" ] || load_cfg_sh
	row=$(pick_termux "$name")
	[ -n "$row" ] || row=$(pick_binary "$name")
	[ -n "$row" ] || return 0
	# 取末段：heredoc read 末变量保留原始分隔符（end_cmd 可含 |）
	IFS='|' read -r _ _ _ _ endcmd <<EOF
$row
EOF
	[ -n "$endcmd" ] || return 0
	case "$endcmd" in *\\*) endcmd=$(printf '%s' "$endcmd" | dec_js) ;; esac
	printf '%s\n' "$endcmd" | grep -q '[^[:space:]]' || return 0
	# 非 root 名单的 termux 服务降权至 Termux 用户（binary 与 root 名单服务本就是 root）
	if printf '%s\n' "$row" | grep -q '^termux|' && ! name_in_set "$name" "$TERMUX_ROOT_NAMES"; then
		extra=$(termux_user_args)
	fi
	su_bin=$(get_su_bin) || { echo "[$(date '+%F %T')] $(ui_msg '收尾 %s 跳过：su 不可用' "$name")" >> "$LOG_DIR/stop.log"; return 0; }
	{
		echo "$(ui_msg '=== 执行 %s 收尾命令 %s ===' "$name" "$(date '+%F %T')")"
		if printf '%s\n' "$row" | grep -q '^termux|'; then
			"$su_bin" $extra -c "$TERMUX_ENV cd $TERMUX_HOME; $endcmd" 2>&1
		else
			"$su_bin" -c "cd \"$SERVER_DIR\" 2>/dev/null; $endcmd" 2>&1
		fi
		rc=$?
		echo "[exit=$rc]"
	} >> "$LOG_DIR/stop.log" 2>&1
	return 0
}

# 停止配置中已被删除的服务：对比新旧两类行列表，旧有新无且仍在运行则停
stop_removed_services() {
	local old_ts=$1 new_ts=$2 old_sv=$3 new_sv=$4 name
	{
		printf '%s\n' "$old_ts" | list_names
		printf '%s\n' "$old_sv" | list_names
	} | sort -u | while IFS= read -r name; do
		[ -n "$name" ] || continue
		printf '%s\n' "$new_ts" | awk -F'|' -v n="$name" '$1==n{found=1; exit} END{exit !found}' && continue
		printf '%s\n' "$new_sv" | awk -F'|' -v n="$name" '$1==n{found=1; exit} END{exit !found}' && continue
		svc_running "$name" && stop_svc "$name"
	done
}

# 停止全部已配置服务（$1=可选排除名单，熄屏白名单传入；缺省=全停，disable/定时窗调用不变）
stop_all() {
	local ex=$1 name
	[ -n "$LOAD_CFG_DONE" ] || load_services
	printf '%s\n' "$TERMUX_SERVICES" | while IFS='|' read -r name port auto cmd endcmd; do
		[ -n "$name" ] || continue
		[ -n "$ex" ] && name_in_set "$name" "$ex" && continue
		stop_svc "$name"
	done
	printf '%s\n' "$BINARY_SERVICES" | while IFS='|' read -r name port auto cmd endcmd; do
		[ -n "$name" ] || continue
		[ -n "$ex" ] && name_in_set "$name" "$ex" && continue
		stop_svc "$name"
	done
}

# ---------- 配置加载 ----------

# 读 setting.conf 到设置类全局变量（不碰服务行；# 注释与空行忽略，值经 dec_js 还原）。
load_settings() {
	local f="$SETTING_FILE" line k v CR
	CR=$(printf '\r')
	SLEEP_INTERVAL=""; SERVER_DIR=""; BOOT_COMMANDS=""
	WIFI_SERVICE_ENABLED=""; WIFI_SERVICE_NAMES=""; WIFI_SERVICE_NAMES_OFF=""; WIFI_SSIDS=""
	SCHEDULE_ENABLED=""; SCHEDULE_STOP=""; SCHEDULE_START=""
	SCREEN_SERVICE_ENABLED=""; SCREEN_SERVICE_NAMES=""; SCREEN_RESUME_NAMES=""
	TERMUX_ROOT_NAMES=""
	PATROL_ENABLED=""
	UI_LANG=""
	WEBUI_ENABLED=""; WEBUI_PASSWORD_HASH=""; WEBUI_TOKEN=""
	[ -f "$f" ] || return 0
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in *"$CR") line=${line%"$CR"} ;; esac
		case "$line" in ''|'#'*) continue ;; esac
		k=${line%%=*}
		case "$k" in
		sleep_interval|server_dir|boot_commands|wifi_service_enabled|wifi_service_names|wifi_service_names_off|wifi_ssids|schedule_enabled|schedule_stop|schedule_start|screen_service_enabled|screen_service_names|screen_resume_names|termux_root_names|patrol_enabled|language|webui_enabled|webui_password_hash|webui_token) ;;
		*) continue ;;
		esac
		v=${line#*=}
		[ "$line" = "$k" ] && v=""
		case "$v" in *\\*) v=$(printf '%s' "$v" | dec_js) ;; esac
		case "$k" in
		sleep_interval) SLEEP_INTERVAL=$v ;;
		server_dir) SERVER_DIR=$v ;;
		boot_commands) BOOT_COMMANDS=$v ;;
		wifi_service_enabled) WIFI_SERVICE_ENABLED=$v ;;
		wifi_service_names) WIFI_SERVICE_NAMES=$v ;;
		wifi_service_names_off) WIFI_SERVICE_NAMES_OFF=$v ;;
		wifi_ssids) WIFI_SSIDS=$v ;;
		schedule_enabled) SCHEDULE_ENABLED=$v ;;
		schedule_stop) SCHEDULE_STOP=$v ;;
		schedule_start) SCHEDULE_START=$v ;;
		screen_service_enabled) SCREEN_SERVICE_ENABLED=$v ;;
		screen_service_names) SCREEN_SERVICE_NAMES=$v ;;
		screen_resume_names) SCREEN_RESUME_NAMES=$v ;;
		termux_root_names) TERMUX_ROOT_NAMES=$v ;;
		patrol_enabled) PATROL_ENABLED=$v ;;
		language) UI_LANG=$v ;;
		webui_enabled) WEBUI_ENABLED=$v ;;
		webui_password_hash) WEBUI_PASSWORD_HASH=$v ;;
		webui_token) WEBUI_TOKEN=$v ;;
		esac
	done < "$f"
}

# 单键读 setting.conf（明文；不存在/无该键输出空）。
setting_get() {
	local key=$1 f="$SETTING_FILE" line k v CR
	CR=$(printf '\r')
	[ -f "$f" ] || return 0
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in *"$CR") line=${line%"$CR"} ;; esac
		case "$line" in ''|'#'*) continue ;; esac
		k=${line%%=*}
		[ "$k" = "$key" ] || continue
		v=${line#*=}
		[ "$line" = "$k" ] && v=""
		case "$v" in *\\*) v=$(printf '%s' "$v" | dec_js) ;; esac
		printf '%s' "$v"
		return 0
	done < "$f"
}

# 校验后的行（5 段 name|port|auto|cmd|end_cmd）追加到对应内存变量；binary 段数不足视为非法
append_row() {
	local rest=$2
	case "$1" in
	termux)
		if [ -n "$TERMUX_SERVICES" ]; then TERMUX_SERVICES="$TERMUX_SERVICES
$rest"; else TERMUX_SERVICES=$rest; fi
		;;
	binary)
		case "$rest" in
		*\|*\|*\|*\|*) : ;;
		*) sup_log "$(ui_msg 'services.conf 非法行(binary段数不足)：%s' "$rest")"; return 1 ;;
		esac
		if [ -n "$BINARY_SERVICES" ]; then BINARY_SERVICES="$BINARY_SERVICES
$rest"; else BINARY_SERVICES=$rest; fi
		;;
	esac
}

# 读 services.conf 到 TERMUX_SERVICES / BINARY_SERVICES（去首段 type；非法行跳过记日志）。
# 首行 # svc-v1.4.0 为格式标记（end_cmd 恒末段，cmd 禁 |）：
#   新 6 段 type|name|port|auto|cmd|end_cmd 原样入内存 5 段；
#   旧 5 段（标记 v1.3.6）补空 end_cmd；更旧 6 段（无标记，第 3 段 extra）丢 extra 补空 end_cmd，写回自动升级。
load_services() {
	local f="$SERVICES_FILE" line type rest name _r1 CR BOM TAB first fmt n1 n2 n3 n4 n5
	CR=$(printf '\r')
	BOM=$(printf '\357\273\277')
	TAB=$(printf '\t')
	TERMUX_SERVICES=""; BINARY_SERVICES=""
	[ -f "$f" ] || return 0
	fmt=""
	IFS= read -r first < "$f"
	case "$first" in *"$CR") first=${first%"$CR"} ;; esac
	case "$first" in "$BOM"*) first=${first#"$BOM"} ;; esac
	case "$first" in '# svc-v1.4.0'*) fmt=v14 ;; '# svc-v1.3.6'*) fmt=v136 ;; esac
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in *"$CR") line=${line%"$CR"} ;; esac
		# 清行首 BOM/空格/Tab，否则 type 带前缀全量判非法
		case "$line" in "$BOM"*) line=${line#"$BOM"} ;; esac
		while :; do
			case "$line" in
			' '*|"$TAB"*) line=${line#?} ;;
			*) break ;;
			esac
		done
		case "$line" in ''|'#'*) continue ;; esac
		case "$line" in
		*'|'*) : ;;
		*) sup_log "$(ui_msg 'services.conf 非法行(无|分隔)：%s' "$line")"; continue ;;
		esac
		# heredoc read 切段（末变量保留原始分隔符）：裸竖线 ${var%%|*} 模式在设备 shell 返回空，会全量判非法
		IFS='|' read -r type rest <<SVCEOF
$line
SVCEOF
		case "$fmt" in
		v14)
			# 新 6 段：rest = name|port|auto|cmd|end_cmd 原样保留（end_cmd 恒末段可含 |）
			;;
		v136)
			# 旧 5 段（cmd 为末段）：补空 end_cmd；够 4 段才迁移
			case "$rest" in
			*\|*\|*\|*)
				IFS='|' read -r n1 n2 n3 n4 <<SVCEOF
$rest
SVCEOF
				rest="$n1|$n2|$n3|$n4|"
				;;
			esac
			;;
		*)
			# 更旧 6 段（第 3 段 extra）：丢 extra，补空 end_cmd
			case "$rest" in
			*\|*\|*\|*\|*)
				IFS='|' read -r n1 n2 n3 n4 n5 <<SVCEOF
$rest
SVCEOF
				rest="$n1|$n2|$n4|$n5|"
				;;
			esac
			;;
		esac
		IFS='|' read -r name _r1 <<SVCEOF
$rest
SVCEOF
		valid_name "$name" || { sup_log "$(ui_msg 'services.conf 非法行(名称[%s]字节=%s)：%s' "$name" "$(printf '%s' "$name" | od -An -tx1 2>/dev/null | tr -d ' \n')" "$line")"; continue; }
		case "$type" in
		termux|binary) append_row "$type" "$rest" || continue ;;
		*) sup_log "$(ui_msg 'services.conf 非法行(类型[%s])非termux/binary：%s' "$type" "$line")" ;;
		esac
	done < "$f"
}

# 同进程加载全部配置（同进程重复 load 免重复读文件，写操作清标记）。
load_cfg_sh() {
	[ -n "$LOAD_CFG_DONE" ] && return 0
	load_settings
	load_services

	[ -n "$SLEEP_INTERVAL" ] || SLEEP_INTERVAL=60
	is_int "$SLEEP_INTERVAL" || SLEEP_INTERVAL=60
	# 保活间隔最小 10 秒，最大 86400 秒
	[ "$SLEEP_INTERVAL" -lt 10 ] && SLEEP_INTERVAL=10
	[ "$SLEEP_INTERVAL" -gt 86400 ] && SLEEP_INTERVAL=86400

	[ -n "$SERVER_DIR" ] || SERVER_DIR="$DEFAULT_SERVER_DIR"
	# 联调覆盖：mock 沙盒的 server_dir 若为设备路径则回退沙盒（PC 上不存在会 return 2）
	if [ -n "$SVCHUB_SERVER_DIR" ]; then
		( cd "$SERVER_DIR" 2>/dev/null ) || SERVER_DIR="$SVCHUB_SERVER_DIR"
	fi

	[ "$WIFI_SERVICE_ENABLED" = "1" ] || WIFI_SERVICE_ENABLED="0"

	[ "$SCHEDULE_ENABLED" = "1" ] || SCHEDULE_ENABLED="0"

	[ "$SCREEN_SERVICE_ENABLED" = "1" ] || SCREEN_SERVICE_ENABLED="0"

	# 自动巡检：缺键默认开启，显式 0 保留（老配置升级兼容）。
	if [ -z "$PATROL_ENABLED" ]; then
		PATROL_ENABLED="1"
	elif [ "$PATROL_ENABLED" != "0" ] && [ "$PATROL_ENABLED" != "1" ]; then
		PATROL_ENABLED="1"
	fi

	# 界面语言：缺键/空/非法按中文，与改前行为一致。
	case "$UI_LANG" in zh|en) ;; *) UI_LANG=zh ;; esac

	# 缺键默认开启，显式 0 保留。
	if [ -z "$WEBUI_ENABLED" ]; then
		WEBUI_ENABLED="1"
	elif [ "$WEBUI_ENABLED" != "0" ] && [ "$WEBUI_ENABLED" != "1" ]; then
		WEBUI_ENABLED="1"
	fi

	# 空哈希填默认 admin 哈希并标记落盘。
	# 盐随机生成（非固定盐），落盘后全设备各异，重启一致。
	WEBUI_PASSWORD_HASH_NEED_SAVE=""
	if [ -z "$WEBUI_PASSWORD_HASH" ] && [ -z "$WEBUI_PASSWORD_HASH_DONE" ]; then
		WEBUI_PASSWORD_HASH_SALT=$(webui_gen_token | head -c 32)
		if [ "${#WEBUI_PASSWORD_HASH_SALT}" -eq 32 ]; then
			WEBUI_PASSWORD_HASH=$(printf '%s' admin | webui_hash_password "$WEBUI_PASSWORD_HASH_SALT")
		fi
		if [ -n "$WEBUI_PASSWORD_HASH" ]; then
			WEBUI_PASSWORD_HASH_NEED_SAVE=1
		else
			WEBUI_PASSWORD_HASH=""
		fi
		WEBUI_PASSWORD_HASH_DONE=1
	fi

	# 缺键才补键（ensure 内部幂等：齐全只读不写，仅作用旧 config.json 迁移前）；新 setting 缺键由 load_settings 默认值覆盖。
	LOAD_CFG_DONE=1
}

# 按名称从配置取整行（awk 保留 cmd 中的 |；返回整行 $0）
pick_termux() {
	printf '%s\n' "$TERMUX_SERVICES" | awk -F'|' -v n="$1" '$1==n { print; exit }'
}

pick_binary() {
	printf '%s\n' "$BINARY_SERVICES" | awk -F'|' -v n="$1" '$1==n { print; exit }'
}

# ---------- 定时启停 ----------

# 定时专用日志（独立于 supervisor.log，WebUI 日志按钮读取 SCHED_LOG_NAME）
SCHED_LOG_NAME="schedule"
SCHED_LOG="$LOG_DIR/$SCHED_LOG_NAME.log"
# 停止窗状态（内存态）：1=当前在停止窗内，巡检与 Wi-Fi 启动分支均跳过
SCHED_IN_WINDOW="0"

sched_log() {
	[ -n "$1" ] || return 0
	echo "[$(date '+%F %T')] $1" >> "$SCHED_LOG"
}

# 亮屏启停专用日志（独立于 supervisor.log，WebUI 日志按钮读取 SCREEN_LOG_NAME）
SCREEN_LOG_NAME="screen"
SCREEN_LOG="$LOG_DIR/$SCREEN_LOG_NAME.log"

screen_log() {
	[ -n "$1" ] || return 0
	echo "[$(date '+%F %T')] $1" >> "$SCREEN_LOG"
}

# 纯判定：当前 now 是否落在 [stop, start) 停止窗内；返回 0=在窗内，1=窗外。
# $1=stop(HH:MM) $2=start(HH:MM) $3=now(HH:MM)；无副作用，可直接单元测试。
# 跨夜（stop > start）视为 [stop,24:00)∪[00:00,start)；stop==start 或任一非法视为窗外。
sched_in_window() {
	local stop_h stop_m start_h start_m now_h now_m stop start now
	case "$1" in
		[0-2][0-9]:[0-5][0-9]) ;;
		*) return 1 ;;
	esac
	case "$2" in
		[0-2][0-9]:[0-5][0-9]) ;;
		*) return 1 ;;
	esac
	case "$3" in
		[0-2][0-9]:[0-5][0-9]) ;;
		*) return 1 ;;
	esac
	stop_h=${1%%:*}; stop_m=${1#*:}
	start_h=${2%%:*}; start_m=${2#*:}
	now_h=${3%%:*}; now_m=${3#*:}
	[ "$stop_h" -le 23 ] 2>/dev/null || return 1
	[ "$start_h" -le 23 ] 2>/dev/null || return 1
	[ "$now_h" -le 23 ] 2>/dev/null || return 1
	# 去前导零后再算术（POSIX sh 无 10# 前缀，08/09 会被当八进制报错）
	stop_h=${stop_h#0}; start_h=${start_h#0}; now_h=${now_h#0}
	stop_m=${stop_m#0}; start_m=${start_m#0}; now_m=${now_m#0}
	[ -n "$stop_h" ] || stop_h=0; [ -n "$start_h" ] || start_h=0; [ -n "$now_h" ] || now_h=0
	[ -n "$stop_m" ] || stop_m=0; [ -n "$start_m" ] || start_m=0; [ -n "$now_m" ] || now_m=0
	stop=$((stop_h * 60 + stop_m)); start=$((start_h * 60 + start_m)); now=$((now_h * 60 + now_m))
	[ "$stop" -eq "$start" ] && return 1
	if [ "$stop" -lt "$start" ]; then
		[ "$now" -ge "$stop" ] && [ "$now" -lt "$start" ] && return 0 || return 1
	else
		[ "$now" -ge "$stop" ] || [ "$now" -lt "$start" ] && return 0 || return 1
	fi
}

# ---------- Wi-Fi 策略控制 ----------

# Wi-Fi 专用日志（独立于 supervisor.log，WebUI 日志按钮读取 WIFI_LOG_NAME）
WIFI_LOG_NAME="wifi"
WIFI_LOG="$LOG_DIR/$WIFI_LOG_NAME.log"
# 最近一次策略计算的上下文（供日志输出），由 calc_wifi_policy 刷新
WIFI_LOG_CONNECTED=""
WIFI_LOG_SSID_MATCH=""
WIFI_LOG_SSID=""
WIFI_LOG_NETID=""

wifi_log() {
	[ -n "$1" ] || return 0
	echo "[$(date '+%F %T')] $1" >> "$WIFI_LOG"
}

wifi_log_connected_text() {
	[ "$WIFI_LOG_CONNECTED" = "1" ] && printf '%s' "$(ui_msg 已连接)" || printf '%s' "$(ui_msg 已断开)"
}

wifi_log_match_text() {
	case "$WIFI_LOG_SSID_MATCH" in
		1) printf '%s' "$(ui_msg 'SSID匹配')" ;;
		0) printf '%s' "$(ui_msg '无SSID匹配')" ;;
		*) printf '%s' "$(ui_msg 'SSID未检测')" ;;
	esac
}

wifi_log_ssid_text() {
	if [ -z "$WIFI_LOG_SSID" ]; then
		printf '%s' "$(ui_msg '(空)')"
	elif [ -n "$WIFI_LOG_NETID" ]; then
		printf '%s' "$(ui_msg '%s（netId %s）' "$WIFI_LOG_SSID" "$WIFI_LOG_NETID")"
	else
		printf '%s' "$WIFI_LOG_SSID"
	fi
}

# 名单拼接展示用：压连续空格并去首尾（sync 日志合并行共用）
wifi_trim_list() {
	printf '%s' "$1" | sed 's/  */ /g;s/^ //;s/ $//'
}

# 检查 Wi-Fi 是否已连接
wifi_connected() {
	# 沙盒联调：mock_wifi 行1 = on/off，直读绕开 dumpsys（文件不存在按未连接）
	if [ "$SVCHUB_MOCK" = "1" ]; then
		[ "$(sed -n '1p' "$MODDIR/mock_wifi" 2>/dev/null)" = "on" ] && return 0
		return 1
	fi
	# 1. dumpsys connectivity：WIFI 类型 NetworkAgentInfo 且状态 CONNECTED
	if dumpsys connectivity 2>/dev/null | grep -A 5 "NetworkAgentInfo{type: WIFI" | grep -q "state: CONNECTED"; then
		return 0
	fi
	# 2. 兜底：默认网络是 Wi-Fi（部分系统版本 NetworkAgentInfo 的 state 字段不在附近）
	if dumpsys connectivity 2>/dev/null | grep -q "Default network:.*WIFI"; then
		return 0
	fi
	# 3. 兜底：wlan0 接口有 IPv4
	if ip addr show dev wlan0 2>/dev/null | grep -q "inet "; then
		return 0
	fi
	return 1
}

# 获取当前 SSID（带 60 秒缓存，避免高频 fork）。
# 结果写入副作用变量 WIFI_SSID_NOW（netId 写入 WIFI_LOG_NETID）；
# 调用方直接用变量而非命令替换，因为命令替换会 fork 子 shell，
# 子 shell 里的缓存赋值会丢失，导致缓存永远不生效。
# SSID 可能含中文/空格/全角符号/emoji：解析时只做行内提取与首尾空白清理，
# 不对字符集做任何过滤；比较时按字节精确匹配，不区分大小写之外的任何归一化。
wifi_current_ssid_cached() {
	# 沙盒联调：mock_wifi 行2 = SSID，直读无缓存（改文件下一轮巡检即生效）
	if [ "$SVCHUB_MOCK" = "1" ]; then
		WIFI_SSID_NOW=$(sed -n '2p' "$MODDIR/mock_wifi" 2>/dev/null)
		WIFI_LOG_NETID=""
		return 0
	fi
	local now cache_time=60
	now=$(date +%s)
	if [ -n "$WIFI_SSID_CACHE_TIME" ] && [ $((now - WIFI_SSID_CACHE_TIME)) -lt "$cache_time" ]; then
		WIFI_SSID_NOW=$WIFI_SSID_CACHE
		return 0
	fi

	local raw ssid="" netid="" first=""
	# 来源优先级（真机验证）：dumpsys wifi 的 mWifiInfo 行（SSID 字段带引号且值正确）
	# > dumpsys wifi 首个 SSID 行 > cmd wifi status（部分 ROM 会把 SSID 字段填成 BSSID，
	# 真实名称以引号形式出现在行内其他位置，引号提取仍可命中）。
	# 提取策略：行内带引号优先取第一个引号值；完全无引号才按 SSID: 字段提取。
	raw=$(dumpsys wifi 2>/dev/null | grep -i "mWifiInfo" | head -n 1)
	[ -z "$raw" ] && raw=$(dumpsys wifi 2>/dev/null | grep -m 1 "SSID:")
	[ -z "$raw" ] && raw=$(cmd wifi status 2>/dev/null | grep -i "SSID:" | head -n 1)
	if printf '%s' "$raw" | grep -q '"'; then
		ssid=$(printf '%s' "$raw" | sed -n 's/[^"]*"\([^"]*\)".*/\1/p')
	else
		ssid=$(printf '%s' "$raw" | sed 's/.*[Ss][Ss][Ii][Dd]:[[:space:]]*//; s/"[[:space:]].*//; s/"$//')
	fi

	# 顺带提取该网络的系统 ID（netId/Net ID，来自同一行；拿不到则日志只显示名称）
	netid=$(printf '%s' "$raw" | grep -io 'net[ ]*id[:= ]*[0-9]*' | head -n 1 | tr -dc '0-9')

	# 过滤无效值：未知占位（大小写不敏感），清理残留回车与首尾空白（含全角空格）
	case "$ssid" in
		'<'*) ssid='' ;;
		*unknown*ssid*|*ssid*unknown*) ssid='' ;;
	esac
	ssid=$(printf '%s' "$ssid" | tr -d '\r\n' | sed 's/^[[:space:]　]*//;s/[[:space:]　]*$//')
	# 首段（空格/逗号前）为 MAC 形态 → 该 ROM 将 SSID 字段填成了 BSSID，视为无效
	first=${ssid%%[ ,]*}
	case "$first" in
		[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]) ssid='' ;;
	esac

	WIFI_SSID_CACHE="$ssid"
	WIFI_SSID_NOW="$ssid"
	WIFI_SSID_CACHE_TIME="$now"
	WIFI_LOG_NETID="$netid"
}

# 检查当前 SSID 是否匹配配置的 SSID 列表
# - 列表为空 = 任意 WiFi 均可；获取不到 SSID = 不匹配（fail-closed）
# - 配置行仅去掉行首尾空白与空行（手工编辑 config.json 的容错），匹配仍为整行精确字节比较
# - 仅剔除含 | 的行（与存储分隔符冲突），其余字符一律允许
wifi_ssid_match() {
	local current_ssid=$1 ssids=$2
	# 列表为空表示任意 WiFi 均可
	[ -z "$ssids" ] && return 0
	# 获取不到 SSID 视为不匹配
	[ -z "$current_ssid" ] && return 1

	printf '%s\n' "$ssids" | grep -v '|' | sed 's/^[[:space:]　]*//;s/[[:space:]　]*$//' | grep -v '^$' | grep -qxF -- "$current_ssid"
}

# 计算 Wi-Fi 策略状态 (disabled / allow / block)，同时刷新日志上下文：
# WIFI_LOG_CONNECTED=未连接/已连接，WIFI_LOG_SSID_MATCH=未检测/匹配/不匹配
# WIFI_LOG_SSID=当前连接的 Wi-Fi 名称，WIFI_LOG_NETID=该网络的系统 ID
calc_wifi_policy() {
	WIFI_LOG_CONNECTED=""
	WIFI_LOG_SSID_MATCH=""
	WIFI_LOG_SSID=""
	if [ "$WIFI_SERVICE_ENABLED" != "1" ]; then
		WIFI_POLICY="disabled"
		return
	fi

	if ! wifi_connected; then
		WIFI_LOG_CONNECTED=0
		WIFI_POLICY="block"
		return
	fi
	WIFI_LOG_CONNECTED=1

	# 如果未配置 SSID 白名单，连接即允许
	if [ -z "$WIFI_SSIDS" ]; then
		WIFI_LOG_SSID_MATCH=1
		WIFI_POLICY="allow"
		return
	fi

	# 直接调用（不用命令替换），读取副作用变量 WIFI_SSID_NOW
	wifi_current_ssid_cached
	WIFI_LOG_SSID=$WIFI_SSID_NOW
	if wifi_ssid_match "$WIFI_SSID_NOW" "$WIFI_SSIDS"; then
		WIFI_LOG_SSID_MATCH=1
		WIFI_POLICY="allow"
	else
		WIFI_LOG_SSID_MATCH=0
		WIFI_POLICY="block"
	fi
}

# 巡检启动前的 Wi-Fi 策略兜底：返回 0=跳过启动。
# block（Wi-Fi 不满足）时跳过连接组名单；allow（已连接）时跳过断开组名单，
# 防止普通巡检重新拉起刚被 Wi-Fi 策略停掉的服务。
wifi_should_skip() {
	case "$WIFI_POLICY" in
		block) name_in_set "$1" "$WIFI_SERVICE_NAMES" && return 0 ;;
		allow) name_in_set "$1" "$WIFI_SERVICE_NAMES_OFF" && return 0 ;;
	esac
	return 1
}

# 高危命令拦截（交互执行入口用，防手滑非安全边界）：逐行扫描，输出首个命中行（空=全部放行）。
# 只拦明确无误伤的模式：删根（rm -rf / 结尾/尾空格/glob 星）、mkfs、写块设备、fork 炸弹；
# 局部清理（如 rm -rf /data/local/tmp/x）、含 ":() " 文本的 echo 均放行。
dangerous_line() {
	printf '%s\n' "$1" | grep -m1 -E 'rm -[rf]{2} /( |$|\*)|mkfs|of=/dev/block|:\(\)\{'
}

# 锁屏检测：window/power 多字段任一命中即锁屏（兼容各 ROM），检测不到按未锁（fail-open）
keyguard_locked() {
	# 沙盒联调：mock_screen 行2 = lock/unlock，直读绕开 dumpsys（无文件走真检测）
	if [ "$SVCHUB_MOCK" = "1" ] && [ -f "$MODDIR/mock_screen" ]; then
		[ "$(sed -n '2p' "$MODDIR/mock_screen" 2>/dev/null)" = "lock" ] && return 0
		return 1
	fi
	case "$(dumpsys window 2>/dev/null | grep -m1 -iE 'mDreamingLockscreen|mKeyguardShowing|mKeyguardGoingAway')" in
	*true*) return 0 ;;
	esac
	case "$(dumpsys power 2>/dev/null | grep -m1 -i 'mInputRestricted')" in
	*true*) return 0 ;;
	esac
	return 1
}

# 亮屏解锁门控：calc_screen_state 后判定 SCREEN_UNLOCK_OK（功能关/熄屏不在此拦截启动）
refresh_screen_gate() {
	calc_screen_state
	SCREEN_UNLOCK_OK=1
	[ "$SCREEN_SERVICE_ENABLED" = "1" ] || return 0
	#亮屏但锁屏（通知/抬手亮屏）不放行；解锁即放行
	if [ "$SCREEN_ON" = "1" ] && keyguard_locked; then
		SCREEN_UNLOCK_OK=0
	fi
}

# 启动禁令统一判定（单点）：阻断时输出原因并返回 0，放行输出空返回 1。
# $2=1 豁免解锁禁令（Wi-Fi 无人值守）。定时窗禁启 > 熄屏仅白名单可启 > 亮屏未解锁禁启。
starts_blocked_reason() {
	[ "$SCHED_IN_WINDOW" = "1" ] && { printf '%s' "$(ui_msg '定时停止窗内')"; return 0; }
	if [ "$2" != "1" ] && [ "$SCREEN_SERVICE_ENABLED" = "1" ] && [ "$SCREEN_UNLOCK_OK" != "1" ]; then
		printf '%s' "$(ui_msg '亮屏未解锁，暂不拉起')"; return 0
	fi
	if [ "$SCREEN_SERVICE_ENABLED" = "1" ] && [ "$SCREEN_ON" != "1" ]; then
		name_in_set "$1" "$SCREEN_SERVICE_NAMES" || { printf '%s' "$(ui_msg '熄屏非白名单')"; return 0; }
	fi
	return 1
}

# Wi-Fi 无人值守启动专用门控：豁免亮屏未解锁禁令（到家/离家场景手机锁屏也要能起），定时窗/熄屏禁令不变。
# 输出原因文案（空=放行），调用方按实际原因记录
starts_blocked_wifi() {
	starts_blocked_reason "$1" 1
}

# 屏幕亮灭判定：设 SCREEN_ON（1=亮屏 0=熄屏）；开关关闭首行短路零 fork。
# 主判据 dumpsys power 的 mWakefulness，回退一 dumpsys display 的 mScreenState，
# 回退二 Display Power: state（老设备）；全解析不到按亮屏（fail-open，误停车比
# 不停车危害大）且只警告一次。直接赋值不用命令替换（子 shell 丢变量）。
calc_screen_state() {
	local pwr disp
	[ "$SCREEN_SERVICE_ENABLED" = "1" ] || { SCREEN_ON=1; return 0; }
	# 沙盒联调：mock_screen 行1 = on/off，直读绕开 dumpsys（文件不存在按亮屏）
	if [ "$SVCHUB_MOCK" = "1" ]; then
		[ "$(sed -n '1p' "$MODDIR/mock_screen" 2>/dev/null)" = "off" ] && { SCREEN_ON=0; return 0; }
		SCREEN_ON=1; return 0
	fi
	pwr=$(dumpsys power 2>/dev/null)
	case "$pwr" in
	*mWakefulness=Awake*) SCREEN_ON=1; return 0 ;;
	*mWakefulness=Asleep*|*mWakefulness=Dozing*|*mWakefulness=Dreaming*) SCREEN_ON=0; return 0 ;;
	esac
	disp=$(dumpsys display 2>/dev/null)
	case "$disp" in
	*mScreenState=ON*) SCREEN_ON=1; return 0 ;;
	*mScreenState=OFF*) SCREEN_ON=0; return 0 ;;
	esac
	case "$pwr" in
	*'Display Power: state=ON'*) SCREEN_ON=1; return 0 ;;
	*'Display Power: state=OFF'*) SCREEN_ON=0; return 0 ;;
	esac
	SCREEN_ON=1
	if [ -z "$SCREEN_WARNED" ]; then
		screen_log "$(ui_msg '无法检测屏幕状态（dumpsys 无匹配字段），按亮屏处理')"
		SCREEN_WARNED=1
	fi
	return 0
}

# Wi-Fi 启动段：窗内边沿说明/门控筛选/两类启动执行。$1=组名 $2=清洗后名单
wifi_sync_starts() {
	local group=$1 names_list=$2 name row port auto cmd reason
	local t_start="" b_start="" missing="" blocked=""
	if [ "$SCHED_IN_WINDOW" = "1" ]; then
		# 定时窗优先级高于 Wi-Fi 启动：窗内不启动，仅首次说明（边沿化防刷屏）
		if [ -z "$WIFI_WINDOW_NOTED" ] && [ -n "$names_list" ]; then
			WIFI_WINDOW_NOTED=1
			wifi_log "$(ui_msg '定时停止窗内，%s暂停启动' "$group")"
		fi
		return 0
	fi
	WIFI_WINDOW_NOTED=""
	for name in $names_list; do
		valid_name "$name" || continue
		svc_running "$name" && continue
		# 启动禁令：按实际原因记录（Wi-Fi 无人值守豁免解锁禁令，见 starts_blocked_wifi）
		if reason=$(starts_blocked_wifi "$name"); then
			blocked="$blocked $name（$reason）"
			continue
		fi
		if [ -n "$(pick_termux "$name")" ]; then
			t_start="$t_start $name"
		elif [ -n "$(pick_binary "$name")" ]; then
			b_start="$b_start $name"
		else
			missing="$missing $name"
		fi
	done
	[ -n "$blocked" ] && wifi_log "$(ui_msg '按门控暂停启动：%s' "$(wifi_trim_list "$blocked")")"
	# 两类服务合并一行输出（Termux 在前），执行仍按类型分开
	if [ -n "$t_start" ] || [ -n "$b_start" ]; then
		wifi_log "$(ui_msg '启动%s：%s' "$group" "$(wifi_trim_list "$t_start $b_start")")"
	fi
	for name in $t_start; do
		row=$(pick_termux "$name")
		IFS='|' read -r _ port auto cmd endcmd <<EOF
$row
EOF
		launch_svc termux "$name" "$cmd"
	done
	for name in $b_start; do
		row=$(pick_binary "$name")
		IFS='|' read -r _ port auto cmd endcmd <<EOF
$row
EOF
		launch_svc binary "$name" "$cmd"
	done
	[ -n "$missing" ] && wifi_log "$(ui_msg '不在服务配置中，跳过：%s' "$(wifi_trim_list "$missing")")"
	return 0
}

# Wi-Fi 停止段：无条件停止（停止不经门控）。$1=组名 $2=清洗后名单
wifi_sync_stops() {
	local group=$1 names_list=$2 name stops=""
	for name in $names_list; do
		valid_name "$name" || continue
		svc_running "$name" && stops="$stops $name"
	done
	if [ -n "$stops" ]; then
		wifi_log "$(ui_msg '停止%s：%s' "$group" "$(wifi_trim_list "$stops")")"
		for name in $stops; do
			stop_svc "$name"
		done
	fi
	return 0
}

# 根据策略同步受管服务的启停
# $1=策略(allow/block/disabled) $2=模式(on=连接组，allow起/block停；off=断开组，反向：allow停/block起)
# 重叠规则：同一服务同时在两组时连接组优先，断开组跳过并记警告。
sync_wifi_service_policy() {
	local new_policy=$1 mode=${2:-on} name
	local group target_names on_names

	if [ "$mode" = "off" ]; then
		group="$(ui_msg '断开组')"
		target_names=$WIFI_SERVICE_NAMES_OFF
		on_names=$WIFI_SERVICE_NAMES
	else
		group="$(ui_msg '连接组')"
		target_names=$WIFI_SERVICE_NAMES
		on_names=""
	fi

	# 策略变化记录到 Wi-Fi 专属日志（含上下文），supervisor 日志不再记录
	# 两组共享同一策略，变化行只记一次（由 on 分支记录，off 分支跳过）
	if [ "$mode" = "on" ] && [ "$new_policy" != "$WIFI_POLICY_PREV" ]; then
		# 状态行：直接呈现当前连接态与匹配结果
		if [ "$new_policy" = "disabled" ]; then
			wifi_log "$(ui_msg 'Wi-Fi 启停已关闭')"
		else
			wifi_log "$(ui_msg 'WiFi %s（%s）' "$(wifi_log_connected_text)" "$(wifi_log_match_text)")"
			# 已配置白名单且已连接时，输出当前 Wi-Fi 名称（及 netId），方便排查匹配失败；
			# 白名单为空（任意 WiFi）时不获取 SSID，跳过该行避免输出无意义的 (空)
			[ "$WIFI_LOG_CONNECTED" = "1" ] && [ -n "$WIFI_SSIDS" ] && \
				wifi_log "$(ui_msg '当前 Wi-Fi：%s' "$(wifi_log_ssid_text)")"
		fi
		WIFI_POLICY_PREV="$new_policy"
	fi

	[ "$new_policy" = "disabled" ] && return 0
	[ -z "$target_names" ] && return 0

	# 服务名仅含字母数字点横线，不含空格，可安全转为空格分隔的单行列表进行 for 遍历
	local names_list
	names_list=$(printf '%s\n' "$target_names" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | tr '\n' ' ')

	# 断开组重叠检查：已在连接组的服务归连接组，断开组跳过并记警告
	if [ "$mode" = "off" ] && [ -n "$on_names" ]; then
		local on_list clean_list="" dup=""
		on_list=$(printf '%s\n' "$on_names" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | tr '\n' ' ')
		for name in $names_list; do
			case " $on_list " in
			*" $name "*) dup="$dup $name" ;;
			*) clean_list="$clean_list $name" ;;
			esac
		done
		names_list=$clean_list
		[ -n "$dup" ] && wifi_log "$(ui_msg '断开组服务%s 同时在连接组，已按连接组处理' "$(wifi_trim_list "$dup")")"
	fi

	# 断开组语义与连接组完全反向：allow=Wi-Fi 连上=断开组停、block=Wi-Fi 断开=断开组起
	local do_start do_stop
	if [ "$mode" = "off" ]; then
		if [ "$new_policy" = "allow" ]; then do_start=""; do_stop=1; else do_start=1; do_stop=""; fi
	else
		if [ "$new_policy" = "allow" ]; then do_start=1; do_stop=""; else do_start=""; do_stop=1; fi
	fi

	[ -n "$do_start" ] && wifi_sync_starts "$group" "$names_list"
	[ -n "$do_stop" ] && wifi_sync_stops "$group" "$names_list"
	return 0
}

# ---------- 模块描述覆盖（KernelSU ksud 专属，其他方案静默回退） ----------
# 管理器 description 安装时缓存，运行时改 module.prop 不生效；ksud config 是唯一覆盖入口。
MODULE_DESC_ZH='开机自启和保活 Termux 服务与二进制服务，并提供定时/亮屏/ WIFI 启停服务和 WebUI 聚合管理'
MODULE_DESC_EN='Boot-start and keep-alive for Termux and binary services, with scheduled / screen / Wi-Fi start-stop rules and a WebUI'

# 找 ksud（探测不到返回 1，调用方静默跳过）
ksud_bin() {
	[ "${KSU:-}" = "true" ] || return 1
	if command -v ksud >/dev/null 2>&1; then
		command -v ksud
		return 0
	fi
	local p
	for p in /data/adb/ksu/bin/ksud /data/adb/ksud/ksud; do
		[ -x "$p" ] && { printf '%s\n' "$p"; return 0; }
	done
	return 1
}

# 按当前语言覆盖管理器 description（非 KernelSU 零操作）
desc_override_apply() {
	local ksud desc
	ksud=$(ksud_bin) || return 0
	if [ "$UI_LANG" = "en" ]; then
		desc=$MODULE_DESC_EN
	else
		desc=$MODULE_DESC_ZH
	fi
	"$ksud" module config set override.description "$desc" >/dev/null 2>&1 || true
	return 0
}

# 外部访问：监听与安全策略来自 web.conf，缺文件/非法值回默认。
# web.conf 默认值。
WEBUI_LISTEN_DEF=127.0.0.1
WEBUI_PORT_DEF=5555
SESS_TTL_DEF=3600
TOKEN_DAYS_DEF=30
FAIL_MAX_DEF=5
FAIL_LOCK_DEF=300

# 读 web.conf（config/web.conf 唯一来源；单次 awk 白名单提取，非法回默认）。
load_web_conf() {
	local f="$WEB_CONF" out
	WEBUI_LISTEN=$WEBUI_LISTEN_DEF
	WEBUI_PORT=$WEBUI_PORT_DEF
	SESS_TTL=$SESS_TTL_DEF
	TOKEN_DAYS=$TOKEN_DAYS_DEF
	FAIL_MAX=$FAIL_MAX_DEF
	FAIL_LOCK=$FAIL_LOCK_DEF
	[ -f "$f" ] || return 0
	# 只认 6 个键，其余忽略（防 source 整文件注入）。
	out=$(awk -F'=' '
		{ k=$1; v=$2; gsub(/[ \t\r]/, "", k); sub(/#.*/, "", v);
		  gsub(/^[ \t]+|[ \t\r]+$/, "", v); gsub(/^["'\'']|["'\'']$/, "", v) }
		k=="WEBUI_LISTEN"||k=="WEBUI_PORT"||k=="SESS_TTL"||k=="TOKEN_DAYS"||k=="FAIL_MAX"||k=="FAIL_LOCK" { print k"="v }
	' "$f" 2>/dev/null) || return 0
	[ -n "$out" ] || return 0
	while IFS='=' read -r k v || [ -n "$k" ]; do
		case "$k" in
		WEBUI_LISTEN) WEBUI_LISTEN=$v ;;
		WEBUI_PORT) WEBUI_PORT=$v ;;
		SESS_TTL) SESS_TTL=$v ;;
		TOKEN_DAYS) TOKEN_DAYS=$v ;;
		FAIL_MAX) FAIL_MAX=$v ;;
		FAIL_LOCK) FAIL_LOCK=$v ;;
		esac
	done <<EOF
$out
EOF
	# 数字键统一钳制：非法回默认。
	case "$WEBUI_PORT" in ''|*[!0-9]*) WEBUI_PORT=$WEBUI_PORT_DEF ;; esac
	[ "$WEBUI_PORT" -ge 1 ] 2>/dev/null && [ "$WEBUI_PORT" -le 65535 ] 2>/dev/null || WEBUI_PORT=$WEBUI_PORT_DEF
	case "$SESS_TTL" in ''|*[!0-9]*) SESS_TTL=$SESS_TTL_DEF ;; esac
	[ "$SESS_TTL" -ge 60 ] 2>/dev/null && [ "$SESS_TTL" -le 2592000 ] 2>/dev/null || SESS_TTL=$SESS_TTL_DEF
	case "$TOKEN_DAYS" in ''|*[!0-9]*) TOKEN_DAYS=$TOKEN_DAYS_DEF ;; esac
	[ "$TOKEN_DAYS" -ge 1 ] 2>/dev/null && [ "$TOKEN_DAYS" -le 365 ] 2>/dev/null || TOKEN_DAYS=$TOKEN_DAYS_DEF
	case "$FAIL_MAX" in ''|*[!0-9]*) FAIL_MAX=$FAIL_MAX_DEF ;; esac
	[ "$FAIL_MAX" -ge 1 ] 2>/dev/null && [ "$FAIL_MAX" -le 100 ] 2>/dev/null || FAIL_MAX=$FAIL_MAX_DEF
	case "$FAIL_LOCK" in ''|*[!0-9]*) FAIL_LOCK=$FAIL_LOCK_DEF ;; esac
	[ "$FAIL_LOCK" -ge 10 ] 2>/dev/null && [ "$FAIL_LOCK" -le 86400 ] 2>/dev/null || FAIL_LOCK=$FAIL_LOCK_DEF
	return 0
}

WEBUI_LOG="$LOG_DIR/webui.log"
# 登录会话目录（run/ 下，与 pid 文件同级；绝不能放 webroot 文档根下，httpd 会静态外泄）。
# 密码会话 sess_<token>，Token 会话 tsess_<token>（长期登录，会话按天，Token 本身不变）。
WEBUI_SESS_DIR="$RUNDIR/session"
WEBUI_SESS_PREFIX="$WEBUI_SESS_DIR/sess_"
WEBUI_TSESS_PREFIX="$WEBUI_SESS_DIR/tsess_"
WEBUI_FAIL_PREFIX="$RUNDIR/webui_fail_"
# 默认 admin 密码的固定盐。
WEBUI_DEFAULT_SALT="svchub-admin"

webui_log() {
	[ -n "$1" ] || return 0
	echo "[$(date '+%F %T')] $1" >> "$WEBUI_LOG"
}

# 启动前清遗留密码会话（Token 长期会话保留）：有效删，过期留待CGI惰性删。
# sess_valid 在 CGI 侧，service/supervisor 共用此函数（同语义：有效删、过期保留）。
webui_clean_stale_sess() {
	local sf st exp now
	for sf in "$WEBUI_SESS_DIR"/sess_*; do
		[ -f "$sf" ] || continue
		st=${sf##*sess_}
		case "$st" in *tsess_*) continue ;; esac
		exp=$(cat "$sf" 2>/dev/null | tr -dc '0-9')
		now=$(date +%s)
		[ -n "$exp" ] && [ "$exp" -gt "$now" ] 2>/dev/null && rm -f "$sf"
	done
}

# 轻量读开关（免全量 load）：输出 enabled has_password。
webui_status_fast() {
	local e h f="$SETTING_FILE"
	e=$(sed -n 's/^[[:space:]]*webui_enabled=\(.*\)/\1/p' "$f" 2>/dev/null | head -n 1)
	h=$(sed -n 's/^[[:space:]]*webui_password_hash=\(.*\)/\1/p' "$f" 2>/dev/null | head -n 1)
	[ -z "$e" ] && e=1
	[ "$e" = 0 ] || e=1
	[ -n "$h" ] && h=1 || h=0
	printf '%s %s\n' "$e" "$h"
}

# WEBUI_PORT 状态：0=LISTEN 1=未监听 2=无法探测（无 /proc/net，如 PC 沙盒）。
# 断网/省电后进程可能活着但监听 socket 被 ROM 摘除，pid 探活探不出，端口探活补这个盲区。
webui_port_state() {
	local hex
	hex=$(printf '%04X' "$WEBUI_PORT" 2>/dev/null)
	[ -n "$hex" ] || return 2
	[ -r /proc/net/tcp ] || [ -r /proc/net/tcp6 ] || return 2
	# 数据行按 local_address 格式识别（首列 sl 是 "0:" 带冒号，不能按纯数字匹配）
	awk -v hex="$hex" '$2 ~ /^[0-9A-Fa-f]+:[0-9A-Fa-f]+$/ { split($2, a, ":"); if (toupper(a[2]) == hex && $4 == "0A") found = 1 } END { exit !found }' /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

# 保活判定：只有「确定未监听」才算异常，未知按可用处理，避免误杀健康实例。
webui_port_down() {
	webui_port_state
	[ $? -eq 1 ]
}

# 找含 httpd 的 busybox，输出路径。
# 顺序：沙盒覆盖（仅 PC 联调）→ PATH → 各 root 方案自带。
webui_find_busybox() {
	local b
	for b in "$SVCHUB_BUSYBOX" "$(command -v busybox 2>/dev/null)" \
		/data/adb/ksu/bin/busybox /data/adb/magisk/busybox /data/adb/ap/bin/busybox; do
		[ -n "$b" ] && [ -x "$b" ] && "$b" httpd --help 2>&1 | grep -q '\-p' && {
			printf '%s\n' "$b"
			return 0
		}
	done
	return 1
}

# 生成 64 位随机 hex（会话 Token / 密码盐）。
webui_gen_token() {
	local t
	t=$(od -An -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' | head -c 64)
	if [ "${#t}" -lt 64 ]; then
		t=$(printf '%s%s%s' "$(date +%s%N)" "$$" "$RANDOM" | sha256sum 2>/dev/null | head -c 64)
	fi
	if [ "${#t}" -lt 64 ]; then
		t=$(printf '%s%s%s' "$(date +%s)" "$$" "$RANDOM" | busybox sha256sum 2>/dev/null | head -c 64)
	fi
	[ "${#t}" -eq 64 ] || return 1
	printf '%s\n' "$t"
}

# 密码哈希：$1=盐，stdin 读明文，输出 盐$hex。
webui_hash_password() {
	local salt=$1 pw hex bb
	[ -n "$salt" ] || return 1
	# 无尾随换行时 read 非零但变量有效，必须保留，否则登录无校验。
	IFS= read -r pw || [ -n "$pw" ] || pw=""
	hex=$(printf '%s' "$salt$pw" | sha256sum 2>/dev/null | head -c 64)
	if [ "${#hex}" -lt 64 ]; then
		bb=$(webui_find_busybox 2>/dev/null) || return 1
		hex=$(printf '%s' "$salt$pw" | "$bb" sha256sum 2>/dev/null | head -c 64)
	fi
	[ "${#hex}" -eq 64 ] || return 1
	printf '%s$%s\n' "$salt" "$hex"
}

# 校验明文密码：$1=明文 $2=存量哈希，匹配返回 0。
webui_check_password() {
	local pw=$1 stored=$2 salt expect got
	case "$stored" in *'$'*) ;; *) return 1 ;; esac
	salt=${stored%%\$*}
	expect=${stored#*\$}
	[ -n "$salt" ] && [ -n "$expect" ] || return 1
	got=$(printf '%s' "$pw" | webui_hash_password "$salt" | head -n 1)
	[ -n "$got" ] || return 1
	[ "$got" = "$stored" ]
}

# source 落点：加载 web.conf。
load_web_conf