#!/system/bin/sh
# SvcHub 保活守护：单实例、按 interval 巡检、主 shell 内直接启动/停止、disable 时收尾退出。
MODDIR=${0%/*}
[ -n "$MODDIR" ] && [ -d "$MODDIR" ] || exit 1
. "$MODDIR/bin/lib.sh" 2>/dev/null || exit 1

mkdir -p "$LOG_DIR"

# 单实例（supervisor 自身防重复）
if [ -f "$SPPID" ]; then
    old=$(awk '{print $1}' "$SPPID" 2>/dev/null)
    if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
        echo "$(date '+%F %T') supervisor 已在运行 (old=$old)，退出" >> "$SUPERLOG"
        exit 0
    fi
    rm -f "$SPPID"
fi

echo "$$" > "$SPPID"
echo "$(date '+%F %T') supervisor 启动 pid=$$" >> "$SUPERLOG"
rotate_log "$SUPERLOG" 262144

# 分三阶段等待并分开记录日志，全部就绪后才进行首次巡检：
# 阶段一（系统启动）：sys.boot_completed=1 且开机动画结束（init.svc.bootanim=stopped）
# 阶段二（用户解锁）：sys.user.0.ce_available=true（FBE 设备首次解锁后 CE 存储才可用，服务目录与 Termux 数据此时才可访问）
# 阶段三（su 就绪）：su 二进制已挂载可用（KernelSU/Magisk/APatch 启动后期才提供）
i=0
stage=1
boot_done=; anim_done=; ce_ready=
while [ "$i" -lt 300 ]; do
    if [ "$stage" -eq 1 ]; then
        boot_done=$(getprop sys.boot_completed 2>/dev/null)
        anim_done=$(getprop init.svc.bootanim 2>/dev/null)
        if [ "$boot_done" = "1" ] && [ "$anim_done" = "stopped" ]; then
            echo "$(date '+%F %T') 系统启动完成" >> "$SUPERLOG"
            stage=2
        fi
    elif [ "$stage" -eq 2 ]; then
        ce_ready=$(getprop sys.user.0.ce_available 2>/dev/null)
        if [ "$ce_ready" = "true" ]; then
            echo "$(date '+%F %T') 设备解锁，服务目录可访问" >> "$SUPERLOG"
            stage=3
        fi
    else
        if su_ready; then
            echo "$(date '+%F %T') su 就绪，开始巡检" >> "$SUPERLOG"
            break
        fi
    fi
    sleep 1
    i=$((i + 1))
done
if [ "$i" -ge 300 ]; then
    su_ready && su_state=yes || su_state=no
    echo "$(date '+%F %T') 等待系统启动/解锁/su 超时(300s)，继续巡检 (boot=$boot_done anim=$anim_done ce=$ce_ready su=$su_state)" >> "$SUPERLOG"
fi
#sleep 30
while :; do
    if [ -f "$DISABLE_FILE" ]; then
        echo "$(date '+%F %T') 检测到 disable，停止全部受管服务" >> "$SUPERLOG"
        stop_all
        rm -f "$SPPID"
        exit 0
    fi

    load_cfg_sh

    echo "[$(date '+%F %T')] 巡检开始 interval=${SLEEP_INTERVAL}s" >> "$SUPERLOG"

    # 本轮一次性批量检测运行中的名字，供下方启动/停止分支共用（与 action.sh status 同源同语义）
    runset=$(
        {
            printf '%s\n' "$TERMUX_SERVICES" | list_names
            printf '%s\n' "$SERVICES" | list_names
        } | detect_running
    )

    # 巡检启动：auto=start 且 name 对应程序未运行才启动（使用 heredoc，主 shell 内执行）
    name=; port=; extra=; auto=; cmd=
    while IFS='|' read -r name port extra auto cmd; do
        [ -n "$name" ] || continue
        if [ "$auto" != start ]; then
            echo "    跳过 $name (auto=$auto)" >> "$SUPERLOG"
            continue
        fi
        if name_in_set "$name" "$runset"; then
            echo "    已运行 $name" >> "$SUPERLOG"
            continue
        fi
        if start_svc "$name" "$TERMUX_HOME" "$extra" "$TERMUX_ENV $cmd"; then
            sleep 0.3
            svc_running "$name" && echo "    已启动 $name" >> "$SUPERLOG" || echo "    启动未生效 $name（请检查该服务日志/命令）" >> "$SUPERLOG"
        else
            echo "    启动失败 $name (目录不存在或命令错误)" >> "$SUPERLOG"
        fi
    done <<EOF
$TERMUX_SERVICES
EOF

    name=; port=; auto=; cmd=
    while IFS='|' read -r name port auto cmd; do
        [ -n "$name" ] || continue
        if [ "$auto" != start ]; then
            echo "    跳过 $name (auto=$auto)" >> "$SUPERLOG"
            continue
        fi
        if name_in_set "$name" "$runset"; then
            echo "    已运行 $name" >> "$SUPERLOG"
            continue
        fi
        if start_svc "$name" "$SERVER_DIR" "" "$cmd"; then
            sleep 0.3
            svc_running "$name" && echo "    已启动 $name" >> "$SUPERLOG" || echo "    启动未生效 $name（请检查该服务日志/命令）" >> "$SUPERLOG"
        else
            echo "    启动失败 $name (服务目录不存在或命令错误)" >> "$SUPERLOG"
        fi
    done <<EOF
$SERVICES
EOF

    echo "[$(date '+%F %T')] 巡检完成" >> "$SUPERLOG"
    rotate_log "$SUPERLOG" 262144
    sleep "$SLEEP_INTERVAL"
done