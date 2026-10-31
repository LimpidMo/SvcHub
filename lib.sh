#!/system/bin/sh
# SvcHub 公共库入口：按序加载 lib/ 下的职责模块（配置、进程、策略、会话）。
# 注意：调用方必须先设置 MODDIR=${0%/*} 再 source 本文件。

if [ -z "$MODDIR" ] || [ ! -d "$MODDIR" ]; then
	echo "lib.sh: MODDIR 未设置或不存在" >&2
	exit 1
fi

# 顺序固定：core 先定义路径并建目录，policy/webui 在 source 期用这些路径拼日志/会话常量。
# update 放最后：依赖 core 的路径常量、config 的 update.conf 读取、proc 的服务启停。
. "$MODDIR/lib/core.sh" || exit 1
. "$MODDIR/lib/i18n.sh" || exit 1
. "$MODDIR/lib/config.sh" || exit 1
. "$MODDIR/lib/proc.sh" || exit 1
. "$MODDIR/lib/policy.sh" || exit 1
. "$MODDIR/lib/webui.sh" || exit 1
. "$MODDIR/lib/update.sh" || exit 1

# source 落点：加载 web.conf。
load_web_conf
