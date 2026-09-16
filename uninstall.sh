#!/system/bin/sh
# 卸载时执行：停止 supervisor 与本模块登记的所有服务，再清理 pidfile。幂等，只碰自家资源。
MODDIR=${0%/*}
[ -n "$MODDIR" ] && [ -d "$MODDIR" ] || exit 0
. "$MODDIR/lib.sh" 2>/dev/null || exit 0

if [ -f "$SPPID" ]; then
    pid=$(awk '{print $1}' "$SPPID" 2>/dev/null)
    [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
    rm -f "$SPPID"
fi

stop_all
rm -rf "$RUNDIR"

exit 0