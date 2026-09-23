#!/system/bin/sh
# SvcHub 公共库：配置读写（config/setting.conf 设置项 + config/services.conf 服务项）、进程 pid 管理、日志轮转与校验、Wi-Fi 策略控制。
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
# 新配置目录（三文件）；CONFIG_FILE 仅作旧版迁移源保留。
CONFIG_DIR="$MODDIR/config"
SETTING_FILE="$CONFIG_DIR/setting.conf"
SERVICES_FILE="$CONFIG_DIR/services.conf"
WEB_CONF_NEW="$CONFIG_DIR/web.conf"
WEB_CONF_OLD="$MODDIR/web.conf"

# 设备上为空走默认路径，零影响
[ -n "$SVCHUB_TERMUX_HOME" ] && TERMUX_HOME="$SVCHUB_TERMUX_HOME" || TERMUX_HOME="/data/data/com.termux/files/home"

# Termux 应用运行 uid
termux_uid() {
	if [ -z "$TERMUX_UID" ]; then
		TERMUX_UID=$(stat -c '%u' "$TERMUX_HOME" 2>/dev/null || stat -c '%u' /data/data/com.termux 2>/dev/null)
		[ -z "$TERMUX_UID" ] && TERMUX_UID=10000
	fi
	printf '%s\n' "$TERMUX_UID"
}

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

mkdir -p "$RUNDIR" "$LOG_DIR" "$RUNDIR/session"

# ---------- 配置（config/setting.conf 设置项 + config/services.conf 服务项） ----------
# 配置 schema 唯一定义：新增设置键在此登记，并同步补全 load_settings / cfg_global / write_settings 各一行；
# 新增服务类型只需在 load_services / write_services 加一个 type 分支。
CONFIG_KEYS='sleep_interval server_dir termux_services services boot_commands wifi_service_enabled wifi_service_names wifi_service_names_off wifi_ssids schedule_enabled schedule_stop schedule_start webui_enabled webui_password_hash webui_token'
# 设置文件键（13 键：CONFIG_KEYS 去掉两类服务行）。
SETTING_KEYS='sleep_interval server_dir boot_commands wifi_service_enabled wifi_service_names wifi_service_names_off wifi_ssids schedule_enabled schedule_stop schedule_start webui_enabled webui_password_hash webui_token'

# JSON 字符串编码：\ " tab 转义、换行转字面 \n；逐字符拼接（gsub 替换串反斜杠 busybox/gawk 语义不一致，禁用）
enc_js() {
	awk 'function esc(s,   o, i, n, c) { o = ""; n = length(s); for (i = 1; i <= n; i++) { c = substr(s, i, 1); if (c == "\\") o = o "\\\\"; else if (c == "\"") o = o "\\\""; else if (c == "\t") o = o "\\t"; else o = o c } return o } { if (NR > 1) printf "\\n"; printf "%s", esc($0) }'
}

# JSON 字符串解码：左到右单遍，\n \t \" \\ 还原明文，孤立 \ 原样保留
dec_js() {
	awk 'function unesc(s,   o, i, n, c) { o = ""; n = length(s); for (i = 1; i <= n; i++) { c = substr(s, i, 1); if (c != "\\") { o = o c; continue } i++; c = substr(s, i, 1); if (c == "n") o = o "\n"; else if (c == "t") o = o "\t"; else if (c == "\"") o = o "\""; else if (c == "\\") o = o "\\"; else o = o "\\" c } return o } { printf "%s", unesc($0) }'
}

# 读取某个 key 的值（明文）；不存在/空则输出空。
cfg_get() {
	local key=$1 val
	[ -f "$CONFIG_FILE" ] || return 0
	val=$(sed -n "s/^[[:space:]]*\"${key}\":[[:space:]]*\"\(.*\)\"[,]*$/\1/p" "$CONFIG_FILE")
	[ -n "$val" ] || return 0
	case "$val" in
	*\\*) printf '%s' "$val" | dec_js ;;
	*) printf '%s' "$val" ;;
	esac
}

