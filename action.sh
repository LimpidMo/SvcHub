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

# stdin 读一行 key=BASE64 并解码：成功设 KV_KEY/KV_VAL 返回 0，EOF 返回 1，空行 KV_KEY 置空；
# webui_* 键走专用子命令，编码/解码/超限错误直接输出 JSON 并 exit 1。
read_kv_b64() {
	local line key b64
	IFS= read -r line || [ -n "$line" ] || return 1
	if [ -z "$line" ]; then KV_KEY=""; return 0; fi
	key=${line%%=*}
	b64=${line#*=}
	case "$key" in
	webui_*) json_fail '外部访问配置请用专用接口修改'; exit 1 ;;
	esac
	case "$b64" in
	*[!A-Za-z0-9+/=]*) json_fail '配置编码错误'; exit 1 ;;
	esac
	KV_VAL=$(printf '%s' "$b64" | base64 -d 2>/dev/null) || { json_fail '配置解码失败'; exit 1; }
	[ "${#KV_VAL}" -le "$CONFIG_VALUE_MAX" ] || { json_fail '配置内容过大'; exit 1; }
	KV_KEY=$key
	return 0
}

# 名单校验（每行一个服务名）：输出首个非法名（空=全部合法）。
validate_name_list() {
	printf '%s\n' "$1" | awk '{ gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if ($0 != "" && $0 !~ /^[A-Za-z0-9._-]+$/) { print $0; exit } }'
}

# 服务行校验：合法输出空，非法输出首个非法行号（saveservices 指明行号共用）。
# 单次 awk 完成全部校验；end_cmd 恒末段可含 |（从第 5 段重拼），故 cmd 禁 | 只约束第 4 段。
validate_rows() {
	awk '
	function valid_name(s) { return s ~ /^[A-Za-z0-9._-]+$/ }
	BEGIN { FS = "|" }
	{
		if ($0 == "") next
		r++
		if (r > 500) { printf "%s", r; exit }
		name = $1; port = $2; auto = $3; cmd = $4
		endcmd = $5
		for (i = 6; i <= NF; i++) endcmd = endcmd "|" $i
		if (!valid_name(name)) { printf "%s", r; exit }
		if (cmd == "") { printf "%s", r; exit }
		if (auto != "start" && auto != "stop") { printf "%s", r; exit }
		if (index(port, "|") > 0) { printf "%s", r; exit }
		if (length(port) > 32) { printf "%s", r; exit }
		if (index(cmd, "|") > 0) { printf "%s", r; exit }
		if (length(cmd) > 8192) { printf "%s", r; exit }
		if (length(endcmd) > 4096) { printf "%s", r; exit }
	}
	'
}

clear_log() {
	local name=$1
	valid_name "$name" || return 1
	: > "$LOG_DIR/$name.log"
}

