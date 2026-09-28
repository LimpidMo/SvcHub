#!/system/bin/sh
# 模块安装入口（KernelSU / Magisk / APatch 通用）

ASH_STANDALONE=1
export ASH_STANDALONE

# ==================== 从 module.prop 读取元信息 ====================
read_prop() {
    sed -n "s/^$1[[:space:]]*=[[:space:]]*//p" "$MODPATH/module.prop" 2>/dev/null | head -n 1
}

NAME=$(read_prop name)
VER=$(read_prop version)
DESC=$(read_prop description)

[ -n "$NAME" ] || NAME="Module"
[ -n "$VER" ]  || VER="?"

ui_print "+ 正在安装 ${NAME} v${VER}"
[ -n "$DESC" ] && ui_print "  $DESC"

# ==================== 音量键选择函数 ====================
# 返回 0 = 音量上(VOL+)， 1 = 音量下(VOL-)， 2 = 超时或失败
# 总时长收敛：按 deadline 耗满 DELAY 即返回，不做第二轮重试
chooseport() {
    local DELAY=${1:-10}
    local GETEVENT=""
    local vk_file deadline now remaining chunk rc

    [ "$DELAY" -gt 0 ] 2>/dev/null || DELAY=10

    # 依次探测可用的 getevent
    if [ -x /system/bin/getevent ]; then
        GETEVENT="/system/bin/getevent"
    elif command -v getevent >/dev/null 2>&1; then
        GETEVENT="getevent"
    elif [ -x /data/adb/ksu/bin/busybox ]; then
        GETEVENT="/data/adb/ksu/bin/busybox getevent"
    elif [ -x /data/adb/magisk/busybox ]; then
        GETEVENT="/data/adb/magisk/busybox getevent"
    else
        return 2
    fi
    command -v timeout >/dev/null 2>&1 || return 2

    vk_file="${TMPDIR:-/dev/tmp}/_vk"
    deadline=$(date +%s 2>/dev/null) || return 2
    deadline=$((deadline + DELAY))

    while :; do
        now=$(date +%s 2>/dev/null) || { rm -f "$vk_file"; return 2; }
        remaining=$((deadline - now))
        [ "$remaining" -le 0 ] && { rm -f "$vk_file"; return 2; }
        # 短轮询：按键最多延迟一个 chunk 即被捕获，无按键时耗满剩余时间即判超时
        chunk=$remaining
        [ "$chunk" -gt 2 ] && chunk=2
        timeout "$chunk" $GETEVENT -lqc 1 > "$vk_file" 2>/dev/null
        rc=$?
        if grep -q 'KEY_VOLUMEUP.*DOWN' "$vk_file" 2>/dev/null; then
            rm -f "$vk_file"
            return 0
        elif grep -q 'KEY_VOLUMEDOWN.*DOWN' "$vk_file" 2>/dev/null; then
            rm -f "$vk_file"
            return 1
        fi
        # 非超时类异常(缺二进制等)短暂歇一下再继续，仍受总超时约束
        if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && [ "$rc" -ne 142 ]; then
            sleep 1 2>/dev/null
        fi
    done
}

# ==================== 检测 root 方案 ====================
if [ "${KSU:-}" = "true" ]; then
    ui_print "- 检测到 KernelSU"
elif [ "${APATCH:-}" = "true" ]; then
    ui_print "- 检测到 APatch"
elif [ "${MAGISK:-}" = "true" ] || [ -d /data/adb/magisk ]; then
    ui_print "- 检测到 Magisk"
    ui_print "! Magisk 可能不支持模块 WebUI，请使用 KsuWebUI 管理"
else
    ui_print "! 未识别当前 root 方案，继续安装"
fi