# 单遍导出 config.json（一次 awk，替代多键多次 cfg_get fork；输出 key<US>原始值 行）。
# 行尾右引号+可选逗号锚定取值（值内引号已转义，不会误伤）；US 分隔安全。
cfg_dump_all() {
	[ -f "$CONFIG_FILE" ] || return 0
	awk -v sep="$(printf '\037')" '
	/^[[:space:]]*"[^"]*"[[:space:]]*:/ {
		line = $0
		sub(/^[[:space:]]*"/, "", line)
		key = substr(line, 1, index(line, "\"") - 1)
		sub(/^[^"]*"[[:space:]]*:[[:space:]]*"/, "", line)
		sub(/"[[:space:]]*,?[[:space:]]*$/, "", line)
		printf "%s%s%s\n", key, sep, line
	}' "$CONFIG_FILE"
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
		printf 'webui_enabled=%s\n'           "$(printf '%s' "$WEBUI_ENABLED" | enc_js)"
		printf 'webui_password_hash=%s\n'     "$(printf '%s' "$WEBUI_PASSWORD_HASH" | enc_js)"
		printf 'webui_token=%s\n'             "$(printf '%s' "$WEBUI_TOKEN" | enc_js)"
	} > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$SETTING_FILE"
	LOAD_CFG_DONE=""
}

# 服务项写成 services.conf（统一 6 段 type|name|port|extra|auto|cmd，先全部 termux 再 # binary + 全部 binary；原子替换）。
# 无参：直接从 load_cfg_sh 的 TERMUX_SERVICES（5 段 name|port|extra|auto|cmd）/ BINARY_SERVICES（6 段 name|port|extra|auto|cmd，extra 为空）读取。
write_services() {
	local tmp="$SERVICES_FILE.tmp" line _bn _bp _ba _bc
	mkdir -p "$CONFIG_DIR" 2>/dev/null
	{
		printf '%s\n' "$TERMUX_SERVICES" | while IFS= read -r line || [ -n "$line" ]; do
			[ -n "$line" ] || continue
			printf 'termux|%s\n' "$line"
		done
		echo '# binary'
		printf '%s\n' "$BINARY_SERVICES" | while IFS= read -r line || [ -n "$line" ]; do
			[ -n "$line" ] || continue
			case "$line" in
			*\|*\|*\|*\|*)
				# 内存 6 段 name|port|extra|auto|cmd 原样加前缀（extra 为空即 ||）。
				printf 'binary|%s\n' "$line" ;;
			*\|*\|*\|*)
				# 旧 4 段 name|port|auto|cmd → 补空 extra（heredoc 切段，避开裸竖线 ${} 模式）。
				IFS='|' read -r _bn _bp _ba _bc <<SVCEOF
$line
SVCEOF
				printf 'binary|%s|%s||%s|%s\n' "$_bn" "$_bp" "$_ba" "$_bc" ;;
			*)
				printf 'binary|%s\n' "$line" ;;
			esac
		done
	} > "$tmp" && mv -f "$tmp" "$SERVICES_FILE"
	LOAD_CFG_DONE=""
}


# 输出 load_cfg_sh 全局变量中 key 对应的值；供 api_get_config 与保存后回读校验共用
cfg_global() {
	case "$1" in
		sleep_interval)         printf '%s' "$SLEEP_INTERVAL" ;;
		server_dir)             printf '%s' "$SERVER_DIR" ;;
		termux_services)        printf '%s' "$TERMUX_SERVICES" ;;
		services)               printf '%s' "$BINARY_SERVICES" ;;
		boot_commands)          printf '%s' "$BOOT_COMMANDS" ;;
		wifi_service_enabled)   printf '%s' "$WIFI_SERVICE_ENABLED" ;;
		wifi_service_names)     printf '%s' "$WIFI_SERVICE_NAMES" ;;
		wifi_service_names_off) printf '%s' "$WIFI_SERVICE_NAMES_OFF" ;;
		wifi_ssids)             printf '%s' "$WIFI_SSIDS" ;;
		schedule_enabled)       printf '%s' "$SCHEDULE_ENABLED" ;;
		schedule_stop)          printf '%s' "$SCHEDULE_STOP" ;;
		schedule_start)         printf '%s' "$SCHEDULE_START" ;;
		webui_enabled)          printf '%s' "$WEBUI_ENABLED" ;;
		webui_password_hash)    printf '%s' "$WEBUI_PASSWORD_HASH" ;;
		webui_token)            printf '%s' "$WEBUI_TOKEN" ;;
	esac
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
		while IFS= read -r line; do
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