# 行列表 -> JSON 对象数组：单个 awk 完成转义与状态注入，避免逐字段 fork。
# $1=运行名单（经 ENVIRON 传入），行列表从 stdin 读；两类内存统一 5 段，输出结构相同。
# 传 $2/$3 时顺带输出 boot_id/server_dir 头部（省两次 enc_js fork），按参数个数判断。
rows_to_json() {
	local head=""
	[ $# -ge 2 ] && head=1
	RUNSET=$1 BOOT_ID=$2 SERVER_DIR_V=$3 awk -v head="$head" "$AWK_ESC"'
BEGIN {
	FS = "|"; runset = ENVIRON["RUNSET"]
	if (head == "1")
		printf "{\"boot_id\":\"%s\",\"server_dir\":\"%s\",\"termux_services\":[", esc(ENVIRON["BOOT_ID"]), esc(ENVIRON["SERVER_DIR_V"])
}
$1 != "" {
	st = index("\n" runset "\n", "\n" $1 "\n") > 0 ? "running" : "stopped"
	# end_cmd 是末段，含 | 的收尾命令需从第 5 段起重拼（$5 会截断）
	endcmd = $5
	for (i = 6; i <= NF; i++) endcmd = endcmd "|" $i
	if (n++) printf ","
	printf "{\"name\":\"%s\",\"port\":\"%s\",\"status\":\"%s\",\"auto\":\"%s\",\"cmd\":\"%s\",\"end_cmd\":\"%s\"}", esc($1), esc($2), st, esc($3), esc($4), esc(endcmd)
}
'
}

api_get_status() {
	local runset boot_id
	load_cfg_sh
	# 批量检测全部服务运行状态（单次遍历 pid 文件），避免逐服务 fork
	runset=$(compute_runset)
	boot_id=""
	if [ -r "$BOOTID_FILE" ]; then read -r boot_id < "$BOOTID_FILE" || true; fi
	# boot_id/server_dir 的转义并进首段的 rows_to_json awk，省两次独立 enc_js fork
	rows_to_json "$runset" "$boot_id" "$SERVER_DIR" <<EOF
$TERMUX_SERVICES
EOF
	printf '],"binary_services":['
	rows_to_json "$runset" <<EOF
$BINARY_SERVICES
EOF
	printf ']}\n'
}

# 查服务行：输出 kind|row（termux 优先，与旧逻辑一致）；未配置返回 1。
find_service_row() {
	local name=$1 row
	row=$(pick_termux "$name")
	[ -n "$row" ] && { printf 'termux|%s\n' "$row"; return 0; }
	row=$(pick_binary "$name")
	[ -n "$row" ] && { printf 'binary|%s\n' "$row"; return 0; }
	return 1
}

api_start_service() {
	local type=$1 name=$2 found kind row port auto cmd endcmd
	valid_name "$name" || { json_fail '名称不合法'; exit 0; }
	load_cfg_sh
	case "$type" in termux|auto|binary) ;; *) json_fail '不支持的服务类型'; exit 0 ;; esac
	found=$(find_service_row "$name")
	if [ -z "$found" ]; then
		if [ "$type" = termux ]; then
			json_fail '未在 Termux 服务中找到该名称'
		else
			json_fail '未在二进制服务中找到该名称'
		fi
		exit 0
	fi
	IFS='|' read -r kind row <<EOF
$found
EOF
	IFS='|' read -r _ port auto cmd endcmd <<EOF
$row
EOF
	stop_svc "$name"
	if launch_svc "$kind" "$name" "$cmd"; then
		json_ok
	else
		if [ "$kind" = termux ]; then
			json_fail '启动失败（可能是 Termux 目录不存在或命令错误）'
		else
			json_fail '启动失败（服务目录不存在或命令错误）'
		fi
	fi
	exit 0
}

api_stop_service() {
	local name=$1
	valid_name "$name" || { json_fail '名称不合法'; exit 0; }
	stop_svc "$name"
	json_ok
}

# ---------- 二进制更新 ----------
# 更新条目 JSON：$1=条目行（10 段） $2=has_update（true/false，调用方用 ver_cmp 算）。
update_entry_json() {
	printf '%s' "$1" | awk -v has="$2" "$AWK_ESC"'
	BEGIN { FS = "|" }
	{
		printf "%s{\"name\":\"%s\",\"repo\":\"%s\",\"asset\":\"%s\",\"target\":\"%s\",\"mode\":\"%s\",\"svc\":\"%s\",\"ins_ver\":\"%s\",\"vercmd\":\"%s\",\"update_ver\":\"%s\",\"auto\":\"%s\",\"has_update\":%s}",
			(n++ ? "," : ""), esc($1), esc($2), esc($3), esc($4), esc($5), esc($6), esc($7), esc($8), esc($9), esc($10), has
	}'
}

# 读更新条目列表（getupdates）。
# 条目缺已装版本时顺手实测一次并回写（首次加载即显示版本，无需先点检查）。
api_get_updates() {
	load_cfg_sh
	load_update_conf
	printf '{"success":true,"items":['
	local line first=1 name _repo _asset target _mode _svc ins vercmd update_ver detected has rawf
	rawf="$RUNDIR/.verraw.$$"
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		IFS='|' read -r name _repo _asset target _mode _svc ins vercmd update_ver _auto <<UEOF
$line
UEOF
		# 只在缺已装版本时补测一次（填了参数按参数，留空逐个兜底）：已记录版本直接返回，避免每次加载都执行命令。
		# 目标二进制不存在/不可执行时连实测都跳过（首次安装前每次加载都白探一轮，还可能撞上挂死的二进制），
		# 但条目照常输出（ins_ver 留空）。
		if [ -z "$ins" ] && [ -x "$SERVER_DIR/$target" ]; then
			if detected=$(update_local_version "$vercmd" "$target" "$rawf"); then
				update_log "[$name] $(ui_msg '本地版本：%s' "$detected")"
				update_set_ins_ver "$name" "$detected"
				ins=$detected
				line=$(pick_update_entry "$name")
			else
				update_log "[$name] $(ui_msg '版本命令未取到版本号（输出：%s）' "$(cat "$rawf" 2>/dev/null || echo '<空>')")"
			fi
		fi
		# 已装/最新都有就版本比较（不联网，刷新页面也有「有更新」判定）
		has=false
		if [ -n "$update_ver" ]; then
			if [ -z "$ins" ] || [ "$(ver_cmp "$update_ver" "$ins")" -gt 0 ]; then
				has=true
			fi
		fi
		[ "$first" -eq 0 ] && printf ','
		first=0
		update_entry_json "$line" "$has"
	done <<EOF
$UPDATE_ENTRIES
EOF
	rm -f "$rawf"
	printf ']}\n'
}

