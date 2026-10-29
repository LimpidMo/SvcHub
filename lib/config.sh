# SvcHub 公共库：配置 schema 与读写（config/setting.conf 设置项 + config/services.conf 服务项 + config/web.conf）。

# 配置 schema 唯一定义：新增设置键需同步补全 setting_var_load / setting_var_set / action.sh cfg_apply_one 及前端字段。
# 序列化、重置、JSON 输出均按本清单自动跟随。
SETTING_KEYS='sleep_interval server_dir boot_commands wifi_service_enabled wifi_service_names wifi_service_names_off wifi_ssids schedule_enabled schedule_stop schedule_start screen_service_enabled screen_service_names screen_resume_names termux_root_names patrol_enabled wake_lock_enabled language webui_enabled webui_password_hash webui_password_default webui_token'

# 对外公开键（去掉密码哈希、长期 Token、默认密码标志三个敏感键），供 api_get_settings 使用；纯 shell 过滤，零 fork。
SETTING_PUBLIC_KEYS=""
for _cfg_key in $SETTING_KEYS; do
	case "$_cfg_key" in
	webui_password_hash|webui_token|webui_password_default) ;;
	*) SETTING_PUBLIC_KEYS="${SETTING_PUBLIC_KEYS:+$SETTING_PUBLIC_KEYS }$_cfg_key" ;;
	esac
done
unset _cfg_key

# 读取设置项当前值到 SV_VALUE（纯 shell，无 fork）；未知键返回 1。
setting_var_load() {
	case "$1" in
	sleep_interval) SV_VALUE=$SLEEP_INTERVAL ;;
	server_dir) SV_VALUE=$SERVER_DIR ;;
	boot_commands) SV_VALUE=$BOOT_COMMANDS ;;
	wifi_service_enabled) SV_VALUE=$WIFI_SERVICE_ENABLED ;;
	wifi_service_names) SV_VALUE=$WIFI_SERVICE_NAMES ;;
	wifi_service_names_off) SV_VALUE=$WIFI_SERVICE_NAMES_OFF ;;
	wifi_ssids) SV_VALUE=$WIFI_SSIDS ;;
	schedule_enabled) SV_VALUE=$SCHEDULE_ENABLED ;;
	schedule_stop) SV_VALUE=$SCHEDULE_STOP ;;
	schedule_start) SV_VALUE=$SCHEDULE_START ;;
	screen_service_enabled) SV_VALUE=$SCREEN_SERVICE_ENABLED ;;
	screen_service_names) SV_VALUE=$SCREEN_SERVICE_NAMES ;;
	screen_resume_names) SV_VALUE=$SCREEN_RESUME_NAMES ;;
	termux_root_names) SV_VALUE=$TERMUX_ROOT_NAMES ;;
	patrol_enabled) SV_VALUE=$PATROL_ENABLED ;;
	wake_lock_enabled) SV_VALUE=$WAKE_LOCK_ENABLED ;;
	language) SV_VALUE=$UI_LANG ;;
	webui_enabled) SV_VALUE=$WEBUI_ENABLED ;;
	webui_password_hash) SV_VALUE=$WEBUI_PASSWORD_HASH ;;
	webui_password_default) SV_VALUE=$WEBUI_PASSWORD_DEFAULT ;;
	webui_token) SV_VALUE=$WEBUI_TOKEN ;;
	*) SV_VALUE=""; return 1 ;;
	esac
}

# 输出设置项当前值（测试/调试用；生产路径直接用 setting_var_load 免子 shell）。
setting_var_get() {
	setting_var_load "$1" || return 1
	printf '%s' "$SV_VALUE"
}

