# SvcHub 公共库：定时停止窗、亮屏/锁屏、Wi-Fi 策略与启动门控、唤醒锁。

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

# ---------- 唤醒锁 ----------
# 内核 PM_WAKELOCKS 接口（写名字持锁 / 写 wake_unlock 释放）。
# 持锁与释放必须用同一名字，抽常量防改一处漏一处。
WAKE_LOCK_NAME=svchub_wakelock

# 可用性探测：直接真写一次再释放，不依赖 -w（root 与 sysfs 下权限位不可靠）。
wake_lock_supported() {
	[ -e /sys/power/wake_lock ] || return 1
	echo "$WAKE_LOCK_NAME" 2>/dev/null > /sys/power/wake_lock || return 1
	echo "$WAKE_LOCK_NAME" 2>/dev/null > /sys/power/wake_unlock
	return 0
}

wake_lock_release() {
	echo "$WAKE_LOCK_NAME" 2>/dev/null > /sys/power/wake_unlock
	return 0
}

wake_lock_sync() {
	if [ "$WAKE_LOCK_ENABLED" = "1" ]; then
		echo "$WAKE_LOCK_NAME" 2>/dev/null > /sys/power/wake_lock
	else
		wake_lock_release
	fi
	return 0
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
	# dumpsys connectivity 一次拉取两判复用（每分片都走到，fork 减半）
	local out
	out=$(dumpsys connectivity 2>/dev/null)
	# 1. WIFI 类型 NetworkAgentInfo 且状态 CONNECTED
	if printf '%s\n' "$out" | grep -A 5 "NetworkAgentInfo{type: WIFI" | grep -q "state: CONNECTED"; then
		return 0
	fi
	# 2. 兜底：默认网络是 Wi-Fi（部分系统版本 NetworkAgentInfo 的 state 字段不在附近）
	if printf '%s\n' "$out" | grep -q "Default network:.*WIFI"; then
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

	# 末段强制 C locale：Git Bash 的 grep 在 UTF-8 locale 下匹配 4 字节 emoji 会失败
	printf '%s\n' "$ssids" | grep -v '|' | sed 's/^[[:space:]　]*//;s/[[:space:]　]*$//' | grep -v '^$' | LC_ALL=C grep -qxF -- "$current_ssid"
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

# ---------- 屏幕 / 启动门控 ----------

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
