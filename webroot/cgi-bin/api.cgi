#!/bin/sh
# CGI 网关：鉴权后把 HTTP 请求转给 action.sh（不拼 shell，无注入）。
MODDIR=${0%/*}
# MODDIR 经 SCRIPT_FILENAME 解析（httpd 下 $0 无目录信息）。
if [ -n "$SCRIPT_FILENAME" ]; then
    MODDIR=$SCRIPT_FILENAME
fi
case "$MODDIR" in
*webroot/cgi-bin*) MODDIR=${MODDIR%webroot/cgi-bin*}; MODDIR=${MODDIR%/} ;;
esac
[ -z "$MODDIR" ] && MODDIR=.
[ -n "$MODDIR" ] && [ -d "$MODDIR" ] || exit 1
# 先 cd 模块根再 source，相对路径不漂移。
cd "$MODDIR" 2>/dev/null || exit 1
MODDIR=$(pwd)
. "$MODDIR/lib.sh" 2>/dev/null || exit 1
# 业务函数同进程调用（省掉 sh action.sh 子进程；只定义函数不分发）。
ACTION_SOURCED=1
. "$MODDIR/action.sh" 2>/dev/null || exit 1

cgi_status() {
    # 头体之间空一行，否则 httpd 吞 body。
    if [ -n "$2" ]; then
        printf 'Status: %s\nContent-Type: application/json\n%s\n\n%s' "$1" "$2" "$3"
    else
        printf 'Status: %s\nContent-Type: application/json\n\n%s' "$1" "$3"
    fi
}

cgi_ok() {
    cgi_status "200 OK" "" "$1"
}

cgi_fail() {
    cgi_status "$1" "" "{\"success\":false,\"error\":\"$2\"}"
}

# URL 解码（无尾随换行仍处理最后一行）。
urldec() {
    printf '%s' "$1" | sed -e 's/+/ /g' -e 's/%\([0-9a-fA-F][0-9a-fA-F]\)/\\x\1/g' | while IFS= read -r l || [ -n "$l" ]; do
        printf '%b' "$l"
    done
}

# 取查询参数 $1=名（已解码）。
qparam() {
    printf '%s' "$QUERY_STRING" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n 1 | { IFS= read -r v || [ -n "$v" ]; urldec "$v"; }
}

# 取 Cookie $1=名。
cookie() {
    printf '%s' "$HTTP_COOKIE" | tr ';' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed -n "s/^$1=//p" | head -n 1
}

# 取 Bearer Token。
bearer() {
    case "$HTTP_AUTHORIZATION" in
    Bearer*) printf '%s' "$HTTP_AUTHORIZATION" | sed 's/^Bearer[[:space:]]*//;s/[[:space:]]*$//' ;;
    esac
}

# 路由：PATH_INFO 优先，回退 a=。
route() {
    local r=${PATH_INFO##*/}
    [ -n "$r" ] && [ "$r" != "api.cgi" ] && { printf '%s' "$r"; return; }
    qparam a
}

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
		webui_log "登录锁定：$(client_ip) 连续失败 $n 次，锁定 $FAIL_LOCK 秒"
	else
		printf '%s:%s' "$n" 0 > "$WEBUI_FAIL_PREFIX$(client_ip)"
	fi
}

fail_clear() {
    rm -f "$WEBUI_FAIL_PREFIX$(client_ip)"
}

# 会话剩余秒数：$1=token，输出剩余秒（过期/无效输出空并顺手删文件，空读重试防并发续写中途）。
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
		if [ -z "$exp" ] || [ "$exp" -le "$now" ] 2>/dev/null; then
			rm -f "$f"
			return 1
		fi
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

# 滑动续期：有效则按同类 TTL 重写过期戳并输出新剩余秒，过期返回 1（空读重试+原子改名防并行续期竞写）。
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
		[ -n "$exp" ] && [ "$exp" -gt "$now" ] 2>/dev/null || { rm -f "$f"; return 1; }
		case "$f" in
		*"tsess_"*) ttl=$((TOKEN_DAYS * 86400)) ;;
		*) ttl=$SESS_TTL ;;
		esac
		exp=$((now + ttl))
		tmp="$f.tmp.$$"
		printf '%s' "$exp" > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; return 1; }
		printf '%s' "$ttl"
		return 0
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

