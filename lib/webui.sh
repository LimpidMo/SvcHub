# SvcHub 公共库：外部访问会话、登录失败计数、密码/Token、端口探测与 httpd 助手。

WEBUI_LOG="$LOG_DIR/webui.log"
# 默认密码单点定义：生成默认哈希、升级迁移推断、改密拒绝回设共用
WEBUI_DEFAULT_PASSWORD=admin
# 登录会话目录（run/ 下，与 pid 文件同级；绝不能放 webroot 文档根下，httpd 会静态外泄）。
# 密码会话 sess_<token>，Token 会话 tsess_<token>（长期登录，会话按天，Token 本身不变）。
WEBUI_SESS_DIR="$RUNDIR/session"
WEBUI_SESS_PREFIX="$WEBUI_SESS_DIR/sess_"
WEBUI_TSESS_PREFIX="$WEBUI_SESS_DIR/tsess_"
WEBUI_FAIL_PREFIX="$RUNDIR/webui_fail_"

webui_log() {
	[ -n "$1" ] || return 0
	echo "[$(date '+%F %T')] $1" >> "$WEBUI_LOG"
}

# 开机时让全部密码会话失效（删除仍有效的 sess_*；过期文件留给 CGI 惰性清理）。
# Token 长期会话在 tsess_*，不在本 glob 内，重启不断登。
webui_expire_password_sessions() {
	local sf exp now
	now=$(date +%s)
	for sf in "$WEBUI_SESS_DIR"/sess_*; do
		[ -f "$sf" ] || continue
		# read 内建读过期戳，免 cat|tr 两次 fork；
		exp=""
		read -r exp < "$sf" 2>/dev/null || :
		case "$exp" in *[!0-9]*) exp="" ;; esac
		[ -n "$exp" ] && [ "$exp" -gt "$now" ] 2>/dev/null && rm -f "$sf"
	done
}

# 轻量读开关（免全量 load）：输出 enabled has_password must_change。
webui_status_fast() {
	local e h d f="$SETTING_FILE"
	e=$(sed -n 's/^[[:space:]]*webui_enabled=\(.*\)/\1/p' "$f" 2>/dev/null | head -n 1)
	h=$(sed -n 's/^[[:space:]]*webui_password_hash=\(.*\)/\1/p' "$f" 2>/dev/null | head -n 1)
	d=$(sed -n 's/^[[:space:]]*webui_password_default=\(.*\)/\1/p' "$f" 2>/dev/null | head -n 1)
	[ -z "$e" ] && e=1
	[ "$e" = 0 ] || e=1
	[ -n "$h" ] && h=1 || h=0
	[ "$d" = 1 ] || d=0
	printf '%s %s %s\n' "$e" "$h" "$d"
}

# 旧配置没有 webui_password_default 键时，按哈希是否为默认 admin 推断并落盘（一次性迁移）。
# 调用前须已 load_cfg_sh（哈希已生成或已加载）；非空值（0/1）视为已迁移，直接跳过。
webui_password_default_migrate() {
	local val
	[ -f "$SETTING_FILE" ] || return 0
	val=$(setting_file_get webui_password_default)
	[ -n "$val" ] && return 0
	if [ -n "$WEBUI_PASSWORD_HASH" ] && webui_check_password "$WEBUI_DEFAULT_PASSWORD" "$WEBUI_PASSWORD_HASH"; then
		WEBUI_PASSWORD_DEFAULT=1
	else
		WEBUI_PASSWORD_DEFAULT=0
	fi
	write_settings
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

# WEBUI_PORT 状态：0=LISTEN 1=未监听 2=无法探测（无 /proc/net，如 PC 沙盒）。
# 断网/省电后进程可能活着但监听 socket 被 ROM 摘除，pid 探活探不出，端口探活补这个盲区。
webui_port_state() {
	local hex
	hex=$(printf '%04X' "$WEBUI_PORT" 2>/dev/null)
	[ -n "$hex" ] || return 2
	[ -r /proc/net/tcp ] || [ -r /proc/net/tcp6 ] || return 2
	# 数据行按 local_address 格式识别（首列 sl 是 "0:" 带冒号，不能按纯数字匹配）
	awk -v hex="$hex" '$2 ~ /^[0-9A-Fa-f]+:[0-9A-Fa-f]+$/ { split($2, a, ":"); if (toupper(a[2]) == hex && $4 == "0A") found = 1 } END { exit !found }' /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

# 保活判定：只有「确定未监听」才算异常，未知按可用处理，避免误杀健康实例。
webui_port_down() {
	webui_port_state
	[ $? -eq 1 ]
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

# ---------- 会话文件 ----------

# 会话剩余秒数：$1=token，输出剩余秒。空读只视为本次无效不删文件——并发续期下 mv 瞬间
sess_left() {
	local t=$1 f now exp i
	[ "${#t}" -eq 64 ] || return 1
	case "$t" in *[!A-Za-z0-9]*) return 1 ;; esac
	for f in "$WEBUI_SESS_PREFIX$t" "$WEBUI_TSESS_PREFIX$t"; do
		[ -f "$f" ] || continue
		exp=""
		i=0
		while [ "$i" -lt 2 ] && [ -z "$exp" ]; do
			exp=$(cat "$f" 2>/dev/null | tr -dc '0-9')
			[ -n "$exp" ] && break
			sleep 0.1 2>/dev/null
			i=$((i + 1))
		done
		now=$(date +%s)
		case "$exp" in
		''|*[!0-9]*) return 1 ;;                       # 读半截/空：本次无效，文件留给后续请求
		*) [ "$exp" -gt "$now" ] 2>/dev/null || { rm -f "$f"; return 1; } ;;
		esac
		printf '%s' "$((exp - now))"
		return 0
	done
	return 1
}

