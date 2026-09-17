#!/system/bin/sh
# SvcHub Action / WebUI 固定子命令 API。
# 每个子命令都做白名单校验；不执行任意 shell、不使用 pkill -f 模糊匹配、不做 eval。
MODDIR=${0%/*}
[ -n "$MODDIR" ] && [ -d "$MODDIR" ] || exit 1
. "$MODDIR/lib.sh" 2>/dev/null || exit 1

# 行数统计：grep -c 无匹配时已输出 0，仅吞掉非零退出码（避免二次 echo 0 拼成两行）
count_rows() {
	printf '%s\n' "$1" | grep -c '^[^|]\{1,\}|' 2>/dev/null || true
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
	local runset boot_id
	load_cfg_sh
	# 批量检测全部服务运行状态（单次遍历 pid 文件），避免逐服务 fork
	runset=$(compute_runset)
	boot_id=$(cat "$BOOTID_FILE" 2>/dev/null)
	printf '{"boot_id":"%s","server_dir":"%s","termux_services":[' "$(printf '%s' "$boot_id" | enc_js)" "$(printf '%s' "$SERVER_DIR" | enc_js)"
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
		if launch_svc termux "$name" "$extra" "$cmd"; then
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
		if launch_svc binary "$name" "" "$cmd"; then
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
	local first=1 l n
	printf '{"logs":['
	for l in "$LOG_DIR"/*.log; do
		[ -f "$l" ] || continue
		n=$(basename "$l" .log)
		[ "$n" = supervisor ] && continue
		[ "$first" -eq 0 ] && printf ','
		first=0
		printf '"%s"' "$(printf '%s' "$n" | enc_js)"
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
	local key first=1
	printf '{'
	for key in $CONFIG_KEYS; do
		[ "$first" -eq 1 ] || printf ','
		first=0
		printf '"%s":"%s"' "$key" "$(printf '%s' "$(cfg_global "$key")" | enc_js)"
	done
	printf '}\n'
}

# 从 stdin 读 key=BASE64VALUE 行；白名单校验后一次性写入 config.json（明文 JSON）。
# 先 load_cfg_sh 让未提供的键沿用现有配置，解析通过的键直接覆盖全局变量，
# 最后 write_config_json 从全局变量统一落盘。
api_save_config() {
	local line key b64 val provided= old_ts old_sv invalid_name ssid_lines k
	load_cfg_sh
	old_ts=$TERMUX_SERVICES
	old_sv=$SERVICES
	while IFS= read -r line; do
		[ -z "$line" ] && continue
		key=${line%%=*}
		b64=${line#*=}
		word_in_set "$key" "$CONFIG_KEYS" || { echo '{"success":false,"error":"未知配置键"}'; exit 1; }
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
			SLEEP_INTERVAL=$val
			;;
		server_dir)
			SERVER_DIR=$val
			;;
		termux_services|services)
			printf '%s\n' "$val" | validate_rows "$key" || { echo '{"success":false,"error":"服务配置格式错误"}'; exit 1; }
			if [ "$key" = termux_services ]; then TERMUX_SERVICES=$val; else SERVICES=$val; fi
			;;
		boot_commands)
			BOOT_COMMANDS=$val
			;;
		wifi_service_enabled)
			case "$val" in
			0|1) WIFI_SERVICE_ENABLED=$val ;;
			*) echo '{"success":false,"error":"Wi-Fi 功能开关必须为 0 或 1"}'; exit 1 ;;
			esac
			;;
		wifi_service_names|wifi_service_names_off)
			# 校验多行文本中的服务名是否合法（仅允许字母数字点横线）
			invalid_name=$(printf '%s\n' "$val" | awk '{ gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if ($0 != "" && $0 !~ /^[A-Za-z0-9._-]+$/) { print $0; exit } }')
			if [ -n "$invalid_name" ]; then
				echo "{\"success\":false,\"error\":\"Wi-Fi 服务名不合法: $invalid_name\"}"
				exit 1
			fi
			if [ "$key" = wifi_service_names ]; then WIFI_SERVICE_NAMES=$val; else WIFI_SERVICE_NAMES_OFF=$val; fi
			;;
		wifi_ssids)
			# SSID 允许中文/空格/符号/emoji：与存储分隔符冲突的 | 与真实换行
			# 由前端剔除，这里只做长度与行数上限 + 拒绝注入配置解析的异常字符
			if [ "${#val}" -gt 10000 ]; then
				echo '{"success":false,"error":"Wi-Fi SSID 列表过长"}'
				exit 1
			fi
			ssid_lines=$(printf '%s\n' "$val" | grep -c '^' 2>/dev/null || true)
			if [ "$ssid_lines" -gt 100 ]; then
				echo '{"success":false,"error":"Wi-Fi SSID 数量过多(最多100个)"}'
				exit 1
			fi
			WIFI_SSIDS=$val
			;;
		schedule_enabled)
			case "$val" in
			0|1) SCHEDULE_ENABLED=$val ;;
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
			if [ "$key" = schedule_stop ]; then SCHEDULE_STOP=$val; else SCHEDULE_START=$val; fi
			;;
		esac
		provided="$provided $key"
	done
	# 停止与启动时间相同无意义：启用状态下拒绝，避免进窗判定恒为窗外却让用户误以为生效
	if [ "$SCHEDULE_ENABLED" = "1" ] && [ -n "$SCHEDULE_STOP" ] && [ "$SCHEDULE_STOP" = "$SCHEDULE_START" ]; then
		echo '{"success":false,"error":"停止时间与启动时间不能相同"}'
		exit 1
	fi

	write_config_json || { echo '{"success":false,"error":"配置写入失败"}'; exit 1; }
	# 删除后收尾：被删掉的服务若仍在运行则停止，防止配置已删、进程残留
	if word_in_set termux_services "$provided" || word_in_set services "$provided"; then
		stop_removed_services "$old_ts" "$TERMUX_SERVICES" "$old_sv" "$SERVICES"
	fi
	# 写入后回读自校验：任一字段不一致即报错，杜绝“字段错位”静默发生
	for k in $CONFIG_KEYS; do
		[ "$(cfg_get "$k")" = "$(cfg_global "$k")" ] || { echo '{"success":false,"error":"配置写入校验不一致"}'; exit 1; }
	done
	echo '{"success":true}'
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
	printf '%s\n' "$BOOT_COMMANDS" | run_lines "$LOG_DIR/boot_commands.log" '开机命令(手动)'
	echo '{"success":true}'
	;;
runcmd)
	load_cfg_sh
	run_lines "$LOG_DIR/run_test.log" '(测试运行)' 'su' ''
	echo '{"success":true}'
	;;
runcmdtermux)
	load_cfg_sh
	run_lines "$LOG_DIR/run_test.log" '(测试运行-termux)' "su $TERMUX_UID" "$TERMUX_ENV cd $TERMUX_HOME;"
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
	runset=$(compute_runset)
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
