# SvcHub 公共库：后端文案双语（中文原文为键，英文查表，漏项回退中文）。

# 界面语言（zh 默认 / en）：由 setting.conf 的 language 键驱动，load_cfg_sh 后同进程可见。
UI_LANG="zh"

# 按位代入 %s 占位：awk 逐段替换，值含 % 不当格式符；无占位时原样返回
ui_fill() {
	[ "$#" -gt 1 ] || { printf '%s' "$1"; return 0; }
	printf '%s\n' "$1" | awk -v a="$2" -v b="${3-}" -v c="${4-}" -v d="${5-}" '{
		sub(/%s/, a); sub(/%s/, b); sub(/%s/, c); sub(/%s/, d); print }'
}

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
	'唤醒锁已%s') printf 'Wake lock turned %s' "$1" ;;
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
	'请先修改默认密码') printf 'Change the default password first' ;;
	'不能使用默认密码') printf 'The default password is not allowed' ;;
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
	'唤醒锁开关必须为 0 或 1') printf 'Wake lock toggle must be 0 or 1' ;;
	'内核不支持唤醒锁或SELinux限制') printf 'This kernel does not support wake lock or SELinux is restricting it' ;;
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
	# ---- 二进制更新（updater.sh / action.sh / lib/config.sh） ----
	'update.conf 非法行已跳过：%s') printf 'Invalid update.conf line skipped: %s' "$1" ;;
	'已有更新任务在运行，本次跳过') printf 'An update task is already running, skipped' ;;
	'没有配置任何更新条目') printf 'No update entries configured' ;;
	'开始检查 %s 个条目') printf 'Checking %s entries' "$1" ;;
	'检查完成') printf 'Check completed' ;;
	'无新版本：%s') printf 'No update: %s' "$1" ;;
	'未指定更新条目名') printf 'Update entry name not specified' ;;
	'未找到更新条目：%s') printf 'Update entry not found: %s' "$1" ;;
	'版本探测失败：%s') printf 'Version check failed: %s' "$1" ;;
	'发现新版本：%s → %s') printf 'New version found: %s -> %s' "$1" "$2" ;;
	'已是最新版本 %s') printf 'Already up to date: %s' "$1" ;;
	'未找到匹配的资产：%s') printf 'No matching asset found: %s' "$1" ;;
	'开始下载：%s') printf 'Downloading: %s' "$1" ;;
	'下载进度 %s%（%s/%s MB）') printf 'Download progress: %s%% (%s/%s MB)' "$1" "$2" "$3" ;;
	'下载失败：%s') printf 'Download failed: %s' "$1" ;;
	'下载内容为空') printf 'Downloaded file is empty' ;;
	'完整性校验通过') printf 'Integrity check passed' ;;
	'完整性校验不通过，已中止更新（旧文件未改动）') printf 'Integrity check failed, update aborted (old file untouched)' ;;
	'未获取到校验值，跳过完整性校验') printf 'No checksum available, integrity check skipped' ;;
	'解包失败') printf 'Extraction failed' ;;
	'解包后无可用内容') printf 'No usable content after extraction' ;;
	'解包后未找到目标文件') printf 'Target file not found after extraction' ;;
	'停止关联服务：%s') printf 'Stopping linked service: %s' "$1" ;;
	'启动关联服务：%s') printf 'Starting linked service: %s' "$1" ;;
	'关联服务 %s 启动成功') printf 'Linked service %s started' "$1" ;;
	'关联服务 %s 启动失败，正在回滚') printf 'Linked service %s failed to start, rolling back' "$1" ;;
	'关联服务 %s 不存在，跳过重启') printf 'Linked service %s not found, skipping restart' "$1" ;;
	'已回滚到旧版本') printf 'Rolled back to the previous version' ;;
	'回滚失败，旧文件仍在：%s') printf 'Rollback failed, old file kept at: %s' "$1" ;;
	'无旧版本可回滚') printf 'No previous version to roll back to' ;;
	'写入目标目录失败') printf 'Failed to write target directory' ;;
	'替换目标文件失败') printf 'Failed to replace target file' ;;
	'更新完成：%s') printf 'Update completed: %s' "$1" ;;
	'自动更新（检查发现新版本 %s）') printf 'Auto update (new version found: %s)' "$1" ;;
	'版本命令未取到版本号（输出：%s）') printf 'Version command produced no version (output: %s)' "$1" ;;
	'更新已手动停止') printf 'Update stopped manually' ;;
	'停止更新任务（%s）') printf 'Stop update task (%s)' "$1" ;;
	'没有正在运行的更新任务') printf 'No update task is running' ;;
	'触发更新：%s（%s）') printf 'Trigger update: %s (%s)' "$1" "$2" ;;
	'触发全部更新（%s）') printf 'Trigger update for all entries (%s)' "$1" ;;
	'保存更新配置：%s') printf 'Save update entries: %s' "$1" ;;
	'更新配置格式错误（第 %s 行）') printf 'Invalid update entry format (line %s)' "$1" ;;
	'关联的二进制服务不存在：%s') printf 'Linked binary service does not exist: %s' "$1" ;;
	'不支持的操作') printf 'Unsupported operation' ;;
	'已有更新任务在运行，请稍后再试') printf 'An update task is already running, try again later' ;;
	'代理前缀须以 http:// 或 https:// 开头') printf 'Proxy prefix must start with http:// or https://' ;;
	'检查周期只支持关闭/一小时/一天/一周') printf 'Check interval must be off, one hour, one day or one week' ;;
	*) printf '%s' "$(ui_fill "$tpl" "$@")" ;;
		esac
		;;
	*)
		printf '%s' "$(ui_fill "$tpl" "$@")"
		;;
	esac
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