# 保存更新条目（saveupdates）：stdin 读 key=BASE64 行，只接受 update_entries。
api_save_updates() {
	local provided= val bad name svc miss=""
	load_cfg_sh
	load_update_conf
	while read_kv_b64; do
		[ -n "$KV_KEY" ] || continue
		case "$KV_KEY" in
		update_entries) ;;
		*) json_fail '未知配置键'; exit 1 ;;
		esac
		provided=1
		val=$KV_VAL
	done
	[ -n "$provided" ] || { json_fail '配置内容为空'; exit 1; }
	bad=$(printf '%s\n' "$val" | validate_update_rows)
	[ -z "$bad" ] || { json_fail '更新配置格式错误（第 %s 行）' "$bad"; exit 1; }
	# 关联服务必须存在于二进制服务列表（软引用失效则拒绝写入）
	printf '%s\n' "$val" | while IFS='|' read -r name _repo _asset _target _mode svc _ins _vc _uv; do
		[ -n "$svc" ] || continue
		printf '%s\n' "$BINARY_SERVICES" | awk -F'|' -v n="$svc" '$1 == n { found = 1; exit } END { exit !found }' || {
			printf '%s' "$svc" > "$RUNDIR/.upd_missing.$$"
			exit 0
		}
	done
	if [ -f "$RUNDIR/.upd_missing.$$" ]; then
		miss=$(cat "$RUNDIR/.upd_missing.$$" 2>/dev/null)
		rm -f "$RUNDIR/.upd_missing.$$"
		json_fail '关联的二进制服务不存在：%s' "$miss"
		exit 1
	fi
	UPDATE_ENTRIES="$val"
	write_update_conf || { json_fail '配置写入失败'; exit 1; }
	json_ok
}

# 检查更新（updatecheck）：后台拉起 updater.sh check 立即返回。
# 探测要逐条目联网（单条 curl 最长 300s），同步执行会把 manager 通道的同步 XHR 卡死——
# 前端只负责拉起与轮询 updatestatus，结果由 check 写回 update.conf（update_ver/ins_ver），
# 完成后前端 getupdates 即可拿到 has_update（不联网）。
api_update_check() {
	load_cfg_sh
	load_update_conf
	[ -n "$UPDATE_ENTRIES" ] || { json_fail '没有配置任何更新条目'; exit 0; }
	if pidfile_alive "$UPDATE_PID" >/dev/null; then
		json_fail '已有更新任务在运行，请稍后再试'
		exit 0
	fi
	setsid sh "$MODDIR/updater.sh" check </dev/null >>"$UPDATE_LOG" 2>&1 &
	json_ok
}

# 更新任务状态（updatestatus）：前端据此把「更新」按钮切「暂停」。
api_update_status() {
	load_cfg_sh
	if pidfile_alive "$UPDATE_PID" >/dev/null; then
		printf '{"success":true,"running":true}\n'
	else
		printf '{"success":true,"running":false}\n'
	fi
}

# 停止更新任务（updatestop）：按 pid 文件杀整个进程组（下载/解包一并终止）。
api_update_stop() {
	load_cfg_sh
	if ! pidfile_alive "$UPDATE_PID" >/dev/null; then
		json_fail '没有正在运行的更新任务'
		exit 0
	fi
	kill_by_name update
	rm -f "$UPDATE_PID"
	update_log "$(ui_msg '更新已手动停止')"
	json_ok
}

