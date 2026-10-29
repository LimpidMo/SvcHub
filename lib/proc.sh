# SvcHub 公共库：进程管理（完全基于 pid 文件，杜绝按名模糊匹配）。
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

# 按服务类型启动：$1=kind(termux|binary) $2=名称 $3=命令文本。
# 统一启动收口（巡检/Wi-Fi/WebUI）：termux 默认以完整 Termux 用户身份运行，命中 termux_root_names 名单则
# 不注入 su 参数改以 root 运行（工作目录与 TERMUX_ENV 不变）；cmd 库存字面 \n，执行前还原为真换行。
launch_svc() {
	local cmdtext=$3
	case "$cmdtext" in *\\*) cmdtext=$(printf '%s' "$cmdtext" | dec_js) ;; esac
	case "$1" in
		termux)
			if name_in_set "$2" "$TERMUX_ROOT_NAMES"; then
				start_svc "$2" "$TERMUX_HOME" "" "$TERMUX_ENV $cmdtext"
			else
				start_svc "$2" "$TERMUX_HOME" "$(termux_user_args)" "$TERMUX_ENV $cmdtext"
			fi
			;;
		binary) start_svc "$2" "$SERVER_DIR" "" "$cmdtext" ;;
	esac
}

# 启动服务：$1=名称 $2=工作目录 $3=su 附加参数（binary 恒空） $4=命令文本
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
		# wait 用换行拼接：命令以 & 结尾时 "&; wait" 是语法错误，换行才是两条语句
		setsid "$su_bin" $extra -c "$cmdtext
wait" </dev/null >>"$log" 2>&1 &
		leader=$!
		printf '%s\n' "$leader" > "$pidf"
	) >> "$log" 2>&1 &
	return 0
}

# 按 pid 文件终止：读取首行 pid，先向整个进程组发送 SIGTERM 优雅终止，再 SIGKILL 强杀
kill_by_name() {
	local name=$1 pidf="$RUNDIR/$1.pid" pid
	[ -f "$pidf" ] || return 1
	read -r pid < "$pidf" || { rm -f "$pidf"; return 1; }
	# pid 合法性校验：必须是大于 1 的纯数字，防止 pid 文件损坏
	is_int "$pid" || { rm -f "$pidf"; return 1; }
	[ "$pid" -gt 1 ] || { rm -f "$pidf"; return 1; }

	# 1. SIGTERM 优雅终止：进程组优先，组形式失败补单 pid
	kill -15 -- -"$pid" 2>/dev/null || kill -15 "-$pid" 2>/dev/null || kill -15 "$pid" 2>/dev/null

	# 2. 探活等待：间隔 0.1→0.2→0.3→0.5 递增（上限 2s），进程早死即返回
	local w=1 total=0 i=0
	while kill -0 "$pid" 2>/dev/null; do
		[ $((total + w)) -le 20 ] || break
		sleep "0.${w}"
		total=$((total + w))
		i=$((i + 1))
		case $i in
		1) w=2 ;;
		2) w=3 ;;
		3) w=5 ;;
		4) w=4 ;;
		*) w=5 ;;
		esac
	done

	# 3. 仍存活则 SIGKILL（组优先、单 pid 兜底），再短确认
	if kill -0 "$pid" 2>/dev/null; then
		kill -9 -- -"$pid" 2>/dev/null || kill -9 "-$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null
		sleep 0.2
	fi

	return 0
}

# 停止服务：按 pid 文件终止进程组，清理 pid 文件与该服务日志。
# 未运行直接返回：省两次 rm fork，且不删日志保留排错信息（stop_all 会遍历全部服务）。
stop_svc() {
	local name=$1 pidf="$RUNDIR/$1.pid" w=1 total=0 i=0
	valid_name "$name" || return 0
	# 布尔判定须吞 stdout（pidfile_alive 成功输出 pid）；未运行则它已清掉过期 pid 文件
	pidfile_alive "$pidf" >/dev/null || return 0
	kill_by_name "$name"
	rm -f "$LOG_DIR/$1.log"
	# 探活直至进程消失（防 fork 竞争残留）：短间隔递增，上限 4s
	while svc_running "$name"; do
		[ $((total + w)) -le 40 ] || break
		sleep "0.${w}"
		total=$((total + w))
		i=$((i + 1))
		case $i in
		1) w=2 ;;
		2) w=3 ;;
		3) w=5 ;;
		4) w=4 ;;
		*) w=5 ;;
		esac
	done
	rm -f "$pidf"
	run_end_cmd "$name"
	return 0
}