# ==================== 升级时保留配置 ====================
# config/ 三文件保留；Token 长期会话文件（run/session/tsess_*）保留，未过期重装不断登。
MODID=${MODID:-$(basename "${MODPATH:-}")}
if [ -n "$MODID" ]; then
    OLD_MOD="/data/adb/modules/$MODID"
    if [ -f "$OLD_MOD/config/setting.conf" ] || [ -f "$OLD_MOD/config/services.conf" ]; then
        mkdir -p "$MODPATH/config" 2>/dev/null
        for cf in setting.conf services.conf web.conf; do
            [ -f "$OLD_MOD/config/$cf" ] || continue
            cp -f "$OLD_MOD/config/$cf" "$MODPATH/config/$cf" 2>/dev/null \
                && ui_print "- 已保留配置 config/$cf" \
                || ui_print "! 配置 config/$cf 保留失败，将使用默认配置"
        done
    fi
    if [ -d "$OLD_MOD/run/session" ]; then
        mkdir -p "$MODPATH/run/session" 2>/dev/null
        for sf in "$OLD_MOD"/run/session/tsess_*; do
            [ -f "$sf" ] || continue
            cp -f "$sf" "$MODPATH/run/session/" 2>/dev/null
        done
        if ls "$MODPATH"/run/session/tsess_* >/dev/null 2>&1; then
            ui_print "- 已保留长期登录会话（Token 未过期不断登）"
        fi
    fi
fi

# ==================== 音量键选择是否挂载 DNS ====================
RESOLV_PATH="$MODPATH/system/etc/resolv.conf"
SKIP_MARK="$MODPATH/skip_mount"
DNS_MOUNT=false

if [ -f "$RESOLV_PATH" ]; then
    ui_print " "
    ui_print "****************************"
    ui_print "  是否挂载 DNS 配置,用于解决一些服务需要的域名解析问题？"
    ui_print "  (覆盖 /system/etc/resolv.conf)"
    ui_print "  音量 +  =  挂载（启用）"
    ui_print "  音量 -  =  不挂载（跳过）"
    ui_print "****************************"
    ui_print "  请在 10 秒内按下音量键，超时则跳过不挂载..."

    chooseport 10
    RC=$?
    if [ $RC -eq 0 ]; then
        ui_print "- 已选择: 挂载 DNS 配置"
        DNS_MOUNT=true
    elif [ $RC -eq 1 ]; then
        ui_print "- 已选择: 不挂载 DNS 配置"
        DNS_MOUNT=false
    else
        ui_print "! 音量键不可用或超时，默认不挂载"
        DNS_MOUNT=false
    fi
else
    ui_print "- 模块内无 resolv.conf，跳过 DNS 选择"
fi

# ==================== 根据 skip_mount 方案处理 ====================
if [ "$DNS_MOUNT" = "true" ]; then
    # 挂载：确保标记文件不存在
    # （升级场景下旧模块可能残留 skip_mount，必须清除）
    if [ -f "$SKIP_MARK" ]; then
        rm -f "$SKIP_MARK" && ui_print "- 已清除旧 skip_mount 标记"
    fi
    ui_print "- resolv.conf 将在重启后挂载到 /system/etc/"
else
    # 不挂载：创建标记文件，整个模块的 /system 均不挂载
    touch "$SKIP_MARK" \
        && ui_print "- 已创建 skip_mount，重启后不挂载 DNS 配置" \
        || ui_print "! skip_mount 创建失败，DNS 配置将被挂载"
fi
ui_print " "
if [ "$DNS_MOUNT" = "false" ]; then
    ui_print "- 后期若需挂载DNS配置，手动删除模块文件夹内skip_mount文件或执行:"
    ui_print "  rm /data/adb/modules/${MODID}/skip_mount 后重启即可"
fi

# 可执行位修复（zip 解压可能丢 exec 位，无位则 CGI 404 / 后端 127）。
chmod 755 "$MODPATH/action.sh" "$MODPATH/service.sh" "$MODPATH/supervisor.sh" \
    "$MODPATH/httpd.sh" "$MODPATH/uninstall.sh" "$MODPATH/customize.sh" \
    "$MODPATH/webroot/cgi-bin/api.cgi" 2>/dev/null \
    && ui_print "- 已修复脚本可执行权限" \
    || ui_print "! 可执行权限修复失败，外部访问 CGI 可能 404"

# ==================== Termux 检测 ====================
if [ ! -d /data/data/com.termux/files/home ]; then
    ui_print "! 未检测到 Termux（/data/data/com.termux/files/home）"
    ui_print "! Termux 服务功能不可用；自定义二进制服务与 WebUI 不受影响"
fi

# ==================== 模块结束 ====================
ui_print " "
ui_print "- 安装完成，重启后生效"