# 设置键赋值（加载与保存共用；未知键直接忽略）
setting_var_set() {
	case "$1" in
	sleep_interval) SLEEP_INTERVAL=$2 ;;
	server_dir) SERVER_DIR=$2 ;;
	boot_commands) BOOT_COMMANDS=$2 ;;
	wifi_service_enabled) WIFI_SERVICE_ENABLED=$2 ;;
	wifi_service_names) WIFI_SERVICE_NAMES=$2 ;;
	wifi_service_names_off) WIFI_SERVICE_NAMES_OFF=$2 ;;
	wifi_ssids) WIFI_SSIDS=$2 ;;
	schedule_enabled) SCHEDULE_ENABLED=$2 ;;
	schedule_stop) SCHEDULE_STOP=$2 ;;
	schedule_start) SCHEDULE_START=$2 ;;
	screen_service_enabled) SCREEN_SERVICE_ENABLED=$2 ;;
	screen_service_names) SCREEN_SERVICE_NAMES=$2 ;;
	screen_resume_names) SCREEN_RESUME_NAMES=$2 ;;
	termux_root_names) TERMUX_ROOT_NAMES=$2 ;;
	patrol_enabled) PATROL_ENABLED=$2 ;;
	wake_lock_enabled) WAKE_LOCK_ENABLED=$2 ;;
	language) UI_LANG=$2 ;;
	webui_enabled) WEBUI_ENABLED=$2 ;;
	webui_password_hash) WEBUI_PASSWORD_HASH=$2 ;;
	webui_password_default) WEBUI_PASSWORD_DEFAULT=$2 ;;
	webui_token) WEBUI_TOKEN=$2 ;;
	esac
}

# 生成随机分隔行：保证不出现在任何值里（纯 shell 检查，零 fork），结果写 SV_SEP。
settings_sep() {
	local keys=$1 sep conflict k
	sep="__SVCHUB_SEP_$$_${RANDOM}_${RANDOM}__"
	while :; do
		conflict=""
		for k in $keys; do
			setting_var_load "$k" || SV_VALUE=""
			case "$SV_VALUE" in *"$sep"*) conflict=1; break ;; esac
		done
		[ -z "$conflict" ] && break
		sep="${sep}x"
	done
	SV_SEP=$sep
}

# 输出记录流：分隔行 / 键 / 值行（原样，可含换行）…；与 AWK_KV_STREAM 配对。
settings_stream() {
	local keys=$1 sep=$2 k
	for k in $keys; do
		printf '%s\n%s\n' "$sep" "$k"
		setting_var_load "$k" || SV_VALUE=""
		printf '%s\n' "$SV_VALUE"
	done
	printf '%s\n' "$sep"
}

# 设置项写成 setting.conf（单行 KEY=转义值；原子替换，600 权限）。
# 值经记录流交给单次 awk 转义，不再靠“下一键前缀”猜多行值边界。
write_settings() {
	local tmp="$SETTING_FILE.tmp" rc
	mkdir -p "$CONFIG_DIR" 2>/dev/null
	settings_sep "$SETTING_KEYS" || return 1
	settings_stream "$SETTING_KEYS" "$SV_SEP" | awk -v sep="$SV_SEP" "$AWK_ESC"'function emit(k, v) { printf "%s=%s\n", k, esc(v) }'"$AWK_KV_STREAM" > "$tmp"
	rc=$?
	[ "$rc" -eq 0 ] || { rm -f "$tmp"; return 1; }
	chmod 600 "$tmp" && mv -f "$tmp" "$SETTING_FILE" || { rm -f "$tmp"; return 1; }
	LOAD_CFG_DONE=""
}

# 服务项写成 services.conf（统一 6 段 type|name|port|auto|cmd|end_cmd，先全部 termux 再 # binary + 全部 binary；原子替换）。
# 首行 # svc-v1.4.0 为格式标记（附段序说明）：无标记按旧格式解析（旧 5 段补空 end_cmd、更旧 6 段丢 extra），写回即升级。
# 无参：直接从 load_cfg_sh 的 TERMUX_SERVICES / BINARY_SERVICES（内存统一 5 段 name|port|auto|cmd|end_cmd）读取。
write_services() {
	local tmp="$SERVICES_FILE.tmp"
	mkdir -p "$CONFIG_DIR" 2>/dev/null
	# 单次 awk 拼装（原两个 printf|while 子 shell）：逐行加前缀、剔空行、补标记行
	TERMUX_SV=$TERMUX_SERVICES BINARY_SV=$BINARY_SERVICES awk '
	BEGIN {
		printf "# svc-v1.4.0 type|name|port|auto|cmd|end_cmd\n"
		n = split(ENVIRON["TERMUX_SV"], a, "\n")
		for (i = 1; i <= n; i++) if (a[i] != "") printf "termux|%s\n", a[i]
		printf "# binary\n"
		n = split(ENVIRON["BINARY_SV"], b, "\n")
		for (i = 1; i <= n; i++) if (b[i] != "") printf "binary|%s\n", b[i]
	}' > "$tmp" && mv -f "$tmp" "$SERVICES_FILE"
	LOAD_CFG_DONE=""
}

