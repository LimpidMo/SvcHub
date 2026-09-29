#!/system/bin/sh
# SvcHub 保活守护：单实例、按 interval 巡检、主 shell 内直接启动/停止、disable 时收尾退出。
MODDIR=${0%/*}
[ -n "$MODDIR" ] && [ -d "$MODDIR" ] || exit 1
. "$MODDIR/lib.sh" 2>/dev/null || exit 1

# 单实例（supervisor 自身防重复）
if old=$(pidfile_alive "$SPPID" 2>/dev/null); then
	sup_log "supervisor 已在运行 (old=$old)，退出"
	exit 0
fi
echo "$$" > "$SPPID"
sup_log "supervisor 启动 pid=$$"

# 分三阶段等待，全部就绪后才进行首次巡检：
# 阶段一（系统启动）：sys.boot_completed=1 且开机动画结束（init.svc.bootanim=stopped）
# 阶段二（用户解锁）：sys.user.0.ce_available=true（FBE 设备首次解锁后 CE 存储才可用，服务目录与 Termux 数据此时才可访问）
# 阶段三（su 就绪）：su 二进制已挂载可用（KernelSU/Magisk/APatch 启动后期才提供）
# 联调跳过：SVCHUB_MOCK=1 时（仅在开发调式沙盒时有效）
wait_boot_stages() {
	local i=0 stage=1 boot_done= anim_done= ce_ready= su_state su_bin
	if [ "$SVCHUB_MOCK" = "1" ]; then
		sup_log "mock 环境，跳过启动等待，直接巡检"
		return 0
	fi
	while [ "$i" -lt 300 ]; do
		if [ "$stage" -eq 1 ]; then
			boot_done=$(getprop sys.boot_completed 2>/dev/null)
			anim_done=$(getprop init.svc.bootanim 2>/dev/null)
			if { [ "$boot_done" = "1" ] || [ "$boot_done" = "true" ]; } &&
				{ [ -z "$anim_done" ] || [ "$anim_done" = "stopped" ]; }; then
				sup_log "系统启动完成"
				stage=2
			fi
		elif [ "$stage" -eq 2 ]; then
			ce_ready=$(getprop sys.user.0.ce_available 2>/dev/null)
			# /data/media/0 是 CE 存储，必须解锁后才能读取；仅判断 -d 不够，需判断可读
			if [ "$ce_ready" = "true" ] || [ -z "$ce_ready" ] || ls /data/media/0 >/dev/null 2>&1; then
				sup_log "设备解锁，服务存储可访问"
				stage=3
			fi
		else
			if su_bin=$(get_su_bin 2>/dev/null); then
				sup_log "su 就绪：$su_bin，开始巡检"
				break
			fi
		fi
		sleep 1
		i=$((i + 1))
	done
	if [ "$i" -ge 300 ]; then
		if get_su_bin >/dev/null 2>&1; then su_state=yes; else su_state=no; fi
		sup_log "等待系统启动/解锁/su 超时(300s)，继续巡检 (boot=$boot_done anim=$anim_done ce=$ce_ready su=$su_state)"
	fi
}

# 巡检启动单类服务：$1=kind(termux|binary) $2=配置行列表 $3=运行中名字集合 $4=仅启名单(空=正常巡检)。
# 名单模式（亮屏白名单恢复轮）：只处理名单内服务且不看 auto 标签（显式名单覆盖），名单外零输出；
# 正常模式：仅 auto=start 且未运行才启动；Wi-Fi 策略兜底统一由 wifi_should_skip 判定
# （定时停止窗已在轮首整轮跳过，此处不再重复判断）。
patrol_start_rows() {
	local kind=$1 rows=$2 runset=$3 allow_names=$4 name port extra auto cmd reason
	# 两类行统一 5 段 name|port|extra|auto|cmd（含 binary 空 extra），read 变量名列表一致
	set -- name port extra auto cmd
	while IFS='|' read -r "$@"; do
		[ -n "$name" ] || continue
		if [ -n "$allow_names" ]; then
			name_in_set "$name" "$allow_names" || continue
		elif [ "$auto" != start ]; then
			sup_log_bare "    跳过 $name"
			continue
		fi
		if wifi_should_skip "$name"; then
			if [ "$WIFI_POLICY" = "block" ]; then
				sup_log_bare "    跳过 $name (WIFI 已断开，连接组不启动)"
			else
				sup_log_bare "    跳过 $name (WIFI 已连接，断开组不启动)"
			fi
			continue
		fi
		# 启动禁令单点判定：亮屏未解锁/熄屏非白名单（定时窗已在轮首整轮跳过）
		if reason=$(starts_blocked_reason "$name"); then
			sup_log_bare "    跳过 $name ($reason)"
			continue
		fi
		if name_in_set "$name" "$runset"; then
			# 名单模式只输出启动动作，已运行静默
			[ -z "$allow_names" ] && sup_log_bare "    已运行 $name"
			continue
		fi
		if launch_svc "$kind" "$name" "${extra:-}" "$cmd"; then
			sleep 0.3
			svc_running "$name" && sup_log_bare "    已启动 $name" || sup_log_bare "    启动未生效 $name（请检查该服务日志/命令）"
		else
			sup_log_bare "    启动失败 $name (服务目录不存在或命令错误)"
		fi
	done <<EOF
$rows
EOF
}

# 单轮巡检：定时停止窗内只做 Wi-Fi 同步的停止分支（禁启由 lib.sh 守卫）；
# 自动巡检禁用时静默跳过周期拉起（零输出）——出停止窗/亮屏解锁的边沿恢复经 PATROL_RESUME 放行一次，
# Wi-Fi 条件启停在 sleep_slice 分片里照常执行，不经此处；
# "巡检开始/完成"头日志在此输出（禁用静默轮不出，避免刷屏）；
# 窗外先算 Wi-Fi 策略并同步（在计算 runset 之前执行，确保新启动的服务能被正确识别为已运行），
# 再按配置巡检启动 auto=start 且未运行的服务。
patrol_once() {
	local runset resume_kind="" resume_allow=""
	# 边沿恢复放行标记（一次性消费）：sched=出停止窗恢复(全量)；screen=亮屏解锁恢复(受亮屏白名单约束)
	case "$PATROL_RESUME" in
	sched) resume_kind=sched ;;
	screen) resume_kind=screen ;;
	esac
	PATROL_RESUME=""
	LOAD_CFG_DONE=""
	load_cfg_sh
	# 亮屏名单必须在 load_cfg_sh 之后读取，避免用到上一分片的旧值
	if [ "$resume_kind" = "screen" ] && [ -n "$SCREEN_RESUME_NAMES" ]; then
		resume_allow=$SCREEN_RESUME_NAMES
	fi
	if [ "$SCHED_IN_WINDOW" = "1" ]; then
		# 窗内日志边沿化：进窗首轮说明一次，窗内期间静默
		if [ -z "$SCHED_LOGGED" ]; then
			SCHED_LOGGED=1
			sup_log "巡检开始 启停功能策略（定时停止窗内 ${SCHEDULE_STOP}~${SCHEDULE_START}），暂停拉起"
		fi
		calc_wifi_policy
		sync_wifi_service_policy "$WIFI_POLICY" on
		sync_wifi_service_policy "$WIFI_POLICY" off
		return 0
	fi
	# 窗外即清窗内已说明标记（下次进窗再说明一次）
	SCHED_LOGGED=""
	# 自动巡检禁用且非边沿恢复轮：静默跳过零输出（httpd 保活/日志轮转/边沿检测照常）
	if [ "$PATROL_ENABLED" != "1" ] && [ -z "$resume_kind" ]; then
		return 0
	fi
	# 边沿恢复轮头部标明"启停功能策略"，避免 interval 让用户误以为周期巡检仍在跑
	if [ -n "$resume_kind" ]; then
		sup_log "巡检开始 启停功能策略"
	else
		sup_log "巡检开始 interval=${SLEEP_INTERVAL}s"
	fi
	calc_wifi_policy
	sync_wifi_service_policy "$WIFI_POLICY" on
	sync_wifi_service_policy "$WIFI_POLICY" off
	runset=$(compute_runset)
	# 亮屏白名单恢复轮：名单非空仅启动名单内服务；空名单=正常巡检恢复
	if [ -n "$resume_allow" ]; then
		sup_log_bare "    亮屏白名单恢复：仅启动名单内服务"
	fi
	sup_log_bare " ------- Termux 服务 ------- "
	patrol_start_rows termux "$TERMUX_SERVICES" "$runset" "$resume_allow"
	sup_log_bare " ------- 二进制服务 ------- "
	patrol_start_rows binary "$BINARY_SERVICES" "$runset" "$resume_allow"
	sup_log "巡检完成"
}

# 巡检后的分片休眠：长间隔拆成 <=60s 的分片，每片后重读配置，实现间隔热更新；
# 防止从 3600s 调回 120s 需等待整个旧周期才能生效。
# 期间实时响应：disable 提前结束、定时窗边沿（进窗停全部/出窗立即巡检）、Wi-Fi 策略变化。
sleep_slice() {
	local elapsed=0 target=$SLEEP_INTERVAL chunk old_target old_policy old_screen old_unlock now_in
	# 入口取当前屏幕/解锁状态，避免开机即锁屏时误触发边沿
	old_screen=$SCREEN_ON
	old_unlock=$SCREEN_UNLOCK_OK
	while [ "$elapsed" -lt "$target" ]; do
		# disable 优先响应，避免睡完整个长周期
		[ -f "$DISABLE_FILE" ] && break

		chunk=$((target - elapsed))
		[ "$chunk" -gt 60 ] && chunk=60
		# 亮屏启停开启时：熄屏（等亮屏边沿）与亮屏锁屏中（等解锁边沿）压到 10s 短分片，以便快速识别到亮屏解锁恢复巡检
		if [ "$SCREEN_SERVICE_ENABLED" = "1" ] && [ "$chunk" -gt 10 ]; then
			if [ "$SCREEN_ON" != "1" ] || [ "$SCREEN_UNLOCK_OK" != "1" ]; then
				chunk=10
			fi
		fi

		sleep "$chunk" || break
		elapsed=$((elapsed + chunk))

		# 每片后重读设置，检查间隔是否被修改（服务行只在轮首读，分片不碰）
		old_target=$target
		LOAD_CFG_DONE=""
		load_cfg_sh
		target=$SLEEP_INTERVAL
		if [ "$target" != "$old_target" ]; then
			sup_log "检查间隔更新为 ${target}s"
		fi

		# 定时停止窗边沿检测（放 Wi-Fi 检查之前：先停后禁启，避免本分片 Wi-Fi 把刚停的拉起）
		# 仅边沿动作 + 写 schedule.log，分片内无变化零输出
		# 关闭状态静默：不警告、不写无效日志；窗内关闭则退出并立即巡检恢复
		if [ "$SCHEDULE_ENABLED" != "1" ]; then
			if [ "$SCHED_IN_WINDOW" = "1" ]; then
				SCHED_IN_WINDOW="0"
				sched_log "定时启停已关闭，恢复巡检"
				PATROL_RESUME=sched
				break
			fi
			SCHED_WARNED=""
		elif [ -n "$SCHEDULE_STOP" ] && [ -n "$SCHEDULE_START" ]; then
			if sched_in_window "$SCHEDULE_STOP" "$SCHEDULE_START" "$(date '+%H:%M')"; then
				now_in=1
			else
				now_in=0
			fi
			if [ "$now_in" != "$SCHED_IN_WINDOW" ]; then
				SCHED_IN_WINDOW="$now_in"
				if [ "$now_in" = "1" ]; then
					stop_all
					sched_log "进入定时停止窗（${SCHEDULE_STOP}~${SCHEDULE_START}），已停止全部服务"
				else
					sched_log "退出定时停止窗（${SCHEDULE_STOP}~${SCHEDULE_START}），立即巡检恢复服务"
					# 出窗立即结束本轮休眠进入巡检：避免 sleep_interval=3600 时恢复延迟一小时
					PATROL_RESUME=sched
					break
				fi
			fi
		elif [ -n "$SCHEDULE_STOP" ] || [ -n "$SCHEDULE_START" ]; then
			# 半配置（时间非法或缺一边，含 stop==start）：视为窗外，仅首次警告一次
			if [ "$SCHED_IN_WINDOW" = "1" ]; then
				SCHED_IN_WINDOW="0"
				sched_log "退出定时停止窗（${SCHEDULE_STOP}~${SCHEDULE_START}），立即巡检恢复服务"
				PATROL_RESUME=sched
				break
			fi
			if [ -z "$SCHED_WARNED" ]; then
				sched_log "定时时间配置无效（stop=${SCHEDULE_STOP} start=${SCHEDULE_START}），已暂停定时启停"
				SCHED_WARNED="1"
			fi
		else
			SCHED_IN_WINDOW="0"
			SCHED_WARNED=""
		fi

		# 屏幕/解锁边沿：亮屏且已解锁才结束休眠进巡检恢复，锁屏中亮屏只等解锁边沿
		refresh_screen_gate
		if [ "$SCREEN_ON" != "$old_screen" ]; then
			old_screen=$SCREEN_ON
			# 同步解锁态：熄屏期间 SCREEN_UNLOCK_OK 恒 1，不同步会掩盖随后的 0→1 解锁边沿
			old_unlock=$SCREEN_UNLOCK_OK
			if [ "$SCREEN_ON" = "1" ]; then
				if [ "$SCREEN_UNLOCK_OK" = "1" ]; then
					if [ "$SCHED_IN_WINDOW" = "1" ]; then
						# 定时窗优先级高于亮屏恢复：窗内不恢复，日志如实说明
						screen_log "亮屏且已解锁，定时停止窗内，暂停拉起"
					else
						screen_log "亮屏且已解锁，立即巡检恢复服务"
						PATROL_RESUME=screen
						break
					fi
				else
					screen_log "亮屏（锁屏中，待解锁后恢复）"
				fi
			else
				stop_all "$SCREEN_SERVICE_NAMES"
				screen_log "进入熄屏，停止非白名单服务"
			fi
		elif [ "$SCREEN_ON" = "1" ] && [ "$SCREEN_UNLOCK_OK" != "$old_unlock" ]; then
			old_unlock=$SCREEN_UNLOCK_OK
			if [ "$SCREEN_UNLOCK_OK" = "1" ]; then
				if [ "$SCHED_IN_WINDOW" = "1" ]; then
					screen_log "亮屏已解锁，定时停止窗内，暂停拉起"
				else
					screen_log "亮屏已解锁，立即巡检恢复服务"
					PATROL_RESUME=screen
					break
				fi
			else
				screen_log "亮屏又进入锁屏（不拉起，运行中服务保留）"
			fi
		fi

		# Wi-Fi 策略变化检测与同步（在分片休眠中实时响应网络变化，无需等待下一个完整巡检周期）
		# 窗内 sync 的 do_start 分支已被 SCHED_IN_WINDOW 守卫禁启（见 lib.sh），只执行停止分支
		old_policy=$WIFI_POLICY
		calc_wifi_policy
		if [ "$WIFI_POLICY" != "$old_policy" ]; then
			sync_wifi_service_policy "$WIFI_POLICY" on
			sync_wifi_service_policy "$WIFI_POLICY" off
		fi

		# 外部访问保活：启用且有密码、httpd 未运行则拉起（被杀/异常退出 60 秒内恢复）
		if [ "$WEBUI_ENABLED" = "1" ] && [ -n "$WEBUI_PASSWORD_HASH" ] && ! svc_running httpd; then
			sh "$MODDIR/httpd.sh" start >/dev/null 2>&1 && \
				webui_log "httpd 保活拉起（分片巡检）" || \
				webui_log "httpd 保活拉起失败，见 webui.log"
		fi

		# 新间隔已到或已过，立即结束本轮休眠进入巡检
		[ "$elapsed" -ge "$target" ] && break
	done
}

wait_boot_stages

# 首轮加载一次配置
load_cfg_sh

# 定时停止窗首轮判定：重启落在窗内直接守住，巡检不拉起（无需持久化名单）
SCHED_IN_WINDOW="0"
SCHED_WARNED=""
# 窗内已说明标记：进窗首轮在 supervisor.log 说明一次，窗内期间静默
SCHED_LOGGED=""
# 边沿恢复放行标记：出停止窗(sched)/亮屏解锁(screen)的立即巡检不受自动巡检禁用影响
PATROL_RESUME=""
if [ "$SCHEDULE_ENABLED" = "1" ] && [ -n "$SCHEDULE_STOP" ] && [ -n "$SCHEDULE_START" ]; then
	if sched_in_window "$SCHEDULE_STOP" "$SCHEDULE_START" "$(date '+%H:%M')"; then
		SCHED_IN_WINDOW="1"
		sched_log "supervisor 启动时已在定时停止窗内（${SCHEDULE_STOP}~${SCHEDULE_START}），暂停拉起"
	fi
fi

# 屏幕/解锁门控首轮判定：开机即熄屏或锁屏则本轮巡检不拉起非白名单服务
# （此时无受管服务在跑，不需 stop_all）
refresh_screen_gate
if [ "$SCREEN_ON" != "1" ]; then
	screen_log "启动时熄屏，暂停非白名单拉起"
elif [ "$SCREEN_UNLOCK_OK" != "1" ]; then
	screen_log "启动时亮屏未解锁（锁屏中），暂停拉起"
fi

while :; do
	if [ -f "$DISABLE_FILE" ]; then
		sup_log "检测到 disable，停止全部受管服务"
		stop_all
		sh "$MODDIR/httpd.sh" stop >/dev/null 2>&1
		rm -f "$SPPID"
		exit 0
	fi

	patrol_once
	rotate_all_logs

	sleep_slice
done