# 拉起后台更新任务：$1=模式（one|all） $2=条目名。
api_update_start() {
	local mode=$1 name=$2
	load_cfg_sh
	case "$mode" in
	one)
		valid_name "$name" || { json_fail '名称不合法'; exit 0; }
		load_update_conf
		[ -n "$(pick_update_entry "$name")" ] || { json_fail '未找到更新条目：%s' "$name"; exit 0; }
		;;
	all) ;;
	*) json_fail '不支持的操作'; exit 0 ;;
	esac
	# 已有任务在跑则拒绝（避免并发改同一个文件）
	if pidfile_alive "$UPDATE_PID" >/dev/null; then
		json_fail '已有更新任务在运行，请稍后再试'
		exit 0
	fi
	# 后台执行：下载耗时，不能同步等（manager 通道是同步 XHR）
	if [ "$mode" = one ]; then
		setsid sh "$MODDIR/updater.sh" update "$name" </dev/null >>"$UPDATE_LOG" 2>&1 &
	else
		setsid sh "$MODDIR/updater.sh" updateall </dev/null >>"$UPDATE_LOG" 2>&1 &
	fi
	json_ok
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
	# $1=日志名 $2=行数（默认 LOG_TAIL_DEFAULT，上限 LOG_TAIL_MAX；0=全文）。
	local name=$1 lines=${2:-$LOG_TAIL_DEFAULT} f
	valid_name "$name" || { printf '{"content":"","error":"%s"}\n' "$(printf '%s' "$(ui_msg '名称不合法')" | json_esc)"; exit 0; }
	is_int "$lines" || lines=500
	[ "$lines" -gt "$LOG_TAIL_MAX" ] && lines=$LOG_TAIL_MAX
	f="$LOG_DIR/$name.log"
	[ -f "$f" ] || { printf '{"content":"","error":"%s"}\n' "$(printf '%s' "$(ui_msg '日志文件不存在')" | json_esc)"; exit 0; }
	{
		printf '{"content":"'
		if [ "$lines" = 0 ]; then cat "$f"; else tail -n "$lines" "$f"; fi | base64 | tr -d '
'
		printf '"}\n'
	}
}

# 设置页按需读：SETTING_PUBLIC_KEYS（SETTING_KEYS 去掉哈希与 Token）。
# 记录流交给单次 awk 输出 JSON，值含换行/引号也能按原样还原。
api_get_settings() {
	load_cfg_sh
	settings_sep "$SETTING_PUBLIC_KEYS" || { json_fail '配置编码错误'; exit 1; }
	settings_stream "$SETTING_PUBLIC_KEYS" "$SV_SEP" | awk -v sep="$SV_SEP" "$AWK_ESC"'function emit(k, v) { printf "%s\"%s\":\"%s\"", (n++ ? "," : ""), k, esc(v) }
BEGIN { printf "{" }'"$AWK_KV_STREAM"' END { printf "}\n" }'
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


# 测试运行命令：stdin 读 shell 文本逐行执行记日志（$1=termux 时注入 Termux 环境）。
# 高危命令（删根/格式化/写块设备/fork 炸弹）整单拒绝，防手滑。
api_run_cmd() {
	local mode=$1 runner=su env_prefix= body hit err
	load_cfg_sh
	body=$(cat)
	if [ "$mode" = termux ]; then
		runner="su $(termux_user_args)"
		env_prefix="$TERMUX_ENV cd $TERMUX_HOME;"
	fi
	hit=$(dangerous_line "$body")
	if [ -n "$hit" ]; then
		webui_log "$(ui_msg '高危命令已拦截：%s' "$hit")"
		err=$(printf '%s' "$hit" | cut -c1-60)
		json_fail '包含高危命令，已拒绝执行：%s' "$err"
		exit 0
	fi
	printf '%s\n' "$body" | run_lines "$LOG_DIR/run_test.log" "$([ "$mode" = termux ] && echo "$(ui_msg '(Termux 测试运行)')" || echo "$(ui_msg '(测试运行)')")" "$runner" "$env_prefix"
	json_ok
}

# 手动执行开机命令（复用开机同一 runner 记账；存量命令同样过高危拦截）。
api_exec_boot() {
	load_cfg_sh
	local hit err
	hit=$(dangerous_line "$BOOT_COMMANDS")
	if [ -n "$hit" ]; then
		webui_log "$(ui_msg '高危命令已拦截（开机命令）：%s' "$hit")"
		err=$(printf '%s' "$hit" | cut -c1-60)
		json_fail '开机命令包含高危命令，已拒绝执行：%s' "$err"
		exit 0
	fi
	printf '%s\n' "$BOOT_COMMANDS" | run_lines "$LOG_DIR/boot_commands.log" "$(ui_msg '开机命令(手动)')"
	json_ok
}

# 外部访问：开关启停 httpd，密码/Token 走专用子命令。
api_webui_enable() {
	load_cfg_sh
	if [ -f "$DISABLE_FILE" ]; then
		json_fail '模块已禁用，无法开启外部访问'
		exit 1
	fi
	# 默认哈希落盘（内存值首次调用时写回）
	if [ "$WEBUI_PASSWORD_HASH_NEED_SAVE" = "1" ]; then
		write_settings 2>/dev/null
		load_cfg_sh
	fi
	if [ -z "$WEBUI_PASSWORD_HASH" ]; then
		json_fail '请先设置密码'
		exit 1
	fi
	# 仍是默认密码时禁止开启外部访问（Magisk 默认开启的实例靠外部登录强制改密）
	if [ "$WEBUI_PASSWORD_DEFAULT" = "1" ]; then
		json_fail '请先修改默认密码'
		exit 1
	fi
	WEBUI_ENABLED=1
	write_settings || { json_fail '配置写入失败'; exit 1; }
	sh "$MODDIR/httpd.sh" start
	rc=$?
	if [ "$rc" -eq 0 ]; then
		webui_log "$(ui_msg '外部访问已开启')"
		json_ok
	else
		case "$rc" in
		2) json_fail '未找到可用 busybox（含 httpd）' ;;
		3) json_fail '端口 %s 被占用' "$WEBUI_PORT" ;;
		5) json_fail 'api.cgi 无可执行权限，请重装模块' ;;
		*) json_fail 'httpd 启动失败，请查看 webui 日志' ;;
		esac
		exit 1
	fi
}