# 成员判断：$1=词是否存在于空格分隔的集合 $2 中（供 CONFIG_KEYS 白名单等）
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

# 按服务类型启动：$1=kind(termux|binary) $2=名称 $3=extra $4=命令文本。
# 统一启动收口（巡检/Wi-Fi/WebUI）：binary extra 忽略；cmd 库存字面 \n，执行前还原为真换行。
launch_svc() {
	local cmdtext=$4
	case "$cmdtext" in *\\*) cmdtext=$(printf '%s' "$cmdtext" | dec_js) ;; esac
	case "$1" in
		termux) start_svc "$2" "$TERMUX_HOME" "$3" "$TERMUX_ENV $cmdtext" ;;
		binary) start_svc "$2" "$SERVER_DIR" "" "$cmdtext" ;;
	esac
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

# 停止全部已配置服务（读已加载全局变量；未加载则先 load_services）
stop_all() {
	[ -n "$LOAD_CFG_DONE" ] || load_services
	printf '%s\n' "$TERMUX_SERVICES" | while IFS='|' read -r name port extra auto cmd; do
		[ -n "$name" ] && stop_svc "$name"
	done
	printf '%s\n' "$BINARY_SERVICES" | while IFS='|' read -r name port extra auto cmd; do
		[ -n "$name" ] && stop_svc "$name"
	done
}

# ---------- 配置加载 ----------
# 缺键补键（幂等：无缺键原样重写，cmp 一致跳过；单次 awk 探测缺键）。
# 仅供旧 config.json 迁移前兜底；新 setting.conf 缺键由 load_settings 默认值覆盖。
ensure_config_keys() {
	local tmp
	[ -f "$CONFIG_FILE" ] || return 0
	tmp="$CONFIG_FILE.tmp"
	awk -v keys="$*" '
		BEGIN { n = split(keys, kl, " ") }
		{
			for (i = 1; i <= n; i++)
				if ($0 ~ "\"" kl[i] "\"[[:space:]]*:") have[i] = 1
			if ($0 ~ "\"sleep_interval\"[[:space:]]*:") base1 = 1
			if ($0 ~ "\"server_dir\"[[:space:]]*:") base2 = 1
			if ($0 ~ "\"termux_services\"[[:space:]]*:") base3 = 1
			if ($0 ~ "\"services\"[[:space:]]*:") base4 = 1
			if ($0 ~ "\"boot_commands\"[[:space:]]*:") base5 = 1
			lines[NR] = $0
		}
		END {
			m = 0
			for (i = 1; i <= n; i++) {
				if (!have[i]) {
					v = (kl[i] ~ /_enabled$/) ? "0" : ""
					def[m++] = "  \"" kl[i] "\": \"" v "\""
				}
			}
			if (m == 0 || !(base1 && base2 && base3 && base4 && base5)) {
				for (i = 1; i <= NR; i++) print lines[i]
				exit 0
			}
			for (i = 1; i <= NR; i++) {
				if (lines[i] ~ /^[[:space:]]*}[[:space:]]*$/) {
					if (lines[i-1] !~ /,[[:space:]]*$/) lines[i-1] = lines[i-1] ","
					for (j = 0; j < m - 1; j++) print def[j] ","
					print def[m - 1]
				}
				print lines[i]
			}
		}
	' "$CONFIG_FILE" > "$tmp" || return 0
	[ -s "$tmp" ] || { rm -f "$tmp"; return 0; }
	cmp -s "$CONFIG_FILE" "$tmp" && { rm -f "$tmp"; return 0; }
	mv -f "$tmp" "$CONFIG_FILE"
	return 0
}