# 服务停止后执行收尾命令：查服务行末段 end_cmd，整段 dec_js 还原真换行后一次 su -c 执行
# （与启动 cmd 同模型，函数/while/if 多行块合法；非常驻不追加 ; wait），身份与工作目录同 launch_svc。
run_end_cmd() {
	local name=$1 row endcmd="" extra="" su_bin rc
	[ -n "$LOAD_CFG_DONE" ] || load_cfg_sh
	row=$(pick_termux "$name")
	[ -n "$row" ] || row=$(pick_binary "$name")
	[ -n "$row" ] || return 0
	# 取末段：heredoc read 末变量保留原始分隔符（end_cmd 可含 |）
	IFS='|' read -r _ _ _ _ endcmd <<EOF
$row
EOF
	[ -n "$endcmd" ] || return 0
	case "$endcmd" in *\\*) endcmd=$(printf '%s' "$endcmd" | dec_js) ;; esac
	printf '%s\n' "$endcmd" | grep -q '[^[:space:]]' || return 0
	# 非 root 名单的 termux 服务降权至 Termux 用户（binary 与 root 名单服务本就是 root）
	if printf '%s\n' "$row" | grep -q '^termux|' && ! name_in_set "$name" "$TERMUX_ROOT_NAMES"; then
		extra=$(termux_user_args)
	fi
	su_bin=$(get_su_bin) || { echo "[$(date '+%F %T')] $(ui_msg '收尾 %s 跳过：su 不可用' "$name")" >> "$LOG_DIR/stop.log"; return 0; }
	{
		echo "$(ui_msg '=== 执行 %s 收尾命令 %s ===' "$name" "$(date '+%F %T')")"
		if printf '%s\n' "$row" | grep -q '^termux|'; then
			"$su_bin" $extra -c "$TERMUX_ENV cd $TERMUX_HOME; $endcmd" 2>&1
		else
			"$su_bin" -c "cd \"$SERVER_DIR\" 2>/dev/null; $endcmd" 2>&1
		fi
		rc=$?
		echo "[exit=$rc]"
	} >> "$LOG_DIR/stop.log" 2>&1
	return 0
}

# 停止已被删除的服务：单次 awk 比对新旧名单并去重；svc_running/stop_svc 留在 shell（pid 文件与信号）。
stop_removed_services() {
	local old_ts=$1 new_ts=$2 old_sv=$3 new_sv=$4 name inf="$RUNDIR/srs.$$.in" outf="$RUNDIR/srs.$$.out"
	# 新名单经环境变量传入（-v 会吞反斜杠），旧名单落临时文件喂 awk（整段重定向，不起子 shell）
	printf '%s\n%s\n' "$old_ts" "$old_sv" > "$inf"
	NEW_TS=$new_ts NEW_SV=$new_sv awk '
	BEGIN {
		# 新两类名单建集合（经 ENVIRON 读，awk 里直接写变量名是空的）；去重省掉 sort fork
		n = split(ENVIRON["NEW_TS"] "\n" ENVIRON["NEW_SV"], tmp, "\n")
		for (i = 1; i <= n; i++) {
			if (tmp[i] == "") continue
			sub(/\|.*/, "", tmp[i])
			if (tmp[i] != "") innew[tmp[i]] = 1
		}
	}
	{
		if ($0 == "") next
		name = $0
		sub(/\|.*/, "", name)
		if (name == "" || (name in innew) || (name in emitted)) next
		emitted[name] = 1
		print name
	}' "$inf" > "$outf"
	# svc_running/stop_svc 必须留在 shell（涉及 pid 文件与信号）
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		svc_running "$name" && stop_svc "$name"
	done < "$outf"
	rm -f "$inf" "$outf"
}

# 停止全部已配置服务（$1=可选排除名单，熄屏白名单传入；缺省=全停，disable/定时窗调用不变）
stop_all() {
	local ex=$1 name
	[ -n "$LOAD_CFG_DONE" ] || load_services
	printf '%s\n' "$TERMUX_SERVICES" | while IFS='|' read -r name port auto cmd endcmd; do
		[ -n "$name" ] || continue
		[ -n "$ex" ] && name_in_set "$name" "$ex" && continue
		stop_svc "$name"
	done
	printf '%s\n' "$BINARY_SERVICES" | while IFS='|' read -r name port auto cmd endcmd; do
		[ -n "$name" ] || continue
		[ -n "$ex" ] && name_in_set "$name" "$ex" && continue
		stop_svc "$name"
	done
}