api_webui_disable() {
	load_cfg_sh
	WEBUI_ENABLED=0
	write_settings || { json_fail '配置写入失败'; exit 1; }
	if sh "$MODDIR/httpd.sh" stop >/dev/null 2>&1; then
		webui_log "$(ui_msg '外部访问已关闭')"
		json_ok
	else
		json_fail 'httpd 停止失败，进程仍存活，请查看 webui 日志'
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
		case "$key" in password|old) ;; *) json_fail '未知参数'; exit 1 ;; esac
		case "$b64" in
		*[!A-Za-z0-9+/=]*) json_fail '编码错误'; exit 1 ;;
		esac
		if [ "$key" = password ]; then
			password=$(printf '%s' "$b64" | base64 -d 2>/dev/null) || { json_fail '解码失败'; exit 1; }
		else
			old=$(printf '%s' "$b64" | base64 -d 2>/dev/null) || { json_fail '解码失败'; exit 1; }
		fi
	done
	[ "${#password}" -ge 6 ] || { json_fail '密码至少 6 位'; exit 1; }
	[ "${#password}" -le 256 ] || { json_fail '密码过长'; exit 1; }
	# 默认密码禁止回设：改密成功即视为完成首次改密
	[ "$password" = "$WEBUI_DEFAULT_PASSWORD" ] && { json_fail '不能使用默认密码'; exit 1; }
	if [ -n "$WEBUI_PASSWORD_HASH" ]; then
		webui_check_password "$old" "$WEBUI_PASSWORD_HASH" || { json_fail '旧密码错误'; exit 1; }
	fi
	salt=$(webui_gen_token | head -c 32)
	[ "${#salt}" -eq 32 ] || { json_fail '随机数生成失败'; exit 1; }
	WEBUI_PASSWORD_HASH=$(printf '%s' "$password" | webui_hash_password "$salt") || { json_fail '密码哈希失败'; exit 1; }
	[ -n "$WEBUI_TOKEN" ] || WEBUI_TOKEN=$(webui_gen_token) || { json_fail 'Token 生成失败'; exit 1; }
	WEBUI_PASSWORD_DEFAULT=0
	write_settings || { json_fail '配置写入失败'; exit 1; }
	[ "$(setting_file_get webui_password_hash)" = "$WEBUI_PASSWORD_HASH" ] || { json_fail '配置写入校验不一致'; exit 1; }
	# 改密清全部会话，强制重登。
	rm -f "$WEBUI_SESS_DIR"/sess_* 2>/dev/null
	json_ok
}

