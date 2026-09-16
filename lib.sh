#!/system/bin/sh
# SvcHub 公共库：配置读写（模块私有 config.json 明文）、进程 pid 管理、日志轮转与校验、Wi-Fi 策略控制。
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
CONFIG_FILE="$MODDIR/config.json"

# 设备上为空走默认路径，零影响
[ -n "$SVCHUB_TERMUX_HOME" ] && TERMUX_HOME="$SVCHUB_TERMUX_HOME" || TERMUX_HOME="/data/data/com.termux/files/home"

# Termux 应用运行 uid
TERMUX_UID=$(stat -c '%u' "$TERMUX_HOME" 2>/dev/null || stat -c '%u' /data/data/com.termux 2>/dev/null)
[ -z "$TERMUX_UID" ] && TERMUX_UID=10000

# Termux 启动命令必须注入的环境
# 联调覆盖：SVCHUB_MOCK=1 时（电脑沙盒）清空注入，设备 Termux 路径在 PC 上不存在
if [ "$SVCHUB_MOCK" = "1" ]; then
	TERMUX_ENV=''
else
	TERMUX_ENV='export PREFIX=/data/data/com.termux/files/usr; export PATH=$PREFIX/bin:$PATH; export TMPDIR=$PREFIX/tmp; export LD_LIBRARY_PATH=$PREFIX/lib;'
fi
DEFAULT_SERVER_DIR="/data/media/0/Server"

# 日志统一上限（字节），默认1MB
LOG_MAX_BYTES=1048576

# Wi-Fi 策略相关全局变量
WIFI_POLICY=""
WIFI_POLICY_PREV=""
WIFI_SSID_CACHE=""
WIFI_SSID_NOW=""
WIFI_SSID_CACHE_TIME=0

mkdir -p "$RUNDIR" "$LOG_DIR"

# ---------- 配置（模块私有 config.json，明文 JSON） ----------
# JSON 字符串编码：换行转义为字面 \n 两字符序列，保证写入的 JSON 合法
enc_js() {
	awk '{ gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); if (NR > 1) printf "\\n"; printf "%s", $0 }'
}

# JSON 字符串解码：\n \t \" \\ 还原为明文
dec_js() {
	awk '{ gsub(/\\n/, "\n"); gsub(/\\t/, "\t"); gsub(/\\"/, "\""); gsub(/\\\\/, "\\"); printf "%s", $0 }'
}

