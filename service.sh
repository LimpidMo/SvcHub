#!/system/bin/sh
# 开机启动入口（KernelSU / Magisk / APatch 通用）：开机命令执行一次 + 拉起保活守护。
MODDIR=${0%/*}
[ -n "$MODDIR" ] && [ -d "$MODDIR" ] || exit 1
. "$MODDIR/lib.sh" 2>/dev/null || exit 1

if [ -f "$DISABLE_FILE" ]; then
	sup_log "disable 标记存在，跳过启动"
	exit 0
fi

# 清理上一会话文件残留
clean_temp_files
# 本次启动标识：WebUI 对比识别跨重启，丢弃旧页面缓存
date +%s > "$BOOTID_FILE" 2>/dev/null
# 开机命令只在启动时执行一次，放后台避免阻塞脚本阶段
load_cfg_sh
if [ -n "$BOOT_COMMANDS" ]; then
	printf '%s\n' "$BOOT_COMMANDS" | run_lines "$LOG_DIR/boot_commands.log" '开机命令' &
fi

# 外部访问默认值落盘（首次启动生成默认 admin 哈希）。
if [ "$WEBUI_PASSWORD_HASH_NEED_SAVE" = "1" ]; then
	write_config_json 2>/dev/null
	load_cfg_sh
fi

# 启动前清遗留会话：密码会话删，Token 长期会话保留（重启不断登）。
webui_clean_stale_sess

# 外部访问默认开启（失败不阻塞开机）。
if [ "$WEBUI_ENABLED" = "1" ] && [ -n "$WEBUI_PASSWORD_HASH" ]; then
	sh "$MODDIR/httpd.sh" start >/dev/null 2>&1
fi

# 拉起 supervisor（单实例由 supervisor 自身保证）
if pidfile_alive "$SPPID" >/dev/null; then
	exit 0
fi
nohup sh "$MODDIR/supervisor.sh" >> "$SUPERLOG" 2>&1 &

exit 0