# 轮换长期 Token（旧 Token 登录态全部失效）。
api_webui_regen_token() {
	load_cfg_sh
	WEBUI_TOKEN=$(webui_gen_token) || { json_fail 'Token 生成失败'; exit 1; }
	[ "${#WEBUI_TOKEN}" -eq 64 ] || { json_fail 'Token 生成失败'; exit 1; }
	write_settings || { json_fail '配置写入失败'; exit 1; }
	[ "$(setting_file_get webui_token)" = "$WEBUI_TOKEN" ] || { json_fail '配置写入校验不一致'; exit 1; }
	# Token 轮换同样清会话。
	rm -f "$WEBUI_SESS_DIR"/tsess_* 2>/dev/null
	printf '{"success":true,"token":"%s"}\n' "$WEBUI_TOKEN"
}

# 查询长期 Token 明文；$1=当前 Token 会话剩余天数（管理器通道无会话，留空）。
api_webui_token_show() {
	load_cfg_sh
	printf '{"success":true,"token":"%s","days":"%s"}\n' "$WEBUI_TOKEN" "${1:-}"
}

# 外部访问状态（轻量读取，不跑全量 load）。
api_webui_status() {
	local running=stopped enabled haspw mustchange mc
	svc_running httpd && running=running
	read -r enabled haspw mustchange <<EOF
$(webui_status_fast)
EOF
	[ "$mustchange" = 1 ] && mc=true || mc=false
	printf '{"success":true,"enabled":"%s","running":"%s","has_password":%s,"must_change_password":%s,"listen":"%s","port":%s}\n' \
		"$enabled" "$running" "$haspw" "$mc" "$WEBUI_LISTEN" "$WEBUI_PORT"
}

# 名单键校验并赋值：$1=key $2=值 $3=错误文案模板（非法直接 exit 1）。
apply_name_list() {
	local invalid err
	invalid=$(validate_name_list "$2")
	if [ -n "$invalid" ]; then
		err=$(printf '%s' "$invalid" | tr -d '\r' | cut -c1-60)
		json_fail "$3" "$err"
		exit 1
	fi
	setting_var_set "$1" "$2"
}

