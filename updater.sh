#!/system/bin/sh
# SvcHub 更新器 CLI：check（探测 + auto 条目自动更新）| update <name> | updateall（逐条替换）。
# 由 action.sh / supervisor.sh 后台拉起；单实例锁 run/update.pid。
MODDIR=${0%/*}
[ -n "$MODDIR" ] && [ -d "$MODDIR" ] || exit 1
. "$MODDIR/lib.sh" 2>/dev/null || exit 1
load_cfg_sh
load_update_conf

# 单实例锁：已有任务在跑则直接退出（周期检查与手动触发可能撞车）。
acquire_lock() {
	if pidfile_alive "$UPDATE_PID" >/dev/null; then
		update_log "$(ui_msg '已有更新任务在运行，本次跳过')"
		return 1
	fi
	rm -f "$UPDATE_PID"
	printf '%s\n' "$$" > "$UPDATE_PID" 2>/dev/null || return 1
	return 0
}

release_lock() {
	rm -f "$UPDATE_PID" 2>/dev/null
}

# 目标路径：$1=条目 target（相对 server_dir）→ 绝对路径。
entry_target_path() {
	case "$1" in
	/*) printf '%s\n' "$1" ;;
	*) printf '%s\n' "$SERVER_DIR/$1" ;;
	esac
}

# 单条目探测：写 update_ver 并输出「名|已装|最新|是否有更新」。
check_entry() {
	local name=$1 repo=$2 ins=$3 vercmd=$4 target=$5 tag cmp cur
	if ! update_fetch_latest "$repo"; then
		# 把实际请求的 URL 写进日志：用户拿去浏览器/adb 一试便知是代理问题还是网络问题
		update_log "[$name] $(ui_msg '版本探测失败：%s' "$(update_api_url "$repo")")"
		CHK_CUR=""; CHK_TAG=""; CHK_FLAG=0
		return 1
	fi
	tag=$UPDATE_LATEST_TAG
	update_set_update_ver "$name" "$tag"
	# 本地版本实测+回写统一走 lib 助手（与 update_entry/getupdates 同一口径）
	cur=$(update_refresh_ins_ver "$name" "$vercmd" "$target" "$ins")
	if [ -z "$cur" ]; then
		cmp=1
		update_log "[$name] $(ui_msg '发现新版本：%s → %s' "-" "$tag")"
	else
		cmp=$(ver_cmp "$tag" "$cur")
		if [ "$cmp" -gt 0 ]; then
			update_log "[$name] $(ui_msg '发现新版本：%s → %s' "$cur" "$tag")"
		else
			update_log "[$name] $(ui_msg '无新版本：%s' "$cur")"
		fi
	fi
	# 结果经全局变量传给 cmd_check（不用 $() 子 shell——那会丢 UPDATE_ASSETS）
	CHK_CUR=$cur
	CHK_TAG=$tag
	CHK_FLAG=$([ "$cmp" -gt 0 ] && echo 1 || echo 0)
	return 0
}

# 全量探测：遍历条目，逐个处理（串行=天然更新队列）。
# 条目 auto=1 且探测到新版本 → 直接进入该条目的完整更新流程（自动更新）。
cmd_check() {
	local name repo asset target mode svc ins vercmd auto line total
	[ -n "$UPDATE_ENTRIES" ] || { update_log "$(ui_msg '没有配置任何更新条目')"; return 0; }
	total=$(printf '%s\n' "$UPDATE_ENTRIES" | grep -c .)
	update_log "$(ui_msg '开始检查 %s 个条目' "$total")"
	# check_entry 必须在父 shell 跑：其内 update_fetch_latest 填充的全局 UPDATE_ASSETS
	# 供 auto 触发的 update_entry 直接复用；放 $() 子 shell 里会随子 shell 丢失（曾致自动更新全部失败）。
	# 探测结果经全局 CHK_* 传递，不落盘
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		IFS='|' read -r name repo asset target mode svc ins vercmd _uv auto <<UEOF
$line
UEOF
		check_entry "$name" "$repo" "$ins" "$vercmd" "$target"
		[ "$auto" = "1" ] && [ "$CHK_FLAG" = "1" ] || continue
		# 自动更新：check 阶段已 fetch 过，把 tag 传下去省一次请求
		update_log "[$name] $(ui_msg '自动更新（检查发现新版本 %s）' "$CHK_TAG")"
		update_entry "$name" "$repo" "$asset" "$target" "$mode" "$svc" "$ins" "$vercmd" "$CHK_TAG"
	done <<EOF
$UPDATE_ENTRIES
EOF
	update_log "$(ui_msg '检查完成')"
	return 0
}

# 取关联服务的启动命令（launch_svc binary 用）；服务不存在输出空。
update_svc_cmd() {
	local row cmd
	row=$(pick_binary "$1")
	[ -n "$row" ] || return 1
	IFS='|' read -r _n _p _a cmd _e <<UEOF
$row
UEOF
	printf '%s\n' "$cmd"
}

# 失败后回滚：$1=是否有备份(1/0) $2=目标路径 $3=mode（dir 走整目录还原）。结果写日志。
rollback_after_fail() {
	local bak=$1 abs_target=$2 mode=$3
	if [ "$bak" -ne 1 ]; then
		update_log "$(ui_msg '无旧版本可回滚')"
		return 0
	fi
	if [ "$mode" = "dir" ]; then
		if update_rollback_dir "$abs_dir"; then
			update_log "$(ui_msg '已回滚到旧版本')"
		else
			update_log "$(ui_msg '回滚失败，旧文件仍在：%s' "$abs_dir.svchub_bak")"
		fi
		return 0
	fi
	if update_rollback_file "$abs_target"; then
		update_log "$(ui_msg '已回滚到旧版本')"
	else
		update_log "$(ui_msg '回滚失败，旧文件仍在：%s' "$abs_target.svchub_bak")"
	fi
	return 0
}

# 单条目替换：完整流程（探测 → 下载 → 校验 → 解包 → 停服务 → 备份 → 替换 → 启服务 → 探活 → 回滚）。
# $9=known_tag（可选）：自动更新路径在 check 阶段已 fetch 过，传入则跳过重复探测。
update_entry() {
	local name=$1 repo=$2 asset_tpl=$3 target=$4 mode=$5 svc=$6 ins=$7 vercmd=$8 known_tag=$9
	local tag cmp asset dl digest total url abs_target abs_dir tmpd src bak cur
	abs_target=$(entry_target_path "$target")
	# dir 模式的落点是目标二进制所在的文件夹，不是把文件名当目录名
	abs_dir=$(dirname "$abs_target")
	tmpd="$UPDATE_TMPDIR/$name"

	if [ -n "$known_tag" ]; then
		tag=$known_tag
	else
		if ! update_fetch_latest "$repo"; then
			update_log "[$name] $(ui_msg '版本探测失败：%s' "$(update_api_url "$repo")")"
			return 1
		fi
		tag=$UPDATE_LATEST_TAG
	fi
	update_set_update_ver "$name" "$tag"
	# 本地版本实测+回写统一走 lib 助手（与 check_entry/getupdates 同一口径）
	cur=$(update_refresh_ins_ver "$name" "$vercmd" "$target" "$ins")
	if [ -n "$cur" ]; then
		cmp=$(ver_cmp "$tag" "$cur")
		if [ "$cmp" -le 0 ]; then
			update_log "[$name] $(ui_msg '已是最新版本 %s' "$tag")"
			return 0
		fi
	fi
	# 已知 tag（自动更新路径）时 check_entry 已记过发现新版本，不重复记
	[ -n "$known_tag" ] || update_log "[$name] $(ui_msg '发现新版本：%s → %s' "$cur" "$tag")"

	asset=$(update_resolve_asset "$asset_tpl" "$tag")
	# 资产名可能不含版本号：精确未命中时按目标 basename 在列表里唯一匹配
	digest=$(update_asset_digest "$UPDATE_ASSETS" "$asset")
	if [ -z "$digest" ]; then
		local picked
		picked=$(update_pick_asset "$UPDATE_ASSETS" "$asset" "$(basename "$target")") || {
			update_log "[$name] $(ui_msg '未找到匹配的资产：%s' "$asset")"
			return 1
		}
		asset=$picked
		digest=$(update_asset_digest "$UPDATE_ASSETS" "$asset")
	fi

	url=$(update_download_url "$repo" "$tag" "$asset")
	mkdir -p "$UPDATE_TMPDIR" 2>/dev/null
	dl="$tmpd.dl"
	rm -f "$dl"
	update_log "[$name] $(ui_msg '开始下载：%s' "$asset")"
	# 带进度下载：release API 的 size 用于百分比（每 5% 记一行，与日志弹窗 3 秒刷新衔接）
	total=$(update_asset_size "$UPDATE_ASSETS" "$asset")
	if ! update_download "$url" "$dl" "$name" "$total"; then
		rm -f "$dl"
		update_log "[$name] $(ui_msg '下载失败：%s' "$asset")"
		return 1
	fi
	[ -s "$dl" ] || { rm -f "$dl"; update_log "[$name] $(ui_msg '下载内容为空')"; return 1; }

	if [ -n "$digest" ]; then
		if update_verify "$dl" "$digest"; then
			update_log "[$name] $(ui_msg '完整性校验通过')"
		else
			rm -f "$dl"
			update_log "[$name] $(ui_msg '完整性校验不通过，已中止更新（旧文件未改动）')"
			return 1
		fi
	else
		update_log "[$name] $(ui_msg '未获取到校验值，跳过完整性校验')"
	fi

	if [ "$mode" = "raw" ]; then
		# 不解包：下载文件本身就是二进制（sha256 已在上方验过）
		src=$dl
	elif [ "$mode" = "dir" ]; then
		rm -rf "$tmpd" 2>/dev/null
		if ! update_unpack "$dl" "$tmpd"; then
			rm -f "$dl"
			update_log "[$name] $(ui_msg '解包失败')"
			return 1
		fi
		rm -f "$dl"
		src=$(update_pick_dir "$tmpd") || { rm -rf "$tmpd"; update_log "[$name] $(ui_msg '解包后无可用内容')"; return 1; }
	else
		# file 模式：解包 + 定位 + 嵌套归档再解一层
		if ! src=$(update_extract_payload "$dl" "$tmpd" "$(basename "$target")"); then
			rm -rf "$tmpd" 2>/dev/null
			rm -f "$dl"
			update_log "[$name] $(ui_msg '解包后未找到目标文件')"
			return 1
		fi
		rm -f "$dl"
	fi
	# 停关联服务（无关联则不碰任何服务）；顺手解析其启动命令备用（失败回滚后重启旧版本）
	svc_cmd=""
	if [ -n "$svc" ]; then
		update_log "[$name] $(ui_msg '停止关联服务：%s' "$svc")"
		stop_svc "$svc"
		svc_cmd=$(update_svc_cmd "$svc")
	fi

	# 备份旧文件/目录（首次安装无旧目标，跳过）；dir 模式备份二进制所在文件夹
	if [ "$mode" = "dir" ]; then
		if update_backup_dir "$abs_dir"; then
			bak=1
		else
			bak=0
		fi
	elif update_backup_file "$abs_target"; then
		bak=1
	else
		bak=0
	fi

	if [ "$mode" = "dir" ]; then
		# 目录模式：内容并入二进制所在文件夹（保留已有配置，只覆盖归档内含的文件）
		mkdir -p "$abs_dir" 2>/dev/null
		if ! cp -rf "$src"/. "$abs_dir"/ 2>/dev/null; then
			rollback_after_fail "$bak" "$abs_dir" "$mode"
			# 失败也要让旧版本继续跑（巡检关闭的服务不会自动拉回）
			if [ -n "$svc" ] && [ -n "$svc_cmd" ]; then
				launch_svc binary "$svc" "$svc_cmd"
				update_log "[$name] $(ui_msg '启动关联服务：%s' "$svc")"
			fi
			rm -rf "$tmpd" 2>/dev/null
			update_log "[$name] $(ui_msg '写入目标目录失败')"
			return 1
		fi
		chmod -R 755 "$abs_dir" 2>/dev/null
	else
		if ! update_replace_file "$src" "$abs_target"; then
			rollback_after_fail "$bak" "$abs_target" "$mode"
			if [ -n "$svc" ] && [ -n "$svc_cmd" ]; then
				launch_svc binary "$svc" "$svc_cmd"
				update_log "[$name] $(ui_msg '启动关联服务：%s' "$svc")"
			fi
			rm -rf "$tmpd" 2>/dev/null
			update_log "[$name] $(ui_msg '替换目标文件失败')"
			return 1
		fi
	fi
	rm -rf "$tmpd" 2>/dev/null
	rm -f "$dl"

	# 启关联服务并探活（svc_cmd 为空 = 关联服务不存在）
	if [ -n "$svc" ]; then
		if [ -z "$svc_cmd" ]; then
			update_log "[$name] $(ui_msg '关联服务 %s 不存在，跳过重启' "$svc")"
		else
			update_log "[$name] $(ui_msg '启动关联服务：%s' "$svc")"
			launch_svc binary "$svc" "$svc_cmd"
			if wait_svc_running "$svc" 20; then
				update_log "[$name] $(ui_msg '关联服务 %s 启动成功' "$svc")"
			else
				update_log "[$name] $(ui_msg '关联服务 %s 启动失败，正在回滚' "$svc")"
				# 先停服务再回滚：探活失败不代表进程已死，cp 覆盖运行中二进制会失败
				if [ "$bak" -eq 1 ]; then
					stop_svc "$svc"
					# dir 模式回滚的是所在文件夹，file/raw 回滚的是二进制文件本身
					if [ "$mode" = "dir" ]; then
						rollback_after_fail "$bak" "$abs_dir" "$mode"
					else
						rollback_after_fail "$bak" "$abs_target" "$mode"
					fi
					# 回滚后重启旧版本（服务本身起不来时也会失败，日志已说明）
					launch_svc binary "$svc" "$svc_cmd"
				fi
				return 1
			fi
		fi
	fi

	# 成功：清理备份，已装=最新（界面变「已最新」，更新按钮消失）
	if [ "$mode" = "dir" ]; then
		update_cleanup_backup "$abs_dir"
	else
		update_cleanup_backup "$abs_target"
	fi
	update_set_ins_ver "$name" "$tag"
	update_set_update_ver "$name" "$tag"
	update_log "[$name] $(ui_msg '更新完成：%s' "$tag")"
	return 0
}

# 等待服务起来：$1=名 $2=最多秒数（每 0.5 秒探一次）。
wait_svc_running() {
	local name=$1 limit=${2:-20} i=0
	while [ "$i" -lt "$limit" ]; do
		svc_running "$name" && return 0
		sleep 0.5 2>/dev/null || sleep 1
		i=$((i + 1))
	done
	svc_running "$name" && return 0
	return 1
}

cmd_update() {
	local name=$1 line repo asset target mode svc ins vercmd update_ver known_tag=$2
	[ -n "$name" ] || { update_log "$(ui_msg '未指定更新条目名')"; return 1; }
	line=$(pick_update_entry "$name")
	[ -n "$line" ] || { update_log "$(ui_msg '未找到更新条目：%s' "$name")"; return 1; }
	IFS='|' read -r name repo asset target mode svc ins vercmd update_ver _auto <<UEOF
$line
UEOF
	update_entry "$name" "$repo" "$asset" "$target" "$mode" "$svc" "$ins" "$vercmd" "$known_tag"
}

cmd_updateall() {
	local name rc=0
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		cmd_update "$name" || rc=1
	done <<EOF
$(list_update_names)
EOF
	return "$rc"
}

case "$1" in
check)
	acquire_lock || exit 0
	cmd_check
	release_lock
	;;
update)
	acquire_lock || exit 0
	cmd_update "$2"
	release_lock
	;;
updateall)
	acquire_lock || exit 0
	cmd_updateall
	release_lock
	;;
*)
	echo "usage: updater.sh check | update <name> | updateall" >&2
	exit 1
	;;
esac
exit 0