# 读 setting.conf 到设置类全局变量（不碰服务行；# 注释与空行忽略，值经 dec_js 还原）。
load_settings() {
	local f="$SETTING_FILE" line k v CR
	CR=$(printf '\r')
	SLEEP_INTERVAL=""; SERVER_DIR=""; BOOT_COMMANDS=""
	WIFI_SERVICE_ENABLED=""; WIFI_SERVICE_NAMES=""; WIFI_SERVICE_NAMES_OFF=""; WIFI_SSIDS=""
	SCHEDULE_ENABLED=""; SCHEDULE_STOP=""; SCHEDULE_START=""
	WEBUI_ENABLED=""; WEBUI_PASSWORD_HASH=""; WEBUI_TOKEN=""
	[ -f "$f" ] || return 0
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in *"$CR") line=${line%"$CR"} ;; esac
		case "$line" in ''|'#'*) continue ;; esac
		k=${line%%=*}
		case "$k" in
		sleep_interval|server_dir|boot_commands|wifi_service_enabled|wifi_service_names|wifi_service_names_off|wifi_ssids|schedule_enabled|schedule_stop|schedule_start|webui_enabled|webui_password_hash|webui_token) ;;
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
		webui_enabled) WEBUI_ENABLED=$v ;;
		webui_password_hash) WEBUI_PASSWORD_HASH=$v ;;
		webui_token) WEBUI_TOKEN=$v ;;
		esac
	done < "$f"
}

# 单键读 setting.conf（明文；新文件缺失回退旧 cfg_get，仅供迁移前兜底）。
setting_get() {
	local key=$1 f="$SETTING_FILE" line k v CR
	CR=$(printf '\r')
	if [ ! -f "$f" ]; then cfg_get "$key"; return 0; fi
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

# 校验后的行追加到对应内存变量；binary 旧 4 段经 heredoc 切段补空 extra 升 6 段（避开裸竖线 ${} 模式）
append_row() {
	local rest=$2 _bn _bp _ba _bc
	case "$1" in
	termux)
		if [ -n "$TERMUX_SERVICES" ]; then TERMUX_SERVICES="$TERMUX_SERVICES
$rest"; else TERMUX_SERVICES=$rest; fi
		;;
	binary)
		case "$rest" in
		*\|*\|*\|*\|*) : ;;
		*\|*\|*\|*)
			IFS='|' read -r _bn _bp _ba _bc <<SVCEOF
$rest
SVCEOF
			rest="$_bn|$_bp||$_ba|$_bc"
			;;
		*)
			sup_log "services.conf 非法行(binary段数不足)：$rest"; return 1 ;;
		esac
		if [ -n "$BINARY_SERVICES" ]; then BINARY_SERVICES="$BINARY_SERVICES
$rest"; else BINARY_SERVICES=$rest; fi
		;;
	esac
}

# 读 services.conf 到 TERMUX_SERVICES / BINARY_SERVICES（去首段 type，还原旧 5 段/4 段行；非法行跳过记日志）。
load_services() {
	local f="$SERVICES_FILE" line type rest name _r1 CR BOM TAB
	CR=$(printf '\r')
	BOM=$(printf '\357\273\277')
	TAB=$(printf '\t')
	TERMUX_SERVICES=""; BINARY_SERVICES=""
	[ -f "$f" ] || return 0
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
		*) sup_log "services.conf 非法行(无|分隔)：$line"; continue ;;
		esac
		# heredoc read 切段（末变量保留原始分隔符）：裸竖线 ${var%%|*} 模式在设备 shell 返回空，会全量判非法
		IFS='|' read -r type rest <<SVCEOF
