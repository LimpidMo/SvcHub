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
chooseport() {
    local DELAY=${1:-5}
    local error=false
    local count=0
    local GETEVENT=""

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

    while true; do
        count=0
        while true; do
            timeout "$DELAY" $GETEVENT -lqc 1 > "$TMPDIR/_vk" 2>/dev/null
            if grep -q 'KEY_VOLUMEUP.*DOWN' "$TMPDIR/_vk" 2>/dev/null; then
                rm -f "$TMPDIR/_vk"
                return 0
            elif grep -q 'KEY_VOLUMEDOWN.*DOWN' "$TMPDIR/_vk" 2>/dev/null; then
                rm -f "$TMPDIR/_vk"
                return 1
            fi
            count=$((count + 1))
            [ $count -gt 10 ] && break
        done

        if $error; then
            rm -f "$TMPDIR/_vk"
            return 2
        else
            error=true
            ui_print "  ! 未检测到按键，请重试..."
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
    ui_print "! 无法识别 root 方案，继续安装"
fi

# ==================== 升级时保留配置 ====================
MODID=${MODID:-$(basename "${MODPATH:-}")}
if [ -n "$MODID" ]; then
    OLD_CFG="/data/adb/modules/$MODID/config.json"
    if [ -f "$OLD_CFG" ]; then
        cp -f "$OLD_CFG" "$MODPATH/config.json" 2>/dev/null \
            && ui_print "- 已保留配置 config.json" \
            || ui_print "! 配置 config.json 保留失败，将使用默认配置"
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

# ==================== Termux 检测 ====================
if [ ! -d /data/data/com.termux/files/home ]; then
    ui_print "! 未检测到 Termux（/data/data/com.termux/files/home）"
    ui_print "! Termux 服务功能不可用；自定义二进制服务与 WebUI 不受影响"
fi

# ==================== 模块结束 ====================
ui_print " "
ui_print "- 安装完成，重启后生效"

