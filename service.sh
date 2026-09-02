#!/system/bin/sh
# 开机启动入口（KernelSU / Magisk / APatch 通用）：开机命令执行一次 + 拉起保活守护。
MODDIR=${0%/*}
[ -n "$MODDIR" ] && [ -d "$MODDIR" ] || exit 1
. "$MODDIR/bin/lib.sh" 2>/dev/null || exit 1

if [ -f "$DISABLE_FILE" ]; then
    echo "$(date '+%F %T') disable 标记存在，跳过启动" >> "$SUPERLOG"
    exit 0
fi

# 清理上一会话残留的 pid 与旧服务日志
clean_session_files
# 开机命令只在启动时执行一次，放后台避免阻塞脚本阶段
load_cfg_sh
if [ -n "$BOOT_COMMANDS" ]; then
    printf '%s\n' "$BOOT_COMMANDS" | run_command_lines '开机命令' &
fi

# 拉起 supervisor（单实例由 supervisor 自身保证）
if [ -f "$SPPID" ]; then
    old=$(awk '{print $1}' "$SPPID" 2>/dev/null)
    if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
        exit 0
    fi
    rm -f "$SPPID"
fi
nohup sh "$MODDIR/supervisor.sh" >> "$SUPERLOG" 2>&1 &

exit 0