$line
SVCEOF
		IFS='|' read -r name _r1 <<SVCEOF
$rest
SVCEOF
		valid_name "$name" || { sup_log "services.conf 非法行(名称[$name]字节=$(printf '%s' "$name" | od -An -tx1 2>/dev/null | tr -d ' \n'))：$line"; continue; }
		case "$type" in
		termux|binary) append_row "$type" "$rest" || continue ;;
		*) sup_log "services.conf 非法行(类型[$type])非termux/binary：$line" ;;
		esac
	done < "$f"
	# 自愈：services.conf 为空但 .bak 还有数据（迁移写空/页面空存误覆），恢复一次。
	[ -z "$TERMUX_SERVICES" ] && [ -z "$BINARY_SERVICES" ] && restore_services_from_bak
}

# services.conf 空但 config.json.bak 还有服务行时恢复（用户主动清空后 .bak 已删，不会误恢复）。
restore_services_from_bak() {
	local bak="$CONFIG_FILE.bak" raw t_raw
	[ -f "$bak" ] || return 1
	raw=$(sed -n 's/^[[:space:]]*"services":[[:space:]]*"\(.*\)"[,]*$/\1/p' "$bak" 2>/dev/null | head -n 1)
	[ -n "$raw" ] || return 1
	case "$raw" in *\\*) raw=$(printf '%s' "$raw" | dec_js) ;; esac
	t_raw=$(sed -n 's/^[[:space:]]*"termux_services":[[:space:]]*"\(.*\)"[,]*$/\1/p' "$bak" 2>/dev/null | head -n 1)
	case "$t_raw" in *\\*) t_raw=$(printf '%s' "$t_raw" | dec_js) ;; esac
	[ -n "$raw" ] || [ -n "$t_raw" ] || return 1
	BINARY_SERVICES=$raw
	TERMUX_SERVICES=$t_raw
	write_services 2>/dev/null || return 1
	sup_log "services.conf 为空，已从 config.json.bak 恢复服务"
	load_services
}

