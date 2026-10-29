# SvcHub 公共库：路径常量、Termux 环境、su 探测、日志、通用校验与字符串编解码。
# 由 lib.sh 按序 source；不单独执行。

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
# PATH 末段的 $PATH 不带反斜杠：由服务 shell 运行时展开为 su 继承的 PATH（带 \ 会变字面死串）；
# 再并上系统默认 PATH 保底，Termux 目录缺失时（如 PC 联调沙盒）仍能找到 sleep 等基础命令。
TERMUX_PATH_SYS='/system/bin:/system/xbin:/vendor/bin:/data/local/bin:/bin:/usr/bin'
TERMUX_ENV='export LANG=en_US.UTF-8;export LC_ALL=en_US.UTF-8; export PREFIX=/data/data/com.termux/files/usr; export PATH=$PREFIX/bin:$PREFIX/bin/applets:$PATH:'"$TERMUX_PATH_SYS"'; export TMPDIR=$PREFIX/tmp; export LD_LIBRARY_PATH=$PREFIX/lib;export LD_PRELOAD=$PREFIX/lib/libtermux-exec.so;'
# 联调沙盒：Termux 目录与 libtermux-exec.so 均不存在，去掉真机专用变量免每条 fork 报错
if [ "$SVCHUB_MOCK" = "1" ]; then
	TERMUX_ENV='export LANG=en_US.UTF-8;export LC_ALL=en_US.UTF-8; export PREFIX=/data/data/com.termux/files/usr; export PATH=$PREFIX/bin:$PREFIX/bin/applets:$PATH:'"$TERMUX_PATH_SYS"';'
fi

# termux 服务的 su 附加参数（uid/主组/inet 组首次使用时才探测，免每次 source 白付 fork）
termux_user_args() {
	if [ -z "$TERMUX_ENV_PROBED" ]; then
		TERMUX_ENV_PROBED=1
		TERMUX_UID=$(stat -c '%u' "$TERMUX_HOME" 2>/dev/null)
		TERMUX_GID=$(stat -c '%g' "$TERMUX_HOME" 2>/dev/null)
		DNS_GID=$(stat -c '%g' /dev/socket/dnsproxyd 2>/dev/null)
	fi
	[ -n "$TERMUX_UID" ] || TERMUX_UID=0
	[ -n "$TERMUX_GID" ] || TERMUX_GID=$TERMUX_UID
	[ -n "$DNS_GID" ] || DNS_GID=3003
	printf '%s\n' "-g $TERMUX_UID -G $DNS_GID $TERMUX_UID"
}

# 日志统一上限（字节），默认1MB
LOG_MAX_BYTES=1048576
# 读取/输入上限：配置值 1MB、日志默认 500 行/最多 2000 行、CGI 请求体 64KB
CONFIG_VALUE_MAX=1048576
LOG_TAIL_DEFAULT=500
LOG_TAIL_MAX=2000
CGI_BODY_MAX=65536

mkdir -p "$RUNDIR" "$LOG_DIR" "$RUNDIR/session"

# ---------- 字符串编解码 ----------
# awk 转义函数抽成共享片段，拼进各 awk 程序（逐字符拼接：gsub 替换串反斜杠 busybox/gawk 语义不一致）
AWK_ESC='function esc(s,   o, i, n, c) { o = ""; n = length(s); for (i = 1; i <= n; i++) { c = substr(s, i, 1); if (c == "\\") o = o "\\\\"; else if (c == "\"") o = o "\\\""; else if (c == "\t") o = o "\\t"; else if (c == "\r") o = o "\\r"; else if (c == "\n") o = o "\\n"; else o = o c } return o }'
AWK_UNESC='function unesc(s,   o, i, n, c) { o = ""; n = length(s); for (i = 1; i <= n; i++) { c = substr(s, i, 1); if (c != "\\") { o = o c; continue } i++; c = substr(s, i, 1); if (c == "n") o = o "\n"; else if (c == "t") o = o "\t"; else if (c == "r") o = o "\r"; else if (c == "\"") o = o "\""; else if (c == "\\") o = o "\\"; else o = o "\\" c } return o }'
# 设置值记录流解析：生产者按「分隔行 / 键 / 值行...」输出，分隔行随机且保证不出现在任何值里。
# 消费方只需定义 emit(key, value)；值原样还原（含换行），不再靠“下一键前缀”猜边界。
AWK_KV_STREAM='
function kv_flush() { if (kv_have) emit(kv_key, kv_val); kv_have = 0 }
$0 == sep { kv_flush(); kv_want = 1; next }
kv_want { kv_key = $0; kv_want = 0; kv_have = 1; kv_first = 1; kv_val = ""; next }
{ if (kv_first) { kv_val = $0; kv_first = 0 } else { kv_val = kv_val "\n" $0 } }
END { kv_flush() }'

# JSON 字符串编码：\ " tab CR 转义、换行转字面 \n
enc_js() {
	awk "$AWK_ESC"' { if (NR > 1) printf "\\n"; printf "%s", esc($0) }'
}

# JSON 字符串解码：左到右单遍，\n \t \r \" \\ 还原明文，孤立 \ 原样保留
dec_js() {
	awk "$AWK_UNESC"' { printf "%s", unesc($0) }'
}

# 批量解码 setting.conf：单次 awk 输出 key\0value\0（值可含换行，故不用 tab/换行分隔）
dec_js_rows() {
	awk "$AWK_UNESC"'
	{
		sub(/\r$/, "")
		p = index($0, "=")
		if (p == 0) next
		k = substr($0, 1, p - 1); v = substr($0, p + 1)
		if (index(v, "\\") > 0) v = unesc(v)
		printf "%s%c%s%c", k, 0, v, 0
	}'
}

# ---------- 通用校验 ----------

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

# 高危命令拦截（交互执行入口用，防手滑非安全边界）：逐行扫描，输出首个命中行（空=全部放行）。
# 只拦明确无误伤的模式：删根（rm -rf / 结尾/尾空格/glob 星）、mkfs、写块设备、fork 炸弹；
# 局部清理（如 rm -rf /data/local/tmp/x）、含 ":() " 文本的 echo 均放行。
dangerous_line() {
	printf '%s\n' "$1" | grep -m1 -E 'rm -[rf]{2} /( |$|\*)|mkfs|of=/dev/block|:\(\)\{'
}

# ---------- JSON 输出（action.sh / api.cgi 共用） ----------

json_esc() {
	enc_js
}

json_ok() {
	printf '{"success":true}\n'
}

# 错误响应：$1=中文原文模板，其余参数经 ui_msg 代入并转义
json_fail() {
	local text escaped
	text=$(ui_msg "$@")
	escaped=$(printf '%s' "$text" | enc_js)
	printf '{"success":false,"error":"%s"}\n' "$escaped"
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
# 清 run 下残留 pid 文件（session 子目录保留，密码会话跨重启由 webui_expire_password_sessions 处理）；
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