# 读取某个 key 的值（明文）；不存在/空则输出空
cfg_get() {
	local key=$1 val
	[ -f "$CONFIG_FILE" ] || return 0
	val=$(sed -n "s/^[[:space:]]*\"${key}\":[[:space:]]*\"\(.*\)\"[,]*$/\1/p" "$CONFIG_FILE")
	[ -n "$val" ] || return 0
	printf '%s' "$val" | dec_js
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

# 配置一次性写成 config.json（原子替换）
write_config_json() {
	local si=$1 sd=$2 ts=$3 sv=$4 bc=$5 wse=$6 wsn=$7 wss=$8 wsn_off=$9 sche=${10} schstop=${11} schstart=${12} tmp="$CONFIG_FILE.tmp"
	{
		echo '{'
		printf '  "sleep_interval": "%s",\n'          "$(printf '%s' "$si" | enc_js)"
		printf '  "server_dir": "%s",\n'              "$(printf '%s' "$sd" | enc_js)"
		printf '  "termux_services": "%s",\n'         "$(printf '%s' "$ts" | enc_js)"
		printf '  "services": "%s",\n'                "$(printf '%s' "$sv" | enc_js)"
		printf '  "boot_commands": "%s",\n'           "$(printf '%s' "$bc" | enc_js)"
		printf '  "wifi_service_enabled": "%s",\n'    "$(printf '%s' "$wse" | enc_js)"
		printf '  "wifi_service_names": "%s",\n'      "$(printf '%s' "$wsn" | enc_js)"
		printf '  "wifi_service_names_off": "%s",\n'  "$(printf '%s' "$wsn_off" | enc_js)"
		printf '  "wifi_ssids": "%s",\n'              "$(printf '%s' "$wss" | enc_js)"
		printf '  "schedule_enabled": "%s",\n'        "$(printf '%s' "$sche" | enc_js)"
		printf '  "schedule_stop": "%s",\n'           "$(printf '%s' "$schstop" | enc_js)"
		printf '  "schedule_start": "%s"\n'           "$(printf '%s' "$schstart" | enc_js)"
		echo '}'
	} > "$tmp" && mv -f "$tmp" "$CONFIG_FILE"
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

# 从 stdin 逐行执行并记录（sh -c，不做 eval；# 注释行会保留执行）
run_command_lines() {
    local mark=$1 line log="$LOG_DIR/boot_commands.log"
    {
        echo "=== $mark $(date '+%Y-%m-%d %H:%M:%S') ==="
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            echo "> $line"
            sh -c "$line"
            echo "[exit=$?]"
        done
    } >> "$log" 2>&1
}

# ---------- 会话清理 ----------
# 清空上一会话残留：run 目录删除全部残留 pid 文件；
# log 目录除开机命令日志全部删除。服务日志会在下次启动时重建。
clean_session_files() {
    local f base pid
    if [ -d "$RUNDIR" ]; then
        for f in "$RUNDIR"/*; do
            [ -e "$f" ] || continue
            base=${f##*/}
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
# 检查服务是否在运行：pid 文件存在且首行 pid 存活即在运行；进程已退出则顺手清理过期 pid 文件
svc_running() {
	local pidf="$RUNDIR/$1.pid"
	[ -f "$pidf" ] || return 1
	read -r pid < "$pidf" || { rm -f "$pidf"; return 1; }
	if kill -0 "$pid" 2>/dev/null; then
		return 0
	fi
	rm -f "$pidf"
	return 1
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

# 启动服务：$1=名称 $2=工作目录 $3=su 附加参数 $4=命令文本
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


# 停止服务：按 pid 文件终止进程组，清理 pid 文件与该服务日志
stop_svc() {
	local name=$1 pidf="$RUNDIR/$1.pid" i=0
	valid_name "$name" || return 0
	kill_by_name "$name"
	rm -f "$LOG_DIR/$1.log"
    # 短等待直至进程消失（防 fork 竞争残留）
	while [ "$i" -lt 20 ]; do
		svc_running "$name" || break
		sleep 0.2
		i=$((i + 1))
	done
	rm -f "$pidf"
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

# 停止全部已配置服务
stop_all() {
	printf '%s\n' "$(cfg_get termux_services)" | while IFS='|' read -r name port extra auto cmd; do
		[ -n "$name" ] && stop_svc "$name"
	done
	printf '%s\n' "$(cfg_get services)" | while IFS='|' read -r name port auto cmd; do
		[ -n "$name" ] && stop_svc "$name"
	done
}

# ---------- 配置加载 ----------
# 旧版 config.json 缺 wifi 键时，只做行级插入补默认值，不触碰已有行。
# 注意：绝不能用解码后的变量全量重写——若文件本身已损坏，解码出空值会覆盖掉原有配置。
ensure_wifi_defaults() {
	local k missing tmp
	[ -f "$CONFIG_FILE" ] || return 0
	missing=""
	for k in wifi_service_enabled wifi_service_names wifi_service_names_off wifi_ssids; do
		grep -q "^[[:space:]]*\"$k\"[[:space:]]*:" "$CONFIG_FILE" 2>/dev/null || missing="$missing $k"
	done
	[ -n "$missing" ] || return 0
	# 五个基础键缺失说明文件结构异常，此时不碰文件，只用内存默认值运行
	for k in sleep_interval server_dir termux_services services boot_commands; do
		grep -q "^[[:space:]]*\"$k\"[[:space:]]*:" "$CONFIG_FILE" 2>/dev/null || return 0
	done
	tmp="$CONFIG_FILE.tmp"
	awk '
		/"wifi_service_enabled"/ { have_wse = 1 }
		/"wifi_service_names"/ && !/"wifi_service_names_off"/ { have_wsn = 1 }
		/"wifi_service_names_off"/ { have_wsn_off = 1 }
		/"wifi_ssids"/ { have_wss = 1 }
		/^[[:space:]]*}[[:space:]]*$/ && !done {
			if (prev != "" && prev !~ /,[[:space:]]*$/) prev = prev ","
			if (prev != "") print prev
			prev = ""
			if (!have_wse) print "  \"wifi_service_enabled\": \"0\","
			if (!have_wsn) print "  \"wifi_service_names\": \"\","
			if (!have_wsn_off) print "  \"wifi_service_names_off\": \"\","
			if (!have_wss) print "  \"wifi_ssids\": \"\""
			print $0
			done = 1
			next
		}
		{ if (prev != "") print prev; prev = $0 }
		END { if (!done && prev != "") print prev }
	' "$CONFIG_FILE" > "$tmp" && mv -f "$tmp" "$CONFIG_FILE"
	return 0
}

# 旧版 config.json 缺定时键时，只做行级插入补默认值，不触碰已有行。
# 注意：与 ensure_wifi_defaults 同理，基础键缺失说明文件结构异常，此时不动文件。
ensure_schedule_defaults() {
	local k missing tmp
	[ -f "$CONFIG_FILE" ] || return 0
	missing=""
	for k in schedule_enabled schedule_stop schedule_start; do
		grep -q "^[[:space:]]*\"$k\"[[:space:]]*:" "$CONFIG_FILE" 2>/dev/null || missing="$missing $k"
	done
	[ -n "$missing" ] || return 0
	for k in sleep_interval server_dir termux_services services boot_commands; do
		grep -q "^[[:space:]]*\"$k\"[[:space:]]*:" "$CONFIG_FILE" 2>/dev/null || return 0
	done
	tmp="$CONFIG_FILE.tmp"
	awk '
		/"schedule_enabled"/ { have_sche = 1 }
		/"schedule_stop"/ { have_schstop = 1 }
		/"schedule_start"/ { have_schstart = 1 }
		/^[[:space:]]*}[[:space:]]*$/ && !done {
			if (prev != "" && prev !~ /,[[:space:]]*$/) prev = prev ","
			if (prev != "") print prev
			prev = ""
			if (!have_sche) print "  \"schedule_enabled\": \"0\","
			if (!have_schstop) print "  \"schedule_stop\": \"\","
			if (!have_schstart) print "  \"schedule_start\": \"\""
			print $0
			done = 1
			next
		}
		{ if (prev != "") print prev; prev = $0 }
		END { if (!done && prev != "") print prev }
	' "$CONFIG_FILE" > "$tmp" && mv -f "$tmp" "$CONFIG_FILE"
	return 0
}

load_cfg_sh() {
	SLEEP_INTERVAL=$(cfg_get sleep_interval)
	SERVER_DIR=$(cfg_get server_dir)
	TERMUX_SERVICES=$(cfg_get termux_services)
	SERVICES=$(cfg_get services)
	BOOT_COMMANDS=$(cfg_get boot_commands)
	WIFI_SERVICE_ENABLED=$(cfg_get wifi_service_enabled)
	WIFI_SERVICE_NAMES=$(cfg_get wifi_service_names)
	WIFI_SERVICE_NAMES_OFF=$(cfg_get wifi_service_names_off)
	WIFI_SSIDS=$(cfg_get wifi_ssids)
	SCHEDULE_ENABLED=$(cfg_get schedule_enabled)
	SCHEDULE_STOP=$(cfg_get schedule_stop)
	SCHEDULE_START=$(cfg_get schedule_start)

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

	ensure_wifi_defaults
	ensure_schedule_defaults
}

# 按名称从配置取整行（awk 保留 cmd 中的 |；返回整行 $0）
pick_termux() {
	printf '%s\n' "$TERMUX_SERVICES" | awk -F'|' -v n="$1" '$1==n { print; exit }'
}

pick_binary() {
	printf '%s\n' "$SERVICES" | awk -F'|' -v n="$1" '$1==n { print; exit }'
}

# 查询某名称在两类配置中的 auto 值（start/stop/空）
should_run() {
	local name=$1 a
	a=$(printf '%s\n' "$TERMUX_SERVICES" | awk -F'|' -v n="$name" '$1==n { print $4; exit }')
	[ -n "$a" ] || a=$(printf '%s\n' "$SERVICES" | awk -F'|' -v n="$name" '$1==n { print $3; exit }')
	printf '%s' "$a"
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

wifi_log_rotate() {
	rotate_log "$WIFI_LOG"
}

wifi_log_connected_text() {
	[ "$WIFI_LOG_CONNECTED" = "1" ] && printf '已连接' || printf '未连接'
}

wifi_log_match_text() {
	case "$WIFI_LOG_SSID_MATCH" in
		1) printf 'SSID匹配' ;;
		0) printf 'SSID不匹配' ;;
		*) printf 'SSID未检测' ;;
	esac
}

