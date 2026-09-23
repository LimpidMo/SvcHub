#!/system/bin/sh
# SvcHub Action / WebUI 固定子命令 API。
# 每个子命令都做白名单校验；不执行任意 shell、不使用 pkill -f 模糊匹配、不做 eval。
# 被 source 时（api.cgi 同进程透传）只定义函数，不重设 MODDIR、不执行分发。
if [ -z "$ACTION_SOURCED" ]; then
MODDIR=${0%/*}
[ -n "$MODDIR" ] && [ -d "$MODDIR" ] || exit 1
. "$MODDIR/lib.sh" 2>/dev/null || exit 1
fi

# 行数统计：grep -c 无匹配时已输出 0，仅吞掉非零退出码（避免二次 echo 0 拼成两行）
count_rows() {
	printf '%s\n' "$1" | grep -c '^[^|]\{1,\}|' 2>/dev/null || true
}

# 服务行校验：合法输出空，非法输出首个非法行号（saveservices 指明行号、saveconfig 判空共用）。
validate_rows() {
	# $1=kind(termux_services|binary_services，兼容旧 services)；从 stdin 逐行校验格式
	local kind=$1 r=0 line name port extra auto cmd
	while IFS= read -r line; do
		[ -z "$line" ] && continue
		r=$((r + 1))
		if [ "$r" -gt 500 ]; then printf '%s' "$r"; return 0; fi
		case "$kind" in
		termux_services)
			IFS='|' read -r name port extra auto cmd <<EOF
$line
EOF
			valid_name "$name" || { printf '%s' "$r"; return 0; }
			[ -n "$cmd" ] || { printf '%s' "$r"; return 0; }
			case "$auto" in start|stop) ;; *) printf '%s' "$r"; return 0 ;; esac
			case "$port" in *\|*) printf '%s' "$r"; return 0 ;; esac
			[ "${#port}" -le 32 ] || { printf '%s' "$r"; return 0; }
			case "$extra" in
			*'$'*|*'`'*|*';'*|*'&'*|*'|'*|*'('*|*')'*|*'<'*|*'>'*|*'"'*|*"'"'*|*'\'*) printf '%s' "$r"; return 0 ;;
			esac
			;;
		services|binary_services)
			# 内存 6 段 name|port|extra|auto|cmd（extra 恒空）；旧 4 段兼容。
			case "$line" in
			*\|*\|*\|*\|*)
				IFS='|' read -r name port extra auto cmd <<EOF
$line
EOF
				[ -z "$extra" ] || { printf '%s' "$r"; return 0; }
				;;
			*)
				IFS='|' read -r name port auto cmd <<EOF
$line
EOF
				;;
			esac
			valid_name "$name" || { printf '%s' "$r"; return 0; }
			[ -n "$cmd" ] || { printf '%s' "$r"; return 0; }
			case "$auto" in start|stop) ;; *) printf '%s' "$r"; return 0 ;; esac
			case "$port" in *\|*) printf '%s' "$r"; return 0 ;; esac
			[ "${#port}" -le 32 ] || { printf '%s' "$r"; return 0; }
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
# 运行名单经环境变量 RUNSET 传入（$1）；行列表从 stdin 读。两类内存统一 5 段，输出结构相同。
rows_to_json() {
	RUNSET=$1 awk '
BEGIN { FS = "|"; runset = ENVIRON["RUNSET"] }
function esc(s,   o, i, n, c) {
	o = ""; n = length(s)
	for (i = 1; i <= n; i++) {
		c = substr(s, i, 1)
		if (c == "\\") o = o "\\\\"
		else if (c == "\"") o = o "\\\""
		else if (c == "\t") o = o "\\t"
		else o = o c
	}
	return o
}
$1 != "" {
	st = index("\n" runset "\n", "\n" $1 "\n") > 0 ? "running" : "stopped"
	# cmd 是末段，含 | 的管道命令需从第 5 段起重拼（$5 会截断）
	cmd = $5
	for (i = 6; i <= NF; i++) cmd = cmd "|" $i
	if (n++) printf ","
	printf "{\"name\":\"%s\",\"port\":\"%s\",\"status\":\"%s\",\"extra\":\"%s\",\"auto\":\"%s\",\"cmd\":\"%s\"}", esc($1), esc($2), st, esc($3), esc($4), esc(cmd)
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
	rows_to_json "$runset" <<EOF
$TERMUX_SERVICES
EOF
	printf '],"binary_services":['
	rows_to_json "$runset" <<EOF
$BINARY_SERVICES
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
		IFS='|' read -r _ port extra auto cmd <<EOF
$row
EOF
		stop_svc "$name"
		if launch_svc binary "$name" "$extra" "$cmd"; then
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
	# $1=日志名 $2=行数（默认 500，上限 2000；0=全文）。
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

# 设置页按需读：13 设置键（不含服务行）。
api_get_settings() {
	load_cfg_sh
	{
		printf '{"sleep_interval":"'
		printf '%s' "$SLEEP_INTERVAL" | enc_js
		printf '","server_dir":"'
		printf '%s' "$SERVER_DIR" | enc_js
		printf '","boot_commands":"'
		printf '%s' "$BOOT_COMMANDS" | enc_js
		printf '","wifi_service_enabled":"'
		printf '%s' "$WIFI_SERVICE_ENABLED" | enc_js
		printf '","wifi_service_names":"'
		printf '%s' "$WIFI_SERVICE_NAMES" | enc_js
		printf '","wifi_service_names_off":"'
		printf '%s' "$WIFI_SERVICE_NAMES_OFF" | enc_js
		printf '","wifi_ssids":"'
		printf '%s' "$WIFI_SSIDS" | enc_js
		printf '","schedule_enabled":"'
		printf '%s' "$SCHEDULE_ENABLED" | enc_js
		printf '","schedule_stop":"'
		printf '%s' "$SCHEDULE_STOP" | enc_js
		printf '","schedule_start":"'
		printf '%s' "$SCHEDULE_START" | enc_js
		printf '","webui_enabled":"'
		printf '%s' "$WEBUI_ENABLED" | enc_js
		printf '","webui_password_hash":"'
		printf '%s' "$WEBUI_PASSWORD_HASH" | enc_js
		printf '","webui_token":"'
		printf '%s' "$WEBUI_TOKEN" | enc_js
		printf '"}\n'
	}
}

# 服务页按需读：两类服务行（前端 parseRows 不动）。
api_get_services() {
	load_cfg_sh
	{
		printf '{"termux_services":"'
		printf '%s' "$TERMUX_SERVICES" | enc_js
		printf '","binary_services":"'
		printf '%s' "$BINARY_SERVICES" | enc_js
		printf '"}\n'
	}
}

# 旧全量读兼容层：设置 + 服务拼装（字段与原来一致，前端迁移完成前可用）。
api_get_config() {
	load_cfg_sh
	{
		printf '{"sleep_interval":"'
		printf '%s' "$SLEEP_INTERVAL" | enc_js
		printf '","server_dir":"'
		printf '%s' "$SERVER_DIR" | enc_js
		printf '","termux_services":"'
		printf '%s' "$TERMUX_SERVICES" | enc_js
		printf '","services":"'
		printf '%s' "$BINARY_SERVICES" | enc_js
		printf '","boot_commands":"'
		printf '%s' "$BOOT_COMMANDS" | enc_js
		printf '","wifi_service_enabled":"'
		printf '%s' "$WIFI_SERVICE_ENABLED" | enc_js
		printf '","wifi_service_names":"'
		printf '%s' "$WIFI_SERVICE_NAMES" | enc_js
		printf '","wifi_service_names_off":"'
		printf '%s' "$WIFI_SERVICE_NAMES_OFF" | enc_js
		printf '","wifi_ssids":"'
		printf '%s' "$WIFI_SSIDS" | enc_js
		printf '","schedule_enabled":"'
		printf '%s' "$SCHEDULE_ENABLED" | enc_js
		printf '","schedule_stop":"'
		printf '%s' "$SCHEDULE_STOP" | enc_js
		printf '","schedule_start":"'
		printf '%s' "$SCHEDULE_START" | enc_js
		printf '","webui_enabled":"'
		printf '%s' "$WEBUI_ENABLED" | enc_js
		printf '","webui_password_hash":"'
		printf '%s' "$WEBUI_PASSWORD_HASH" | enc_js
		printf '","webui_token":"'
		printf '%s' "$WEBUI_TOKEN" | enc_js
		printf '"}\n'
	}
}

# 测试运行命令：stdin 读 shell 文本逐行执行记日志（$1=termux 时注入 Termux 环境）。
api_run_cmd() {
	local mode=$1 runner=su env_prefix=
	load_cfg_sh
	if [ "$mode" = termux ]; then
		runner="su $(termux_uid)"
		env_prefix="$TERMUX_ENV cd $TERMUX_HOME;"
	fi
	run_lines "$LOG_DIR/run_test.log" '(测试运行)' "$runner" "$env_prefix"
	echo '{"success":true}'
}

# 手动执行开机命令（复用开机同一 runner 记账）。
api_exec_boot() {
	load_cfg_sh
	printf '%s\n' "$BOOT_COMMANDS" | run_lines "$LOG_DIR/boot_commands.log" '开机命令(手动)'
	echo '{"success":true}'
}

# 外部访问：开关启停 httpd，密码/Token 走专用子命令。
api_webui_enable() {
	load_cfg_sh
	if [ -f "$DISABLE_FILE" ]; then
		echo '{"success":false,"error":"模块已禁用，无法开启外部访问"}'
		exit 1
	fi
	# 默认哈希落盘（内存值首次调用时写回）
	if [ "$WEBUI_PASSWORD_HASH_NEED_SAVE" = "1" ]; then
		write_settings 2>/dev/null
		load_cfg_sh
	fi
	if [ -z "$WEBUI_PASSWORD_HASH" ]; then
		echo '{"success":false,"error":"请先设置密码"}'
		exit 1
	fi
	WEBUI_ENABLED=1
	write_settings || { echo '{"success":false,"error":"配置写入失败"}'; exit 1; }
	sh "$MODDIR/httpd.sh" start
	rc=$?
	if [ "$rc" -eq 0 ]; then
		echo '{"success":true}'
	else
		case "$rc" in
		2) echo '{"success":false,"error":"未找到可用 busybox（含 httpd）"}' ;;
		3) echo "{\"success\":false,\"error\":\"端口 $WEBUI_PORT 被占用\"}" ;;
		5) echo '{"success":false,"error":"api.cgi 无可执行权限，请重装模块"}' ;;
		*) echo '{"success":false,"error":"httpd 启动失败，请查看 webui 日志"}' ;;
		esac
		exit 1
	fi
}

api_webui_disable() {
	load_cfg_sh
	WEBUI_ENABLED=0
	write_settings || { echo '{"success":false,"error":"配置写入失败"}'; exit 1; }
	if sh "$MODDIR/httpd.sh" stop >/dev/null 2>&1; then
		echo '{"success":true}'
	else
		echo '{"success":false,"error":"httpd 停止失败，进程仍存活，请查看 webui 日志"}'
		exit 1
	fi
}

# 设置密码：stdin 读 password/old（BASE64），已有哈希须验旧密码。
api_webui_set_password() {
	local line key b64 password="" old="" salt
	load_cfg_sh
	# 末行无尾随换行仍要处理（fetch body 无尾随换行，read 会返回非零）。
	while IFS= read -r line || [ -n "$line" ]; do
		[ -z "$line" ] && continue
		key=${line%%=*}
		b64=${line#*=}
		case "$key" in password|old) ;; *) echo '{"success":false,"error":"未知参数"}'; exit 1 ;; esac
		case "$b64" in
		*[!A-Za-z0-9+/=]*) echo '{"success":false,"error":"编码错误"}'; exit 1 ;;
		esac
		if [ "$key" = password ]; then
			password=$(printf '%s' "$b64" | base64 -d 2>/dev/null) || { echo '{"success":false,"error":"解码失败"}'; exit 1; }
		else
			old=$(printf '%s' "$b64" | base64 -d 2>/dev/null) || { echo '{"success":false,"error":"解码失败"}'; exit 1; }
		fi
	done
	[ "${#password}" -ge 6 ] || { echo '{"success":false,"error":"密码至少 6 位"}'; exit 1; }
	[ "${#password}" -le 256 ] || { echo '{"success":false,"error":"密码过长"}'; exit 1; }
	if [ -n "$WEBUI_PASSWORD_HASH" ]; then
		webui_check_password "$old" "$WEBUI_PASSWORD_HASH" || { echo '{"success":false,"error":"旧密码错误"}'; exit 1; }
	fi
	salt=$(webui_gen_token | head -c 32)
	[ "${#salt}" -eq 32 ] || { echo '{"success":false,"error":"随机数生成失败"}'; exit 1; }
	WEBUI_PASSWORD_HASH=$(printf '%s' "$password" | webui_hash_password "$salt") || { echo '{"success":false,"error":"密码哈希失败"}'; exit 1; }
	[ -n "$WEBUI_TOKEN" ] || WEBUI_TOKEN=$(webui_gen_token) || { echo '{"success":false,"error":"Token 生成失败"}'; exit 1; }
	write_settings || { echo '{"success":false,"error":"配置写入失败"}'; exit 1; }
	[ "$(setting_get webui_password_hash)" = "$WEBUI_PASSWORD_HASH" ] || { echo '{"success":false,"error":"配置写入校验不一致"}'; exit 1; }
	# 改密清全部会话，强制重登。
	rm -f "$WEBUI_SESS_DIR"/sess_* 2>/dev/null
	echo '{"success":true}'
}

# 轮换长期 Token（旧 Token 登录态全部失效）。
api_webui_regen_token() {
	load_cfg_sh
	WEBUI_TOKEN=$(webui_gen_token) || { echo '{"success":false,"error":"Token 生成失败"}'; exit 1; }
	[ "${#WEBUI_TOKEN}" -eq 64 ] || { echo '{"success":false,"error":"Token 生成失败"}'; exit 1; }
	write_settings || { echo '{"success":false,"error":"配置写入失败"}'; exit 1; }
	[ "$(setting_get webui_token)" = "$WEBUI_TOKEN" ] || { echo '{"success":false,"error":"配置写入校验不一致"}'; exit 1; }
	# Token 轮换同样清会话。
	rm -f "$WEBUI_SESS_DIR"/tsess_* 2>/dev/null
	printf '{"success":true,"token":"%s"}\n' "$WEBUI_TOKEN"
}

# 查询长期 Token 明文。
api_webui_token_show() {
	load_cfg_sh
	printf '{"success":true,"token":"%s"}\n' "$WEBUI_TOKEN"
}

# 外部访问状态（轻量读取，不跑全量 load）。
api_webui_status() {
	local running=stopped enabled haspw
	svc_running httpd && running=running
	read -r enabled haspw <<EOF
$(webui_status_fast)
EOF
	printf '{"success":true,"enabled":"%s","running":"%s","has_password":%s,"listen":"%s","port":%s}\n' \
		"$enabled" "$running" "$haspw" "$WEBUI_LISTEN" "$WEBUI_PORT"
}

# 单键校验落盘：$1=key $2=解码值（非法直接 exit 1）。
cfg_apply_one() {
	local key=$1 val=$2 invalid_name ssid_lines
	case "$key" in
	sleep_interval)
		[ -n "$val" ] || val=60
		is_int "$val" || { echo '{"success":false,"error":"间隔必须为数字"}'; exit 1; }
		[ "$val" -lt 10 ] && val=10
		[ "$val" -gt 86400 ] && val=86400
		SLEEP_INTERVAL=$val
		;;
	server_dir) SERVER_DIR=$val ;;
	termux_services|services)
		bad=$(printf '%s\n' "$val" | validate_rows "$key")
		[ -z "$bad" ] || { echo '{"success":false,"error":"服务配置格式错误"}'; exit 1; }
		if [ "$key" = termux_services ]; then TERMUX_SERVICES=$val; else BINARY_SERVICES=$val; fi
		;;
	boot_commands) BOOT_COMMANDS=$val ;;
	wifi_service_enabled)
		case "$val" in
		0|1) WIFI_SERVICE_ENABLED=$val ;;
		*) echo '{"success":false,"error":"Wi-Fi 功能开关必须为 0 或 1"}'; exit 1 ;;
		esac
		;;
	wifi_service_names|wifi_service_names_off)
		invalid_name=$(printf '%s\n' "$val" | awk '{ gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if ($0 != "" && $0 !~ /^[A-Za-z0-9._-]+$/) { print $0; exit } }')
		if [ -n "$invalid_name" ]; then
			echo "{\"success\":false,\"error\":\"Wi-Fi 服务名不合法: $invalid_name\"}"
			exit 1
		fi
		if [ "$key" = wifi_service_names ]; then WIFI_SERVICE_NAMES=$val; else WIFI_SERVICE_NAMES_OFF=$val; fi
		;;
	wifi_ssids)
		# SSID 允中文/符号/emoji（| 与真换行由前端剔除），只限长度行数。
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
}

# 写后自校验：回读 sleep_interval 一键探活（写盘失败/错位时该键必不一致）。
cfg_verify_written() {
	[ "$(setting_get sleep_interval)" = "$SLEEP_INTERVAL" ] || { echo '{"success":false,"error":"配置写入校验不一致"}'; exit 1; }
}

# stdin 读 key=BASE64 行，白名单校验后落盘（未提供的键沿用现值；旧全量兼容层，按 key 路由双文件）。
api_save_config() {
	local line key b64 val bad provided= old_ts old_sv need_settings= need_services=
	load_cfg_sh
	old_ts=$TERMUX_SERVICES
	old_sv=$BINARY_SERVICES
	# 末行无尾随换行仍处理（fetch body 无尾换行时 read 返回非零）。
	while IFS= read -r line || [ -n "$line" ]; do
		[ -z "$line" ] && continue
		key=${line%%=*}
		b64=${line#*=}
		# webui_* 走专用子命令，禁止经 saveconfig 覆盖。
		case "$key" in
		webui_*) echo '{"success":false,"error":"外部访问配置请用专用接口修改"}'; exit 1 ;;
		esac
		word_in_set "$key" "$CONFIG_KEYS" || { echo '{"success":false,"error":"未知配置键"}'; exit 1; }
		case "$b64" in
		*[!A-Za-z0-9+/=]*) echo '{"success":false,"error":"配置编码错误"}'; exit 1 ;;
		esac
		val=$(printf '%s' "$b64" | base64 -d 2>/dev/null) || { echo '{"success":false,"error":"配置解码失败"}'; exit 1; }
		[ "${#val}" -le 1048576 ] || { echo '{"success":false,"error":"配置内容过大"}'; exit 1; }
		cfg_apply_one "$key" "$val"
		provided="$provided $key"
		case "$key" in
		termux_services|services) need_services=1 ;;
		*) need_settings=1 ;;
		esac
	done
	# 空 body 不能当成功写回旧值（否则前端误报“已保存”）。
	[ -n "$provided" ] || { echo '{"success":false,"error":"配置内容为空"}'; exit 1; }
	# 启用时起止相同无意义（进窗判定恒窗外），直接拒绝。
	if [ "$SCHEDULE_ENABLED" = "1" ] && [ -n "$SCHEDULE_STOP" ] && [ "$SCHEDULE_STOP" = "$SCHEDULE_START" ]; then
		echo '{"success":false,"error":"停止时间与启动时间不能相同"}'
		exit 1
	fi

	[ -n "$need_settings" ] && { write_settings || { echo '{"success":false,"error":"配置写入失败"}'; exit 1; }; }
	[ -n "$need_services" ] && { write_services || { echo '{"success":false,"error":"配置写入失败"}'; exit 1; }; }
	# 被删服务仍在运行则停，防止配置已删进程残留。
	if word_in_set termux_services "$provided" || word_in_set services "$provided"; then
		stop_removed_services "$old_ts" "$TERMUX_SERVICES" "$old_sv" "$BINARY_SERVICES"
	fi
	cfg_verify_written
	echo '{"success":true}'
}

# 设置页按需保存：只接受 SETTING_KEYS（webui_* 直接拒），只写 setting.conf。
api_save_settings() {
	local line key b64 val provided=
	load_cfg_sh
	while IFS= read -r line || [ -n "$line" ]; do
		[ -z "$line" ] && continue
		key=${line%%=*}
		b64=${line#*=}
		case "$key" in
		webui_*) echo '{"success":false,"error":"外部访问配置请用专用接口修改"}'; exit 1 ;;
		esac
		word_in_set "$key" "$SETTING_KEYS" || { echo '{"success":false,"error":"未知配置键"}'; exit 1; }
		case "$b64" in
		*[!A-Za-z0-9+/=]*) echo '{"success":false,"error":"配置编码错误"}'; exit 1 ;;
		esac
		val=$(printf '%s' "$b64" | base64 -d 2>/dev/null) || { echo '{"success":false,"error":"配置解码失败"}'; exit 1; }
		[ "${#val}" -le 1048576 ] || { echo '{"success":false,"error":"配置内容过大"}'; exit 1; }
		cfg_apply_one "$key" "$val"
		provided="$provided $key"
	done
	[ -n "$provided" ] || { echo '{"success":false,"error":"配置内容为空"}'; exit 1; }
	if [ "$SCHEDULE_ENABLED" = "1" ] && [ -n "$SCHEDULE_STOP" ] && [ "$SCHEDULE_STOP" = "$SCHEDULE_START" ]; then
		echo '{"success":false,"error":"停止时间与启动时间不能相同"}'
		exit 1
	fi
	write_settings || { echo '{"success":false,"error":"配置写入失败"}'; exit 1; }
	cfg_verify_written
	echo '{"success":true}'
}

# 服务页按需保存：只接受 termux_services/services，只写 services.conf；非法整单拒绝并带行号。
api_save_services() {
	local line key b64 val provided= old_ts old_sv bad
	load_cfg_sh
	old_ts=$TERMUX_SERVICES
	old_sv=$BINARY_SERVICES
	while IFS= read -r line || [ -n "$line" ]; do
		[ -z "$line" ] && continue
		key=${line%%=*}
		b64=${line#*=}
		case "$key" in
		termux_services|binary_services) ;;
		*) echo '{"success":false,"error":"未知配置键"}'; exit 1 ;;
		esac
		case "$b64" in
		*[!A-Za-z0-9+/=]*) echo '{"success":false,"error":"配置编码错误"}'; exit 1 ;;
		esac
		val=$(printf '%s' "$b64" | base64 -d 2>/dev/null) || { echo '{"success":false,"error":"配置解码失败"}'; exit 1; }
		[ "${#val}" -le 1048576 ] || { echo '{"success":false,"error":"配置内容过大"}'; exit 1; }
		bad=$(printf '%s\n' "$val" | validate_rows "$key")
		[ -z "$bad" ] || { echo "{\"success\":false,\"error\":\"服务配置格式错误（第 $bad 行）\"}"; exit 1; }
		if [ "$key" = termux_services ]; then TERMUX_SERVICES=$val; else BINARY_SERVICES=$val; fi
		provided="$provided $key"
	done
	[ -n "$provided" ] || { echo '{"success":false,"error":"配置内容为空"}'; exit 1; }
	write_services || { echo '{"success":false,"error":"配置写入失败"}'; exit 1; }
	stop_removed_services "$old_ts" "$TERMUX_SERVICES" "$old_sv" "$BINARY_SERVICES"
	echo '{"success":true}'
}

# 被 source 时只定义函数，不执行分发（api.cgi 同进程透传用）。
if [ -z "$ACTION_SOURCED" ]; then
case "$1" in
status)
	api_get_status
	;;start)
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
getsettings)
	api_get_settings
	;;
getservices)
	api_get_services
	;;
saveconfig)
	api_save_config
	;;
savesettings)
	api_save_settings
	;;
saveservices)
	api_save_services
	;;
webuistart)
	api_webui_enable
	;;
webuistop)
	api_webui_disable
	;;
webuistatus)
	api_webui_status
	;;
webuipasswd)
	api_webui_set_password
	;;
webuiregen)
	api_webui_regen_token
	;;
webuitoken)
	api_webui_token_show
	;;
execboot)
	api_exec_boot
	;;
runcmd)
	api_run_cmd
	;;
runcmdtermux)
	api_run_cmd termux
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
	echo "保活间隔: ${SLEEP_INTERVAL}s | Termux 服务: $(count_rows "$TERMUX_SERVICES") | 二进制服务: $(count_rows "$BINARY_SERVICES")"
	printf 'Termux 服务:\n'
	printf '%s\n' "$TERMUX_SERVICES" | while IFS='|' read -r name port extra auto cmd; do
		[ -n "$name" ] || continue
		name_in_set "$name" "$runset" && st=running || st=stopped
		echo "  $name [$st] auto=$auto"
	done
	printf '二进制服务:\n'
	printf '%s\n' "$BINARY_SERVICES" | while IFS='|' read -r name port extra auto cmd; do
		[ -n "$name" ] || continue
		name_in_set "$name" "$runset" && st=running || st=stopped
		echo "  $name [$st] auto=$auto"
	done
	exit 0
	;;
esac
fi
