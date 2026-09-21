#!/system/bin/sh
# 用法：httpd.sh start|stop|status（仅随开关启停，不自启不保活）。
MODDIR=${0%/*}
[ -n "$MODDIR" ] && [ -d "$MODDIR" ] || exit 1
. "$MODDIR/lib.sh" 2>/dev/null || exit 1

case "$1" in
start)
    # 单实例：旧端口残留先清再起。
    if svc_running httpd; then
        exit 0
    fi
    rm -f "$RUNDIR/httpd.pid"
    BB=$(webui_find_busybox) || { webui_log "启动失败：未找到可用 busybox（含 httpd）"; exit 2; }
    # api.cgi 无 exec 位则 CGI 404，自检自修，修不好拒绝启动。
    if [ ! -x "$MODDIR/webroot/cgi-bin/api.cgi" ]; then
        chmod 755 "$MODDIR/webroot/cgi-bin/api.cgi" 2>/dev/null
    fi
    if [ ! -x "$MODDIR/webroot/cgi-bin/api.cgi" ]; then
        webui_log "启动失败：api.cgi 无可执行权限（CGI 会 404）"
        exit 5
    fi
    # 端口被占直接失败（旧实例残留先关外部访问再重开）。
    # 精确匹配 local_address 字段（第 2 列），子串 grep 会误伤（如 555 命中 5555）。
    PORTHEX=$(printf '%04X' "$WEBUI_PORT" 2>/dev/null)
    if [ -n "$PORTHEX" ] && awk 'NR>1 { split($2,a,":"); if (toupper(a[2]) == "'"$PORTHEX"'") exit 0 } END { exit 1 }' /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
        webui_log "启动失败：端口 $WEBUI_PORT 被占用（若为旧实例残留，先关闭外部访问再重开）"
        exit 3
    fi
    # -h 取绝对路径，-f 前台运行，setsid 独立会话（无则裸启动）。
    case "$MODDIR" in
    /*) HTTPDIR="$MODDIR/webroot" ;;
    *) HTTPDIR=$(pwd)/"$MODDIR/webroot" ;;
    esac
    if command -v setsid >/dev/null 2>&1; then
        setsid "$BB" httpd -f -p "$WEBUI_LISTEN:$WEBUI_PORT" -h "$HTTPDIR" >>"$WEBUI_LOG" 2>&1 &
    else
        "$BB" httpd -f -p "$WEBUI_LISTEN:$WEBUI_PORT" -h "$HTTPDIR" >>"$WEBUI_LOG" 2>&1 &
    fi
    echo "$!" > "$RUNDIR/httpd.pid"
    sleep 1
    if svc_running httpd; then
        # 进程存活≠端口监听，取一次 status 确认链路；回环固定连 127（配 0.0.0.0 时自检连它会自杀）。
        if busybox wget -q -O /dev/null "http://127.0.0.1:$WEBUI_PORT/cgi-bin/api.cgi?a=status" 2>/dev/null || \
           "$BB" wget -q -O /dev/null "http://127.0.0.1:$WEBUI_PORT/cgi-bin/api.cgi?a=status" 2>/dev/null; then
            webui_log "httpd 已启动（$WEBUI_LISTEN:$WEBUI_PORT，pid=$(cat "$RUNDIR/httpd.pid" 2>/dev/null))"
            exit 0
        fi
        webui_log "启动失败：httpd 进程存活但 $WEBUI_LISTEN:$WEBUI_PORT 无响应（CGI 链路不通）"
    else
        webui_log "启动失败：httpd 进程未存活，请查看 $WEBUI_LOG"
    fi
    # 自检失败收尾：杀残留删 pid，防 running 假阳性。
    kill_by_name httpd 2>/dev/null
    rm -f "$RUNDIR/httpd.pid"
    exit 4
    ;;
stop)
	# 组杀失败补直杀 pid（防 pid 丢失的孤儿残留）。
	kill_by_name httpd 2>/dev/null
	if svc_running httpd; then
		pid=$(cat "$RUNDIR/httpd.pid" 2>/dev/null | tr -dc '0-9')
		if [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; then
			kill -15 "$pid" 2>/dev/null
			sleep 1
			kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
			sleep 0.5
		fi
	fi
	rm -f "$RUNDIR/httpd.pid"
	if svc_running httpd; then
		webui_log "httpd 停止失败，进程仍存活"
		exit 1
	fi
	webui_log "httpd 已停止"
	exit 0
	;;
status)
    if svc_running httpd; then
        echo "running"
    else
        echo "stopped"
    fi
    exit 0
    ;;
*)
    echo "用法：httpd.sh start|stop|status" >&2
    exit 1
    ;;
esac