# ---------- 配置加载 ----------

# 读 setting.conf 到设置类全局变量（不碰服务行；含转义的值走 dec_js_rows 批量解码，免逐值 fork）。
# 格式契约：单行 KEY=value，等号两侧不得有空格（KEY 为小写下划线标识符，与各写入方一致），# 开头为注释行
load_settings() {
	local f="$SETTING_FILE" line k v CR
	CR=$(printf '\r')
	# 重置全部设置键（键清单唯一来源；language 清空后由 load_cfg_sh 归一为 zh）
	for k in $SETTING_KEYS; do
		setting_var_set "$k" ""
	done
	[ -f "$f" ] || return 0
	# 无转义值时零 fork：直接按行解析；有转义才起一次 awk 批量解码
	if grep -q '\\' "$f" 2>/dev/null; then
		dec_js_rows < "$f" > "$f.dec.$$"
		# NUL 分隔读 key/value；管道会让 while 进子 shell 丢赋值，故用临时文件
		while IFS= read -r -d '' k && IFS= read -r -d '' v; do
			setting_var_set "$k" "$v"
		done < "$f.dec.$$"
		rm -f "$f.dec.$$"
		return 0
	fi
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in *"$CR") line=${line%"$CR"} ;; esac
		case "$line" in ''|'#'*) continue ;; esac
		k=${line%%=*}
		v=${line#*=}
		[ "$line" = "$k" ] && v=""
		setting_var_set "$k" "$v"
	done < "$f"
}

# 单键读 setting.conf（明文；不存在/无该键输出空）。
setting_file_get() {
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

	# 唤醒锁：缺键默认关闭（内核不支持时同样静默降级）
	if [ -z "$WAKE_LOCK_ENABLED" ]; then
		WAKE_LOCK_ENABLED="0"
	elif [ "$WAKE_LOCK_ENABLED" != "0" ] && [ "$WAKE_LOCK_ENABLED" != "1" ]; then
		WAKE_LOCK_ENABLED="0"
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
	# 生成默认哈希时同步标记「仍是默认密码」，外部通道据此强制首次改密。
	WEBUI_PASSWORD_HASH_NEED_SAVE=""
	if [ -z "$WEBUI_PASSWORD_HASH" ] && [ -z "$WEBUI_PASSWORD_HASH_DONE" ]; then
		WEBUI_PASSWORD_HASH_SALT=$(webui_gen_token | head -c 32)
		if [ "${#WEBUI_PASSWORD_HASH_SALT}" -eq 32 ]; then
			WEBUI_PASSWORD_HASH=$(printf '%s' "$WEBUI_DEFAULT_PASSWORD" | webui_hash_password "$WEBUI_PASSWORD_HASH_SALT")
		fi
		if [ -n "$WEBUI_PASSWORD_HASH" ]; then
			WEBUI_PASSWORD_HASH_NEED_SAVE=1
			WEBUI_PASSWORD_DEFAULT=1
		else
			WEBUI_PASSWORD_HASH=""
		fi
		WEBUI_PASSWORD_HASH_DONE=1
	fi

	LOAD_CFG_DONE=1
}

# 按名称从配置取整行（awk 保留 cmd 中的 |；返回整行 $0）
pick_termux() {
	printf '%s\n' "$TERMUX_SERVICES" | awk -F'|' -v n="$1" '$1==n { print; exit }'
}

pick_binary() {
	printf '%s\n' "$BINARY_SERVICES" | awk -F'|' -v n="$1" '$1==n { print; exit }'
}

# 从配置行列表提取 name 列（每行一个，跳过空行）
list_names() {
	awk -F'|' '$1 != "" { print $1 }'
}

# ---------- 外部访问配置（config/web.conf） ----------
# 默认值。
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