# 会话校验：任一前缀命中即有效（过期顺手删文件）。
sess_valid() {
	local left
	left=$(sess_left "$1") && [ -n "$left" ]
}

# 滑动续期：有效则按同类 TTL 重写过期戳并输出新剩余秒，过期返回 1。
# 空读/读半截（并发 mv 瞬间）只按本次无效处理，绝不删文件——删错活会话=随机掉登录；
# 写入失败也保留原文件，续期失败仅本请求不续期，下次请求再试。
sess_touch() {
	local t=$1 f now exp ttl tmp i
	[ "${#t}" -eq 64 ] || return 1
	case "$t" in *[!A-Za-z0-9]*) return 1 ;; esac
	now=$(date +%s)
	for f in "$WEBUI_SESS_PREFIX$t" "$WEBUI_TSESS_PREFIX$t"; do
		[ -f "$f" ] || continue
		exp=""
		i=0
		while [ "$i" -lt 2 ] && [ -z "$exp" ]; do
			exp=$(cat "$f" 2>/dev/null | tr -dc '0-9')
			[ -n "$exp" ] && break
			sleep 0.1 2>/dev/null
			i=$((i + 1))
		done
		case "$exp" in
		''|*[!0-9]*) return 1 ;;                       # 读半截：不删，留给下个请求正常续
		*) [ "$exp" -gt "$now" ] 2>/dev/null || { rm -f "$f"; return 1; } ;;
		esac
		case "$f" in
		*"tsess_"*) ttl=$((TOKEN_DAYS * 86400)) ;;
		*) ttl=$SESS_TTL ;;
		esac
		exp=$((now + ttl))
		tmp="$f.tmp.$$"
		if printf '%s' "$exp" > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null; then
			printf '%s' "$ttl"
			return 0
		fi
		rm -f "$tmp"
		return 1
	done
	return 1
}

# 写会话：$1=token $2=过期戳 $3=1 走 Token 前缀，否则密码前缀（临时文件改名防并发读半截）。
sess_write() {
	local f tmp
	if [ "$3" = "1" ]; then
		f="$WEBUI_TSESS_PREFIX$1"
	else
		f="$WEBUI_SESS_PREFIX$1"
	fi
	tmp="$f.tmp.$$"
	printf '%s' "$2" > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null
}

# 清过期会话（有效保留），防超时文件堆积。
sess_sweep() {
	local sf st
	for sf in "$WEBUI_SESS_DIR"/sess_* "$WEBUI_SESS_DIR"/tsess_*; do
		[ -f "$sf" ] || continue
		st=${sf##*sess_}
		sess_valid "$st" || true
	done
}

# ---------- 登录失败计数 ----------

# 客户端 IP（只信 REMOTE_ADDR）。
client_ip() {
	printf '%s' "${REMOTE_ADDR:-unknown}" | tr -c 'A-Za-z0-9.:_' '_'
}

# 登录失败记录（次数:解锁时间），锁定期返回 0。
fail_read() {
	local f="$WEBUI_FAIL_PREFIX$(client_ip)" n=0 unlock=0
	if [ -f "$f" ]; then
		while IFS=':' read -r n unlock; do :; done < "$f" 2>/dev/null
	fi
	printf '%s:%s\n' "${n:-0}" "${unlock:-0}"
}

fail_locked() {
	local r n unlock now
	r=$(fail_read); n=${r%%:*}; unlock=${r##*:}
	now=$(date +%s)
	if [ "$unlock" -gt "$now" ] 2>/dev/null; then
		return 0
	fi
	# 锁定期已过清零重计。
	[ "$unlock" -gt 0 ] 2>/dev/null && printf '0:0' > "$WEBUI_FAIL_PREFIX$(client_ip)"
	return 1
}

fail_add() {
	local r n unlock now
	r=$(fail_read); n=${r%%:*}; unlock=${r##*:}
	now=$(date +%s)
	n=$((n + 1))
	if [ "$n" -ge "$FAIL_MAX" ]; then
		printf '%s:%s' "$n" "$((now + FAIL_LOCK))" > "$WEBUI_FAIL_PREFIX$(client_ip)"
		webui_log "$(ui_msg '登录锁定：%s 连续失败 %s 次，锁定 %s 秒' "$(client_ip)" "$n" "$FAIL_LOCK")"
	else
		printf '%s:%s' "$n" 0 > "$WEBUI_FAIL_PREFIX$(client_ip)"
	fi
}

fail_clear() {
	rm -f "$WEBUI_FAIL_PREFIX$(client_ip)"
}

# 清过期失败计数（锁定已解除的文件），防按 IP 无界堆积；正常计数与锁定中的文件保留。
fail_sweep() {
	local f unlock now
	now=$(date +%s)
	for f in "$WEBUI_FAIL_PREFIX"*; do
		[ -f "$f" ] || continue
		unlock=$(cat "$f" 2>/dev/null | tr -dc '0-9:' | sed 's/^.*://')
		[ "$unlock" -gt 0 ] 2>/dev/null && [ "$unlock" -le "$now" ] 2>/dev/null && rm -f "$f"
	done
}