# 鉴权（滑动续期）：命中有效会话则续期，结果经 AUTH_COOKIE 回显。
AUTH_COOKIE=""
auth_check() {
    local t long_only=$1 left
    AUTH_COOKIE=""
    load_cfg_sh
    t=$(cookie SVC_SESS)
    if [ -n "$t" ]; then
        left=$(sess_touch "$t" 2>/dev/null)
        if [ -n "$left" ]; then
            AUTH_COOKIE="Set-Cookie: SVC_SESS=$t; HttpOnly; Path=/; Max-Age=$left"
            return 0
        fi
    fi
    t=$(bearer)
    if [ -n "$t" ]; then
        left=$(sess_touch "$t" 2>/dev/null)
        if [ -n "$left" ]; then
            AUTH_COOKIE="Set-Cookie: SVC_SESS=$t; HttpOnly; Path=/; Max-Age=$left"
            return 0
        fi
        [ -n "$WEBUI_TOKEN" ] && [ "$t" = "$WEBUI_TOKEN" ] && return 0
    fi
    if [ "$long_only" = "1" ]; then
        t=$(qparam token)
        [ -n "$t" ] && [ -n "$WEBUI_TOKEN" ] && [ "$t" = "$WEBUI_TOKEN" ] && return 0
    fi
    return 1
}

# 带续期 Cookie 的 200（无续期走普通 cgi_ok）。
cgi_authed() {
    if [ -n "$AUTH_COOKIE" ]; then
        cgi_status "200 OK" "$AUTH_COOKIE" "$1"
    else
        cgi_ok "$1"
    fi
}
# 从 POST 表单取字段 $1=名。
form_field() {
    printf '%s' "$FORM_BODY" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n 1 | { IFS= read -r v || [ -n "$v" ]; urldec "$v"; }
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

load_cfg_sh
R=$(route)
[ -n "$R" ] || { cgi_fail "404 Not Found" "未知接口"; exit 0; }

case "$R" in
status)
    if [ -n "$WEBUI_PASSWORD_HASH" ]; then hp=1; else hp=0; fi
    cgi_ok "{\"online\":true,\"has_password\":$hp}"
    ;;
login)
    [ "$REQUEST_METHOD" = "POST" ] || { cgi_fail "405 Method Not Allowed" "仅支持 POST"; exit 0; }
    if fail_locked; then
        cgi_fail "429 Too Many Requests" "尝试过多，请 $FAIL_LOCK 秒后再试"
        exit 0
    fi
    FORM_BODY=$(cat)
    PW=$(form_field password)
    TK=$(form_field token)
    ok=""; via_token=""
    if [ -n "$PW" ] && [ -n "$WEBUI_PASSWORD_HASH" ]; then
        webui_check_password "$PW" "$WEBUI_PASSWORD_HASH" && ok=1
    fi
    if [ -z "$ok" ] && [ -n "$TK" ] && [ -n "$WEBUI_TOKEN" ] && [ "$TK" = "$WEBUI_TOKEN" ]; then
        ok=1; via_token=1
    fi
    if [ -z "$ok" ]; then
        fail_add
        webui_log "登录失败：$(client_ip)"
        cgi_fail "401 Unauthorized" "密码或 Token 错误"
        exit 0
    fi
    fail_clear
    # 密码会话按 SESS_TTL，Token 会话按 TOKEN_DAYS 天。
    if [ -n "$via_token" ]; then TTL=$((TOKEN_DAYS * 86400)); is_tsess=1; else TTL=$SESS_TTL; is_tsess=""; fi
    OLDSESS=$(cookie SVC_SESS)
    if [ -n "$OLDSESS" ]; then
        LEFT=$(sess_left "$OLDSESS")
        if [ -n "$LEFT" ]; then
            webui_log "登录成功（会话复用）：$(client_ip)"
            cgi_status "200 OK" "Set-Cookie: SVC_SESS=$OLDSESS; HttpOnly; Path=/; Max-Age=$LEFT" '{"success":true,"reused":true}'
            exit 0
        fi
    fi
    # 新建会话前清过期文件（有效会话不动，多设备共存）。
    sess_sweep
    SESS=$(webui_gen_token) || { cgi_fail "500 Internal Server Error" "会话生成失败"; exit 0; }
    sess_write "$SESS" "$(($(date +%s) + TTL))" "$is_tsess"
    webui_log "登录成功：$(client_ip)"
    cgi_status "200 OK" "Set-Cookie: SVC_SESS=$SESS; HttpOnly; Path=/; Max-Age=$TTL" '{"success":true}'
    ;;
logout)
    auth_check 0 || { cgi_fail "401 Unauthorized" "未登录"; exit 0; }
    # 删会话文件（两前缀都清，非法值跳过）。
    for T in "$(cookie SVC_SESS)" "$(bearer)"; do
        case "$T" in ''|*[!A-Za-z0-9]*) ;; *) rm -f "$WEBUI_SESS_PREFIX$T" "$WEBUI_TSESS_PREFIX$T" ;; esac
    done
    cgi_status "200 OK" "Set-Cookie: SVC_SESS=; HttpOnly; Path=/; Max-Age=0" '{"success":true}'
    ;;
webuitoken)
    # 仅会话 Cookie 可查（防 ?token= 进代理日志扩散）。
    sess_valid "$(cookie SVC_SESS)" || { cgi_fail "401 Unauthorized" "未登录"; exit 0; }
    OUT=$(api_webui_token_show 2>/dev/null)
    cgi_authed "$OUT"
    ;;