# 旧 config.json 一次性迁移到 config/ 三文件（两新文件都不存在且旧文件存在时才跑；成功后旧文件改名 .bak）。
migrate_config_json_once() {
	local us tmp line k v t_row b_row old_web
	[ -f "$SETTING_FILE" ] || [ -f "$SERVICES_FILE" ] && return 0
	[ -f "$CONFIG_FILE" ] || return 0
	SLEEP_INTERVAL=""; SERVER_DIR=""; TERMUX_SERVICES=""; BINARY_SERVICES=""; BOOT_COMMANDS=""
	WIFI_SERVICE_ENABLED=""; WIFI_SERVICE_NAMES=""; WIFI_SERVICE_NAMES_OFF=""; WIFI_SSIDS=""
	SCHEDULE_ENABLED=""; SCHEDULE_STOP=""; SCHEDULE_START=""
	WEBUI_ENABLED=""; WEBUI_PASSWORD_HASH=""; WEBUI_TOKEN=""
	us=$(printf '\037')
	tmp="$RUNDIR/.cfgdump.$$.tmp"
	cfg_dump_all > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
	t_row=""; b_row=""
	while IFS= read -r line || [ -n "$line" ]; do
		k=${line%%"$us"*}
		[ "$k" = "$line" ] && continue
		v=${line#*"$us"}
		case "$v" in *\\*) v=$(printf '%s' "$v" | dec_js) ;; esac
		case "$k" in
		sleep_interval) SLEEP_INTERVAL=$v ;;
		server_dir) SERVER_DIR=$v ;;
		termux_services) t_row=$v ;;
		services) b_row=$v ;;
		boot_commands) BOOT_COMMANDS=$v ;;
		wifi_service_enabled) WIFI_SERVICE_ENABLED=$v ;;
		wifi_service_names) WIFI_SERVICE_NAMES=$v ;;
		wifi_service_names_off) WIFI_SERVICE_NAMES_OFF=$v ;;
		wifi_ssids) WIFI_SSIDS=$v ;;
		schedule_enabled) SCHEDULE_ENABLED=$v ;;
		schedule_stop) SCHEDULE_STOP=$v ;;
		schedule_start) SCHEDULE_START=$v ;;
		webui_enabled) WEBUI_ENABLED=$v ;;
		webui_password_hash) WEBUI_PASSWORD_HASH=$v ;;
		webui_token) WEBUI_TOKEN=$v ;;
		esac
	done < "$tmp"
	rm -f "$tmp"
	TERMUX_SERVICES=$t_row
	BINARY_SERVICES=$b_row
	write_settings 2>/dev/null || return 1
	write_services 2>/dev/null || return 1
	old_web="$WEB_CONF_OLD"
	[ -f "$WEB_CONF_NEW" ] || { [ -f "$old_web" ] && cp -f "$old_web" "$WEB_CONF_NEW" 2>/dev/null; }
	mv -f "$CONFIG_FILE" "$CONFIG_FILE.bak" 2>/dev/null
	sup_log "已从 config.json 迁移到 config/ 三文件"
}

	load_cfg_sh() {
	# 同进程重复 load 免重复读文件（写操作清标记）。
	[ -n "$LOAD_CFG_DONE" ] && return 0
	# 新文件优先；旧 json 存在则先一次性迁移。
	migrate_config_json_once 2>/dev/null
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
		local prev_state cur_state
		case "${WIFI_POLICY_PREV:-}" in allow) prev_state=已连接 ;; block) prev_state=已断开 ;; *) prev_state=功能关闭 ;; esac
		case "$new_policy" in allow) cur_state=已连接 ;; block) cur_state=已断开 ;; *) cur_state=功能关闭 ;; esac
		wifi_log "WiFi 状态变化：$prev_state -> $cur_state（$(wifi_log_connected_text)，$(wifi_log_match_text)）"
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
				launch_svc termux "$name" "$extra" "$cmd"
			done
		fi
		if [ -n "$b_start" ]; then
			wifi_log "WiFi 条件满足（$(wifi_log_match_text)），启动${group}二进制服务$b_start"
			for name in $b_start; do
				row=$(pick_binary "$name")
				IFS='|' read -r _ port extra auto cmd <<EOF
$row
EOF
				launch_svc binary "$name" "$extra" "$cmd"
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

# 外部访问：监听与安全策略来自 web.conf，缺文件/非法值回默认。
# web.conf 默认值。
WEBUI_LISTEN_DEF=127.0.0.1
WEBUI_PORT_DEF=5555
SESS_TTL_DEF=3600
TOKEN_DAYS_DEF=30
FAIL_MAX_DEF=5
FAIL_LOCK_DEF=300

# 读 web.conf（新 config/web.conf 优先、旧根 web.conf 回退；单次 awk 白名单提取，非法回默认）。
load_web_conf() {
	local f="$WEB_CONF_NEW" out
	[ -f "$f" ] || f="$WEB_CONF_OLD"
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
	[ -f "$f" ] || f="$CONFIG_FILE"
	e=$(sed -n 's/^[[:space:]]*webui_enabled=\(.*\)/\1/p' "$f" 2>/dev/null | head -n 1)
	h=$(sed -n 's/^[[:space:]]*webui_password_hash=\(.*\)/\1/p' "$f" 2>/dev/null | head -n 1)
	# 旧 config.json 回退（迁移前）：沿用原 JSON 取值。
	if [ "$f" = "$CONFIG_FILE" ]; then
		e=$(sed -n 's/^[[:space:]]*"webui_enabled":[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_FILE" 2>/dev/null | head -n 1)
		h=$(sed -n 's/^[[:space:]]*"webui_password_hash":[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_FILE" 2>/dev/null | head -n 1)
	fi
	[ -z "$e" ] && e=1
	[ "$e" = 0 ] || e=1
	[ -n "$h" ] && h=1 || h=0
	printf '%s %s\n' "$e" "$h"
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