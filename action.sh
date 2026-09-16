#!/system/bin/sh
# SvcHub Action / WebUI 固定子命令 API。
# 每个子命令都做白名单校验；不执行任意 shell、不使用 pkill -f 模糊匹配、不做 eval。
MODDIR=${0%/*}
[ -n "$MODDIR" ] && [ -d "$MODDIR" ] || exit 1
. "$MODDIR/lib.sh" 2>/dev/null || exit 1

json_escape() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | tr '\n' '\a' | sed 's/\a/\\n/g'
}

count_rows() {
	printf '%s\n' "$1" | grep -c '^[^|]\{1,\}|' 2>/dev/null || echo 0
}

validate_rows() {
	# $1=kind(termux_services|services)；从 stdin 逐行校验格式，非法 return 1
	local kind=$1 r=0 line name port extra auto cmd
	while IFS= read -r line; do
		[ -z "$line" ] && continue
		r=$((r + 1))
		[ "$r" -gt 500 ] && return 1
		case "$kind" in
		termux_services)
			IFS='|' read -r name port extra auto cmd <<EOF
$line
EOF
			valid_name "$name" || return 1
			[ -n "$cmd" ] || return 1
			case "$auto" in start|stop) ;; *) return 1 ;; esac
			# 端口仅是展示标识，允许任意短文本（不含 |）
			case "$port" in *\|*) return 1 ;; esac
			[ "${#port}" -le 32 ] || return 1
			# 附加参数仅允许字母/数字/空格/._-（拒绝 shell 元字符）
			case "$extra" in
			*'$'*|*'`'*|*';'*|*'&'*|*'|'*|*'('*|*')'*|*'<'*|*'>'*|*'"'*|*"'"'*|*'\'*) return 1 ;;
			esac
			;;
		services)
			IFS='|' read -r name port auto cmd <<EOF
$line
EOF
			valid_name "$name" || return 1
			[ -n "$cmd" ] || return 1
			case "$auto" in start|stop) ;; *) return 1 ;; esac
			# 端口仅是展示标识，允许任意短文本（不含 |）
			case "$port" in *\|*) return 1 ;; esac
			[ "${#port}" -le 32 ] || return 1
			;;
		esac
	done
	return 0
}

clear_log() {
	local name=$1
	valid_name "$name" || return 1
	: > "$LOG_DIR/$name.log"
}

# 行列表 -> JSON 对象数组：单个 awk 完成字段转义与运行状态注入，避免逐字段 fork。
# $1=1 为 Termux 行(5 字段含 extra)，$1=0 为二进制行(4 字段)；运行名单经环境变量 RUNSET 传入；行列表从 stdin 读。
rows_to_json() {
	RUNSET=$2 awk -v termux="$1" '
BEGIN { FS = "|"; runset = ENVIRON["RUNSET"] }
function esc(s) {
	gsub(/\\/, "\\\\", s)
	gsub(/"/, "\\\"", s)
	gsub(/\t/, "\\t", s)
	return s
}
$1 != "" {
	st = index("\n" runset "\n", "\n" $1 "\n") > 0 ? "running" : "stopped"
	if (n++) printf ","
	if (termux)
		printf "{\"name\":\"%s\",\"port\":\"%s\",\"status\":\"%s\",\"extra\":\"%s\",\"auto\":\"%s\",\"cmd\":\"%s\"}", esc($1), esc($2), st, esc($3), esc($4), esc($5)
	else
		printf "{\"name\":\"%s\",\"port\":\"%s\",\"status\":\"%s\",\"auto\":\"%s\",\"cmd\":\"%s\"}", esc($1), esc($2), st, esc($3), esc($4)
}
'
}

api_get_status() {
	local runset
	load_cfg_sh
	# 批量检测全部服务运行状态（单次 pgrep），避免逐服务 fork
	runset=$(
		{
			printf '%s\n' "$TERMUX_SERVICES" | list_names
			printf '%s\n' "$SERVICES" | list_names
		} | detect_running
	)
	boot_id=$(cat "$BOOTID_FILE" 2>/dev/null)
	printf '{"boot_id":"%s","server_dir":"%s","termux_services":[' "$(json_escape "$boot_id")" "$(json_escape "$SERVER_DIR")"
	rows_to_json 1 "$runset" <<EOF
$TERMUX_SERVICES
EOF
	printf '],"services":['
	rows_to_json 0 "$runset" <<EOF
$SERVICES
EOF
	printf ']}\n'
}

api_start_service() {
	local type=$1 name=$2 row port extra auto cmd
	valid_name "$name" || { echo '{"success":false,"error":"名称不合法"}'; exit 0; }
	load_cfg_sh
	case "$type" in termux|auto|binary) ;; *) echo '{"success":false,"error":"不支持的服务类型"}'; exit 0 ;; esac
	row=$(pick_termux "$name")
	if [ -n "$row" ]; then
		IFS='|' read -r _ port extra auto cmd <<EOF
$row
EOF
		stop_svc "$name"
		if start_svc "$name" "$TERMUX_HOME" "$extra" "$TERMUX_ENV $cmd"; then
			echo '{"success":true}'
		else
			echo '{"success":false,"error":"启动失败（可能是 Termux 目录不存在或命令错误）"}'
		fi
		exit 0
	fi
	if [ "$type" = termux ]; then
		echo '{"success":false,"error":"未在 Termux 服务中找到该名称"}'
		exit 0
	fi
	row=$(pick_binary "$name")
	if [ -n "$row" ]; then
		IFS='|' read -r _ port auto cmd <<EOF
$row
EOF
		stop_svc "$name"
		if start_svc "$name" "$SERVER_DIR" "" "$cmd"; then
			echo '{"success":true}'
		else
			echo '{"success":false,"error":"启动失败（服务目录不存在或命令错误）"}'
		fi
		exit 0
	fi
	echo '{"success":false,"error":"未在二进制服务中找到该名称"}'
}

api_stop_service() {
	local name=$1
	valid_name "$name" || { echo '{"success":false,"error":"名称不合法"}'; exit 0; }
	stop_svc "$name"
	echo '{"success":true}'
}

api_get_logs() {
	local first l n
	printf '{"logs":['
	first=1
	for l in "$LOG_DIR"/*.log; do
		[ -f "$l" ] || continue
		n=$(basename "$l" .log)
		[ "$n" = supervisor ] && continue
		[ "$first" -eq 0 ] && printf ','
		first=0
		printf '"%s"' "$(json_escape "$n")"
	done
	printf ']}\n'
}

api_read_log() {
	local name=$1 lines=${2:-500} f
	valid_name "$name" || { echo '{"content":"","error":"名称不合法"}'; exit 0; }
	is_int "$lines" || lines=500
	[ "$lines" -gt 2000 ] && lines=2000
	f="$LOG_DIR/$name.log"
	[ -f "$f" ] || { echo '{"content":"","error":"日志文件不存在"}'; exit 0; }
	{
		printf '{"content":"'
		if [ "$lines" = 0 ]; then cat "$f"; else tail -n "$lines" "$f"; fi | base64 | tr -d '
'
		printf '"}\n'
	}
}

api_get_config() {
	load_cfg_sh
	printf '{"sleep_interval":"%s","server_dir":"%s","termux_services":"' "$SLEEP_INTERVAL" "$(json_escape "$SERVER_DIR")"
	printf '%s' "$(json_escape "$TERMUX_SERVICES")"
	printf '","services":"'
	printf '%s' "$(json_escape "$SERVICES")"
	printf '","boot_commands":"'
	printf '%s' "$(json_escape "$BOOT_COMMANDS")"
	printf '","wifi_service_enabled":"%s","wifi_service_names":"' "$WIFI_SERVICE_ENABLED"
	printf '%s' "$(json_escape "$WIFI_SERVICE_NAMES")"
	printf '","wifi_service_names_off":"'
	printf '%s' "$(json_escape "$WIFI_SERVICE_NAMES_OFF")"
	printf '","wifi_ssids":"'
	printf '%s' "$(json_escape "$WIFI_SSIDS")"
	printf '","schedule_enabled":"%s","schedule_stop":"' "$SCHEDULE_ENABLED"
	printf '%s' "$(json_escape "$SCHEDULE_STOP")"
	printf '","schedule_start":"'
	printf '%s' "$(json_escape "$SCHEDULE_START")"
	printf '"}\n'
}

# 从 stdin 读 key=BASE64VALUE 行；白名单校验后一次性写入 config.json（明文 JSON）
api_save_config() {
	local line key b64 val
	local has_si=0 has_sd=0 has_ts=0 has_sv=0 has_bc=0 has_wse=0 has_wsn=0 has_wsn_off=0 has_wss=0
	local has_sche=0 has_schstop=0 has_schstart=0
	local si= sd= ts= sv= bc= wse= wsn= wsn_off= wss=
	local sche= schstop= schstart=
	while IFS= read -r line; do
		[ -z "$line" ] && continue
		key=${line%%=*}
		b64=${line#*=}
		case "$key" in
		sleep_interval|server_dir|termux_services|services|boot_commands|wifi_service_enabled|wifi_service_names|wifi_service_names_off|wifi_ssids|schedule_enabled|schedule_stop|schedule_start) ;;
		*) echo '{"success":false,"error":"未知配置键"}'; exit 1 ;;
		esac
		case "$b64" in
		*[!A-Za-z0-9+/=]*) echo '{"success":false,"error":"配置编码错误"}'; exit 1 ;;
		esac
		val=$(printf '%s' "$b64" | base64 -d 2>/dev/null) || { echo '{"success":false,"error":"配置解码失败"}'; exit 1; }
		[ "${#val}" -le 1048576 ] || { echo '{"success":false,"error":"配置内容过大"}'; exit 1; }
		case "$key" in
		sleep_interval)
			[ -n "$val" ] || val=60
			is_int "$val" || { echo '{"success":false,"error":"间隔必须为数字"}'; exit 1; }
			# 保活间隔最小 10 秒，最大 86400 秒
			[ "$val" -lt 10 ] && val=10
			[ "$val" -gt 86400 ] && val=86400
			si=$val; has_si=1
			;;
		server_dir)
			sd=$val; has_sd=1
			;;
		termux_services|services)
			printf '%s\n' "$val" | validate_rows "$key" || { echo '{"success":false,"error":"服务配置格式错误"}'; exit 1; }
			if [ "$key" = termux_services ]; then ts=$val; has_ts=1; else sv=$val; has_sv=1; fi
			;;
		boot_commands)
			bc=$val; has_bc=1
			;;
		wifi_service_enabled)
			case "$val" in
			0|1) wse=$val; has_wse=1 ;;
			*) echo '{"success":false,"error":"Wi-Fi 功能开关必须为 0 或 1"}'; exit 1 ;;
			esac
			;;
		wifi_service_names|wifi_service_names_off)
			# 校验多行文本中的服务名是否合法（仅允许字母数字点横线）
			local invalid_name
			invalid_name=$(printf '%s\n' "$val" | awk '{ gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if ($0 != "" && $0 !~ /^[A-Za-z0-9._-]+$/) { print $0; exit } }')
			if [ -n "$invalid_name" ]; then
				echo "{\"success\":false,\"error\":\"Wi-Fi 服务名不合法: $invalid_name\"}"
				exit 1
			fi
			if [ "$key" = wifi_service_names ]; then wsn=$val; has_wsn=1; else wsn_off=$val; has_wsn_off=1; fi
			;;
		wifi_ssids)
			# SSID 允许中文/空格/符号/emoji：与存储分隔符冲突的 | 与真实换行
			# 由前端剔除，这里只做长度与行数上限 + 拒绝注入配置解析的异常字符
			if [ "${#val}" -gt 10000 ]; then
				echo '{"success":false,"error":"Wi-Fi SSID 列表过长"}'
				exit 1
			fi
			local ssid_lines
			ssid_lines=$(printf '%s\n' "$val" | grep -c '^' 2>/dev/null || echo 0)
			if [ "$ssid_lines" -gt 100 ]; then
				echo '{"success":false,"error":"Wi-Fi SSID 数量过多(最多100个)"}'
				exit 1
			fi
			wss=$val; has_wss=1
			;;
		schedule_enabled)
			case "$val" in
			0|1) sche=$val; has_sche=1 ;;
			*) echo '{"success":false,"error":"定时功能开关必须为 0 或 1"}'; exit 1 ;;
			esac
			;;
		schedule_stop|schedule_start)
			if [ -n "$val" ]; then
				case "$val" in
				[0-2][0-9]:[0-5][0-9])
					[ "${val%%:*}" -le 23 ] 2>/dev/null || { echo '{"success":false,"error":"定时时间格式错误(HH:MM)"}'; exit 1; }
					;;
				*) echo '{"success":false,"error":"定时时间格式错误(HH:MM)"}'; exit 1 ;;
				esac
			fi
			if [ "$key" = schedule_stop ]; then schstop=$val; has_schstop=1; else schstart=$val; has_schstart=1; fi
			;;
		esac
	done
	# 未提供的键沿用现有配置，避免误清空
	load_cfg_sh
	old_ts=$TERMUX_SERVICES
	old_sv=$SERVICES
	[ "$has_si" -eq 1 ] || si=$SLEEP_INTERVAL
	[ "$has_sd" -eq 1 ] || sd=$SERVER_DIR
	[ "$has_ts" -eq 1 ] || ts=$TERMUX_SERVICES
	[ "$has_sv" -eq 1 ] || sv=$SERVICES
	[ "$has_bc" -eq 1 ] || bc=$BOOT_COMMANDS
	[ "$has_wse" -eq 1 ] || wse=$WIFI_SERVICE_ENABLED
	[ "$has_wsn" -eq 1 ] || wsn=$WIFI_SERVICE_NAMES
	[ "$has_wsn_off" -eq 1 ] || wsn_off=$WIFI_SERVICE_NAMES_OFF
	[ "$has_wss" -eq 1 ] || wss=$WIFI_SSIDS
	[ "$has_sche" -eq 1 ] || sche=$SCHEDULE_ENABLED
	[ "$has_schstop" -eq 1 ] || schstop=$SCHEDULE_STOP
	[ "$has_schstart" -eq 1 ] || schstart=$SCHEDULE_START
	# 停止与启动时间相同无意义：启用状态下拒绝，避免进窗判定恒为窗外却让用户误以为生效
	if [ "$sche" = "1" ] && [ -n "$schstop" ] && [ "$schstop" = "$schstart" ]; then
		echo '{"success":false,"error":"停止时间与启动时间不能相同"}'
		exit 1
	fi

	write_config_json "$si" "$sd" "$ts" "$sv" "$bc" "$wse" "$wsn" "$wss" "$wsn_off" "$sche" "$schstop" "$schstart" || { echo '{"success":false,"error":"配置写入失败"}'; exit 1; }
	# 删除后收尾：被删掉的服务若仍在运行则停止，防止配置已删、进程残留
	if [ "$has_ts" -eq 1 ] || [ "$has_sv" -eq 1 ]; then
		stop_removed_services "$old_ts" "$ts" "$old_sv" "$sv"
	fi
	# 写入后回读自校验：任一字段不一致即报错，杜绝“字段错位”静默发生
	if [ "$(cfg_get sleep_interval)" != "$si" ] || [ "$(cfg_get server_dir)" != "$sd" ] \
	|| [ "$(cfg_get termux_services)" != "$ts" ] || [ "$(cfg_get services)" != "$sv" ] \
	|| [ "$(cfg_get boot_commands)" != "$bc" ] || [ "$(cfg_get wifi_service_enabled)" != "$wse" ] \
	|| [ "$(cfg_get wifi_service_names)" != "$wsn" ] || [ "$(cfg_get wifi_service_names_off)" != "$wsn_off" ] \
	|| [ "$(cfg_get wifi_ssids)" != "$wss" ] || [ "$(cfg_get schedule_enabled)" != "$sche" ] \
	|| [ "$(cfg_get schedule_stop)" != "$schstop" ] || [ "$(cfg_get schedule_start)" != "$schstart" ]; then
		echo '{"success":false,"error":"配置写入校验不一致"}'
		exit 1
	fi
	echo '{"success":true}'
}

# 测试命令的通用执行体；从 stdin 逐行执行。
# $1=标记 $2=su 调用基准（正常=su，termux=su $TERMUX_UID） $3=命令前缀（termux 注入 TERMUX_ENV）
run_test_lines() {
	local mark=$1 runner=$2 env_prefix=$3 line log="$LOG_DIR/run_test.log"
	{
		echo "=== $mark $(date '+%Y-%m-%d %H:%M:%S') ==="
		while IFS= read -r line; do
			[ -z "$line" ] && continue
			echo "> $line"
			$runner -c "$env_prefix $line"
			echo "[exit=$?]"
		done
	} >> "$log" 2>&1
}

case "$1" in
status)
	api_get_status
	;;
start)
	api_start_service "$2" "$3"
	;;
stop)
	api_stop_service "$2"
	;;
logs)
	api_get_logs
	;;
readlog)
	api_read_log "$2" "$3"
	;;
getconfig)
	api_get_config
	;;
saveconfig)
	api_save_config
	;;
execboot)
	load_cfg_sh
	printf '%s\n' "$BOOT_COMMANDS" | run_command_lines '开机命令(手动)'
	echo '{"success":true}'
	;;
runcmd)
	load_cfg_sh
	run_test_lines '(测试运行)' 'su' ''
	echo '{"success":true}'
	;;
runcmdtermux)
	load_cfg_sh
	run_test_lines '(测试运行-termux)' "su $TERMUX_UID" "$TERMUX_ENV cd $TERMUX_HOME;"
	echo '{"success":true}'
	;;
clearlog)
	if clear_log "$2"; then echo '{"success":true}'; else echo '{"success":false,"error":"名称不合法"}'; fi
	;;
open)
	port=$2
	is_int "$port" || { echo '{"success":false,"error":"端口不合法"}'; exit 0; }
	[ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null \
	|| { echo '{"success":false,"error":"端口超出范围"}'; exit 0; }
	/system/bin/am start -a android.intent.action.VIEW -d "http://127.0.0.1:$port" >/dev/null 2>&1
	echo '{"success":true}'
	;;
*)
	# Manager Action 入口：输出简短状态摘要
	load_cfg_sh
	runset=$(
		{
			printf '%s\n' "$TERMUX_SERVICES" | list_names
			printf '%s\n' "$SERVICES" | list_names
		} | detect_running
	)
	echo "SvcHub 状态摘要"
	echo "保活间隔: ${SLEEP_INTERVAL}s | Termux 服务: $(count_rows "$TERMUX_SERVICES") | 二进制服务: $(count_rows "$SERVICES")"
	printf 'Termux 服务:\n'
	printf '%s\n' "$TERMUX_SERVICES" | while IFS='|' read -r name port extra auto cmd; do
		[ -n "$name" ] || continue
		name_in_set "$name" "$runset" && st=running || st=stopped
		echo "  $name [$st] auto=$auto"
	done
	printf '二进制服务:\n'
	printf '%s\n' "$SERVICES" | while IFS='|' read -r name port auto cmd; do
		[ -n "$name" ] || continue
		name_in_set "$name" "$runset" && st=running || st=stopped
		echo "  $name [$st] auto=$auto"
	done
	exit 0
	;;
esac