# 单键校验落盘：$1=key $2=解码值（非法直接 exit 1）。
cfg_apply_one() {
	local key=$1 val=$2 ssid_lines
	case "$key" in
	sleep_interval)
		[ -n "$val" ] || val=60
		is_int "$val" || { json_fail '间隔必须为数字'; exit 1; }
		[ "$val" -lt 10 ] && val=10
		[ "$val" -gt 86400 ] && val=86400
		setting_var_set sleep_interval "$val"
		;;
	server_dir|boot_commands)
		setting_var_set "$key" "$val"
		;;
	wifi_service_enabled)
		case "$val" in
		0|1)
			# 开关值实际变化才记日志，全量保存不刷屏
			[ "$WIFI_SERVICE_ENABLED" != "$val" ] && TOGGLE_LOG="$TOGGLE_LOG wifi_service_enabled=$val"
			setting_var_set wifi_service_enabled "$val"
			;;
		*) json_fail 'Wi-Fi 功能开关必须为 0 或 1'; exit 1 ;;
		esac
		;;
	wifi_service_names|wifi_service_names_off)
		apply_name_list "$key" "$val" 'Wi-Fi 服务名不合法: %s'
		;;
	wifi_ssids)
		# SSID 允中文/符号/emoji（| 与真换行由前端剔除），只限长度行数。
		if [ "${#val}" -gt 10000 ]; then
			json_fail 'Wi-Fi SSID 列表过长'
			exit 1
		fi
		ssid_lines=$(printf '%s\n' "$val" | grep -c '^' 2>/dev/null || true)
		if [ "$ssid_lines" -gt 100 ]; then
			json_fail 'Wi-Fi SSID 数量过多(最多100个)'
			exit 1
		fi
		setting_var_set wifi_ssids "$val"
		;;
	schedule_enabled)
		case "$val" in
		0|1)
			[ "$SCHEDULE_ENABLED" != "$val" ] && TOGGLE_LOG="$TOGGLE_LOG schedule_enabled=$val"
			setting_var_set schedule_enabled "$val"
			;;
		*) json_fail '定时功能开关必须为 0 或 1'; exit 1 ;;
		esac
		;;
	schedule_stop|schedule_start)
		if [ -n "$val" ]; then
			case "$val" in
			[0-2][0-9]:[0-5][0-9])
				[ "${val%%:*}" -le 23 ] 2>/dev/null || { json_fail '定时时间格式错误(HH:MM)'; exit 1; }
				;;
			*) json_fail '定时时间格式错误(HH:MM)'; exit 1 ;;
			esac
		fi
		setting_var_set "$key" "$val"
		;;
	screen_service_enabled)
		case "$val" in
		0|1)
			[ "$SCREEN_SERVICE_ENABLED" != "$val" ] && TOGGLE_LOG="$TOGGLE_LOG screen_service_enabled=$val"
			setting_var_set screen_service_enabled "$val"
			;;
		*) json_fail '亮屏启停开关必须为 0 或 1'; exit 1 ;;
		esac
		;;
	screen_service_names)
		apply_name_list "$key" "$val" '锁屏白名单服务名不合法: %s'
		;;
	screen_resume_names)
		apply_name_list "$key" "$val" '亮屏白名单服务名不合法: %s'
		;;
	termux_root_names)
		apply_name_list "$key" "$val" 'root 运行服务名不合法: %s'
		;;
	patrol_enabled)
		case "$val" in
		0|1)
			# 开关值实际变化才记日志，全量保存不刷屏
			[ "$PATROL_ENABLED" != "$val" ] && TOGGLE_LOG="$TOGGLE_LOG patrol_enabled=$val"
			setting_var_set patrol_enabled "$val"
			;;
		*) json_fail '巡检开关必须为 0 或 1'; exit 1 ;;
		esac
		;;
	wake_lock_enabled)
		case "$val" in
		0|1)
			# 内核不支持时拒绝开启：避免开关显示已开但实际无效
			if [ "$val" = "1" ] && ! wake_lock_supported; then
				json_fail '内核不支持唤醒锁或SELinux限制'
				exit 1
			fi
			[ "$WAKE_LOCK_ENABLED" != "$val" ] && TOGGLE_LOG="$TOGGLE_LOG wake_lock_enabled=$val"
			setting_var_set wake_lock_enabled "$val"
			;;
		*) json_fail '唤醒锁开关必须为 0 或 1'; exit 1 ;;
		esac
		;;
	language)
		case "$val" in
		zh|en)
			# 语言真变了才动 description 覆盖（免每次全量保存都 fork ksud）
			[ "$UI_LANG" != "$val" ] && LANG_DESC_CHANGED=1
			setting_var_set language "$val"
			;;
		*) json_fail '语言只支持 zh 或 en'; exit 1 ;;
		esac
		;;
	update_proxy_prefix)
		# 代理前缀：留空=直连；只接受 http(s) 开头；末尾无 / 自动补（拼接时依赖）
		case "$val" in
		'')
			setting_var_set update_proxy_prefix ""
			;;
		http://*|https://*)
			case "$val" in
			*/) setting_var_set update_proxy_prefix "$val" ;;
			*) setting_var_set update_proxy_prefix "$val/" ;;
			esac
			;;
		*) json_fail '代理前缀须以 http:// 或 https:// 开头'; exit 1 ;;
		esac
		;;
	update_check_interval)
		case "$val" in
		0|3600|86400|604800)
			setting_var_set update_check_interval "$val"
			;;
		*) json_fail '检查周期只支持关闭/一小时/一天/一周'; exit 1 ;;
		esac
		;;
	esac
}

# 写后自校验：回读 sleep_interval 一键探活（写盘失败/错位时该键必不一致）。
cfg_verify_written() {
	[ "$(setting_file_get sleep_interval)" = "$SLEEP_INTERVAL" ] || { json_fail '配置写入校验不一致'; exit 1; }
}