wifi_log_ssid_text() {
	if [ -z "$WIFI_LOG_SSID" ]; then
		printf '(空)'
	elif [ -n "$WIFI_LOG_NETID" ]; then
		printf '%s（netId %s）' "$WIFI_LOG_SSID" "$WIFI_LOG_NETID"
	else
		printf '%s' "$WIFI_LOG_SSID"
	fi
}

# 中文策略文案（日志中不出现 allow/block/disabled 英文）
wifi_policy_zh() {
	case "$1" in
		allow) printf '运行服务' ;;
		block) printf '停止服务' ;;
		*) printf '功能关闭' ;;
	esac
}

# 检查 Wi-Fi 是否已连接
wifi_connected() {
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

# 根据策略同步受管服务的启停
# $1=策略(allow/block/disabled) $2=模式(on=连接组，allow起/block停；off=断开组，反向：allow停/block起)
# 重叠规则：同一服务同时在两组时连接组优先，断开组跳过并记警告。
sync_wifi_service_policy() {
	local new_policy=$1 mode=${2:-on} name row port extra auto cmd
	local group target_names on_names

	if [ "$mode" = "off" ]; then
		group="断开组"
		target_names=$WIFI_SERVICE_NAMES_OFF
		on_names=$WIFI_SERVICE_NAMES
	else
		group="连接组"
		target_names=$WIFI_SERVICE_NAMES
		on_names=""
	fi

	# 策略变化记录到 Wi-Fi 专属日志（含上下文），supervisor 日志不再记录
	# 两组共享同一策略，变化行只记一次（由 on 分支记录，off 分支跳过）
	if [ "$mode" = "on" ] && [ "$new_policy" != "$WIFI_POLICY_PREV" ]; then
		wifi_log "WiFi 状态变化：$(wifi_policy_zh "${WIFI_POLICY_PREV:-初始}") -> $(wifi_policy_zh "$new_policy")（$(wifi_log_connected_text)，$(wifi_log_match_text)）"
		# 已配置白名单且已连接时，输出当前 Wi-Fi 名称（及 netId），方便排查匹配失败；
		# 白名单为空（任意 WiFi）时不获取 SSID，跳过该行避免输出无意义的 (空)
		[ "$new_policy" != "disabled" ] && [ "$WIFI_LOG_CONNECTED" = "1" ] && [ -n "$WIFI_SSIDS" ] && \
			wifi_log "当前 Wi-Fi：$(wifi_log_ssid_text)"
		WIFI_POLICY_PREV="$new_policy"
	fi

	[ "$new_policy" = "disabled" ] && return 0
	[ -z "$target_names" ] && return 0

	# 服务名仅含字母数字点横线，不含空格，可安全转为空格分隔的单行列表进行 for 遍历
	local names_list
	names_list=$(printf '%s\n' "$target_names" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | tr '\n' ' ')

	# 同类服务聚合为一行日志（name 均经 valid_name 校验，不含空格，可安全空格拼接）
	local t_start="" b_start="" missing="" stops="" dup=""

	# 断开组重叠检查：已在连接组的服务归连接组，断开组跳过并记警告
	if [ "$mode" = "off" ] && [ -n "$on_names" ]; then
		local on_list clean_list=""
		on_list=$(printf '%s\n' "$on_names" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | tr '\n' ' ')
		for name in $names_list; do
			case " $on_list " in
			*" $name "*) dup="$dup $name" ;;
			*) clean_list="$clean_list $name" ;;
			esac
		done
		names_list=$clean_list
		[ -n "$dup" ] && wifi_log "断开组服务$dup 同时在连接组，已按连接组处理"
	fi

	# 断开组语义与连接组完全反向：allow=Wi-Fi 连上=断开组停、block=Wi-Fi 断开=断开组起
	local do_start do_stop
	if [ "$mode" = "off" ]; then
		if [ "$new_policy" = "allow" ]; then do_start=""; do_stop=1; else do_start=1; do_stop=""; fi
	else
		if [ "$new_policy" = "allow" ]; then do_start=1; do_stop=""; else do_start=""; do_stop=1; fi
	fi

	if [ -n "$do_start" ] && [ "$SCHED_IN_WINDOW" != "1" ]; then
		for name in $names_list; do
			valid_name "$name" || continue
			svc_running "$name" && continue
			if [ -n "$(pick_termux "$name")" ]; then
				t_start="$t_start $name"
			elif [ -n "$(pick_binary "$name")" ]; then
				b_start="$b_start $name"
			else
				missing="$missing $name"
			fi
		done
		if [ -n "$t_start" ]; then
			wifi_log "WiFi 条件满足（$(wifi_log_match_text)），启动${group} Termux 服务$t_start"
			for name in $t_start; do
				row=$(pick_termux "$name")
				IFS='|' read -r _ port extra auto cmd <<EOF
$row
EOF
				start_svc "$name" "$TERMUX_HOME" "$extra" "$TERMUX_ENV $cmd"
			done
		fi
		if [ -n "$b_start" ]; then
			wifi_log "WiFi 条件满足（$(wifi_log_match_text)），启动${group}二进制服务$b_start"
			for name in $b_start; do
				row=$(pick_binary "$name")
				IFS='|' read -r _ port auto cmd <<EOF
$row
EOF
				start_svc "$name" "$SERVER_DIR" "" "$cmd"
			done
		fi
		[ -n "$missing" ] && wifi_log "WiFi 条件满足，但${group}名单内服务$missing 不在服务配置中，跳过"
	fi
	if [ -n "$do_stop" ]; then
		for name in $names_list; do
			valid_name "$name" || continue
			svc_running "$name" && stops="$stops $name"
		done
		if [ -n "$stops" ]; then
			wifi_log "WiFi 条件不满足（$(wifi_log_connected_text)，$(wifi_log_match_text)），停止${group}服务$stops"
			for name in $stops; do
				stop_svc "$name"
			done
		fi
	fi
}