whoami)
    # 登录态自检（滑动续期，每次有效访问续满 TTL）。
    if auth_check 0; then
        cgi_authed '{"success":true,"authed":true}'
    else
        cgi_fail "401 Unauthorized" "未登录"
    fi
    ;;
webuistatus)
    # 浏览器只读（改密/开关走管理器）。
    if auth_check 0; then
        OUT=$(api_webui_status 2>/dev/null)
        cgi_authed "$OUT"
    else
        cgi_fail "401 Unauthorized" "未登录"
    fi
    ;;
webuipasswd|webuiregen)
    auth_check 0 || { cgi_fail "401 Unauthorized" "未登录"; exit 0; }
    FORM_BODY=$(cat)
    case "$R" in
    webuipasswd)
        PW=$(form_field password)
        OLD=$(form_field old)
        OUT=$(printf 'password=%s\nold=%s\n' \
            "$(printf '%s' "$PW" | base64 2>/dev/null | tr -d '\n')" \
            "$(printf '%s' "$OLD" | base64 2>/dev/null | tr -d '\n')" \
            | api_webui_set_password 2>/dev/null)
        ;;
    *) OUT=$(api_webui_regen_token 2>/dev/null) ;;
    esac
    cgi_authed "$OUT"
    ;;
webuistart|webuistop)
    # 开关走管理器，CGI 不代理。
    cgi_fail "403 Forbidden" "请在管理器内操作"
    ;;
svcstatus|getconfig|getsettings|getservices|saveconfig|savesettings|saveservices|start|stop|logs|readlog|clearlog|execboot|runcmd|runcmdtermux)
    auth_check 1 || { cgi_fail "401 Unauthorized" "未登录"; exit 0; }
    # 滑动过期：每次有效访问续满 TTL，锁屏回来不断登。
    case "$R" in
    svcstatus) SUB=status ;;
    *) SUB=$R ;;
    esac
    case "$SUB" in
    getconfig)
        # 出站过滤哈希与 Token 明文。
        OUT=$(api_get_config 2>/dev/null | sed 's/"webui_password_hash":"[^"]*"/"webui_password_hash":""/; s/"webui_token":"[^"]*"/"webui_token":""/')
        cgi_authed "$OUT"
        ;;
    getsettings)
        # 出站过滤哈希与 Token 明文（与 getconfig 同规则）。
        OUT=$(api_get_settings 2>/dev/null | sed 's/"webui_password_hash":"[^"]*"/"webui_password_hash":""/; s/"webui_token":"[^"]*"/"webui_token":""/')
        cgi_authed "$OUT"
        ;;
    getservices)
        OUT=$(api_get_services 2>/dev/null)
        cgi_authed "$OUT"
        ;;
    saveconfig|savesettings|saveservices|runcmd|runcmdtermux|execboot)
        # body 透传 stdin；空 body 直接拒，防“已保存”假成功。
        BODY_LEN=${CONTENT_LENGTH:-0}
        case "$BODY_LEN" in ''|*[!0-9]*) BODY_LEN=0 ;; esac
        if [ "$BODY_LEN" -le 0 ] 2>/dev/null; then
            cgi_fail "400 Bad Request" "请求体为空"
            exit 0
        fi
        case "$SUB" in
        saveconfig) OUT=$(cat | api_save_config 2>/dev/null) ;;
        savesettings) OUT=$(cat | api_save_settings 2>/dev/null) ;;
        saveservices) OUT=$(cat | api_save_services 2>/dev/null) ;;
        runcmd) OUT=$(cat | api_run_cmd 2>/dev/null) ;;
        runcmdtermux) OUT=$(cat | api_run_cmd termux 2>/dev/null) ;;
        execboot) OUT=$(api_exec_boot 2>/dev/null) ;;
        esac
        cgi_authed "$OUT"
        ;;
    start|stop|readlog|clearlog)
        # 查询参数转 argv（白名单函数直调，参数经 valid_name 校验）。
        P1=$(qparam p1)
        P2=$(qparam p2)
        case "$SUB" in
        start) OUT=$(api_start_service "$P1" "$P2" 2>/dev/null) ;;
        stop) OUT=$(api_stop_service "$P1" 2>/dev/null) ;;
        readlog) OUT=$(api_read_log "$P1" "$P2" 2>/dev/null) ;;
        clearlog)
            if clear_log "$P1"; then OUT='{"success":true}'; else OUT='{"success":false,"error":"名称不合法"}'; fi
            ;;
        esac
        cgi_authed "$OUT"
        ;;
    *)
        case "$SUB" in
        status) OUT=$(api_get_status 2>/dev/null) ;;
        logs) OUT=$(api_get_logs 2>/dev/null) ;;
        esac
        cgi_authed "$OUT"
        ;;
    esac
    ;;
*)
    cgi_fail "404 Not Found" "未知接口"
    ;;
esac
exit 0