# 设置页按需保存：只接受 SETTING_KEYS（webui_* 直接拒），只写 setting.conf。
api_save_settings() {
	local provided= tkey tval tstate
	TOGGLE_LOG=""
	LANG_DESC_CHANGED=""
	load_cfg_sh
	while read_kv_b64; do
		[ -n "$KV_KEY" ] || continue
		word_in_set "$KV_KEY" "$SETTING_KEYS" || { json_fail '未知配置键'; exit 1; }
		cfg_apply_one "$KV_KEY" "$KV_VAL"
		provided="$provided $KV_KEY"
	done
	[ -n "$provided" ] || { json_fail '配置内容为空'; exit 1; }
	if [ "$SCHEDULE_ENABLED" = "1" ] && [ -n "$SCHEDULE_STOP" ] && [ "$SCHEDULE_STOP" = "$SCHEDULE_START" ]; then
		json_fail '停止时间与启动时间不能相同'
		exit 1
	fi
	write_settings || { json_fail '配置写入失败'; exit 1; }
	cfg_verify_written
	# 开关即时生效：写盘成功后立刻持锁/释放
	wake_lock_sync
	# 落盘成功后才记开关日志，避免写失败时日志与实际状态不一致
	for tkey in $TOGGLE_LOG; do
		tval=${tkey#*=}
		tkey=${tkey%%=*}
		[ "$tval" = 1 ] && tstate="$(ui_msg 开启)" || tstate="$(ui_msg 关闭)"
		case "$tkey" in
		patrol_enabled)         sup_log    "$(ui_msg '自动巡检已%s' "$tstate")" ;;
		wifi_service_enabled)   wifi_log   "$(ui_msg 'Wi-Fi 启停服务已%s' "$tstate")" ;;
		schedule_enabled)       sched_log  "$(ui_msg '定时启停服务已%s' "$tstate")" ;;
		screen_service_enabled) screen_log "$(ui_msg '亮屏启停服务已%s' "$tstate")" ;;
		wake_lock_enabled)      sup_log    "$(ui_msg '唤醒锁已%s' "$tstate")" ;;
		esac
	done
	# 语言本次有变：落盘成功后同步管理器 description 覆盖（KernelSU 生效，其他方案零操作）
	[ -n "$LANG_DESC_CHANGED" ] && desc_override_apply
	json_ok
}

# 服务页按需保存：只接受 termux_services|binary_services，只写 services.conf；非法整单拒绝并带行号。
api_save_services() {
	local provided= old_ts old_sv bad
	load_cfg_sh
	old_ts=$TERMUX_SERVICES
	old_sv=$BINARY_SERVICES
	while read_kv_b64; do
		[ -n "$KV_KEY" ] || continue
		case "$KV_KEY" in
		termux_services|binary_services) ;;
		*) json_fail '未知配置键'; exit 1 ;;
		esac
		bad=$(printf '%s\n' "$KV_VAL" | validate_rows)
		[ -z "$bad" ] || { json_fail '服务配置格式错误（第 %s 行）' "$bad"; exit 1; }
		if [ "$KV_KEY" = termux_services ]; then TERMUX_SERVICES=$KV_VAL; else BINARY_SERVICES=$KV_VAL; fi
		provided="$provided $KV_KEY"
	done
	[ -n "$provided" ] || { json_fail '配置内容为空'; exit 1; }
	write_services || { json_fail '配置写入失败'; exit 1; }
	stop_removed_services "$old_ts" "$TERMUX_SERVICES" "$old_sv" "$BINARY_SERVICES"
	json_ok
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
getsettings)
	api_get_settings
	;;
getservices)
	api_get_services
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
getupdates)
	api_get_updates
	;;
saveupdates)
	api_save_updates
	;;
updatecheck)
	api_update_check
	;;
updateone)
	api_update_start one "$2"
	;;
updateall)
	api_update_start all
	;;
updatestatus)
	api_update_status
	;;
updatestop)
	api_update_stop
	;;
clearlog)
	if clear_log "$2"; then json_ok; else json_fail '名称不合法'; fi
	;;
open)
	port=$2
	is_int "$port" || { json_fail '端口不合法'; exit 0; }
	[ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null \
	|| { json_fail '端口超出范围'; exit 0; }
	/system/bin/am start -a android.intent.action.VIEW -d "http://127.0.0.1:$port" >/dev/null 2>&1
	json_ok
	;;
*)
	# Manager Action 入口：输出简短状态摘要
	load_cfg_sh
	runset=$(compute_runset)
	echo "$(ui_msg 'SvcHub 状态摘要')"
	echo "$(ui_msg '保活间隔: %ss | Termux 服务: %s | 二进制服务: %s' "$SLEEP_INTERVAL" "$(count_rows "$TERMUX_SERVICES")" "$(count_rows "$BINARY_SERVICES")")"
	printf '%s\n' "$(ui_msg 'Termux 服务:')"
	printf '%s\n' "$TERMUX_SERVICES" | while IFS='|' read -r name port auto cmd endcmd; do
		[ -n "$name" ] || continue
		name_in_set "$name" "$runset" && st=running || st=stopped
		echo "  $name [$st] auto=$auto"
	done
	printf '%s\n' "$(ui_msg '二进制服务:')"
	printf '%s\n' "$BINARY_SERVICES" | while IFS='|' read -r name port auto cmd endcmd; do
		[ -n "$name" ] || continue
		name_in_set "$name" "$runset" && st=running || st=stopped
		echo "  $name [$st] auto=$auto"
	done
	exit 0
	;;
esac
fi
