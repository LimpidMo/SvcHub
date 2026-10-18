#!/system/bin/sh
# 模块安装入口（KernelSU / Magisk / APatch 通用）

ASH_STANDALONE=1
export ASH_STANDALONE

# ==================== 安装期语言选择 ====================
# 安装期 lib.sh 尚未就位（config/ 还没落盘），用独立的最小文案表；
# 选中的语言写入 setting.conf 的 language 键，与运行时后端 i18n 同一配置项。
INSTALL_LANG="zh"

# 安装期文案：$1=键 其余参数按位代入；中文为默认直出（零回归），英文查表，漏项回中文
inst_msg() {
    _im_tpl=$1
    shift
    # 非英文（含未设/非法值）走中文直出：中文零回归
    case "$INSTALL_LANG" in
    en) ;;
    *) _im_out=$(ui_fill "$_im_tpl" "$@"); printf '%s' "$_im_out"; return 0 ;;
    esac
    case "$_im_tpl" in
    '+ 正在安装 / Installing %s v%s') _im_out=$(printf '%s%s' '+ ' "$(printf 'Installing %s v%s' "$1" "$2")") ;;
    '检测到 KernelSU') _im_out=$(printf 'KernelSU detected') ;;
    '检测到 APatch') _im_out=$(printf 'APatch detected') ;;
    '检测到 Magisk') _im_out=$(printf 'Magisk detected') ;;
    '! Magisk 可能不支持模块 WebUI，请使用 KsuWebUI 管理') _im_out=$(printf '%s%s' '! ' "$(printf 'Magisk may not support module WebUI, use KsuWebUI instead')") ;;
    '! 未识别当前 root 方案，继续安装') _im_out=$(printf '%s%s' '! ' "$(printf 'Root solution not identified, continuing install')") ;;
    '- 已保留配置 config/%s') _im_out=$(printf '%s%s' '- ' "$(printf 'Kept config config/%s' "$1")") ;;
    '! 配置 config/%s 保留失败，将使用默认配置') _im_out=$(printf '%s%s' '! ' "$(printf 'Failed to keep config/%s, defaults will be used' "$1")") ;;
    '- 已保留长期登录会话（Token 未过期不断登）') _im_out=$(printf '%s%s' '- ' "$(printf 'Kept long-term login sessions (unexpired Token stays signed in)')") ;;
    '  是否挂载 DNS 配置,用于解决一些服务需要的域名解析问题？') _im_out=$(printf '  Mount DNS config to fix domain resolution for some services?') ;;
    '  (覆盖 /system/etc/resolv.conf)') _im_out=$(printf '  (overrides /system/etc/resolv.conf)') ;;
    '  音量 +  =  挂载（启用）') _im_out=$(printf '  VOL +  =  Mount (enable)') ;;
    '  音量 -  =  不挂载（跳过）') _im_out=$(printf '  VOL -  =  Skip (do not mount)') ;;
    '  请在 %s 秒内按下音量键，超时则跳过不挂载...') _im_out=$(printf '  Press a volume key within %s seconds; timeout skips mounting...' "$1") ;;
    '- 已选择: 挂载 DNS 配置') _im_out=$(printf '%s%s' '- ' "$(printf 'Selected: mount DNS config')") ;;
    '- 已选择: 不挂载 DNS 配置') _im_out=$(printf '%s%s' '- ' "$(printf 'Selected: do not mount DNS config')") ;;
    '! 音量键不可用或超时，默认不挂载') _im_out=$(printf '%s%s' '! ' "$(printf 'Volume keys unavailable or timed out, skipping mount by default')") ;;
    '- 模块内无 resolv.conf，跳过 DNS 选择') _im_out=$(printf '%s%s' '- ' "$(printf 'No resolv.conf in module, skipping DNS choice')") ;;
    '- 已清除旧 skip_mount 标记') _im_out=$(printf '%s%s' '- ' "$(printf 'Cleared stale skip_mount flag')") ;;
    '- resolv.conf 将在重启后挂载到 /system/etc/') _im_out=$(printf '%s%s' '- ' "$(printf 'resolv.conf will be mounted to /system/etc/ after reboot')") ;;
    '- 已创建 skip_mount，重启后不挂载 DNS 配置') _im_out=$(printf '%s%s' '- ' "$(printf 'Created skip_mount, DNS config will not be mounted after reboot')") ;;
    '! skip_mount 创建失败，DNS 配置将被挂载') _im_out=$(printf '%s%s' '! ' "$(printf 'Failed to create skip_mount, DNS config will be mounted')") ;;
    '- 后期若需挂载DNS配置，手动删除模块文件夹内skip_mount文件或执行:') _im_out=$(printf '%s%s' '- ' "$(printf 'To mount DNS later, delete the skip_mount file in the module folder or run:')") ;;
    '  rm /data/adb/modules/%s/skip_mount 后重启即可') _im_out=$(printf '  rm /data/adb/modules/%s/skip_mount then reboot' "$1") ;;
    '- 已修复脚本可执行权限') _im_out=$(printf '%s%s' '- ' "$(printf 'Fixed script executable permissions')") ;;
    '! 可执行权限修复失败，外部访问 CGI 可能 404') _im_out=$(printf '%s%s' '! ' "$(printf 'Failed to fix executable permissions, web access CGI may 404')") ;;
    '! 未检测到 Termux（/data/data/com.termux/files/home）') _im_out=$(printf '%s%s' '! ' "$(printf 'Termux not detected (/data/data/com.termux/files/home)')") ;;
    '! Termux 服务功能不可用；自定义二进制服务与 WebUI 不受影响') _im_out=$(printf '%s%s' '! ' "$(printf 'Termux services unavailable; custom binary services and WebUI are unaffected')") ;;
    '- 安装完成，重启后生效') _im_out=$(printf '%s%s' '- ' "$(printf 'Install complete, takes effect after reboot')") ;;
    '  请选择界面语言 / Choose interface language:') _im_out=$(printf '  Choose interface language:') ;;
    '  音量 +  =  中文（默认）') _im_out=$(printf '  VOL +  =  Chinese (default)') ;;
    '  音量 -  =  English') _im_out=$(printf '  VOL -  =  English') ;;
    '  请在 %s 秒内按下音量键，超时默认中文... ') _im_out=$(printf '  Press a volume key within %s seconds; timeout defaults to Chinese...' "$1") ;;
    '- 已选择语言: 中文') _im_out=$(printf '%s%s' '- ' "$(printf 'Language selected: Chinese')") ;;
    '- 已选择语言: English') _im_out=$(printf '%s%s' '- ' "$(printf 'Language selected: English')") ;;
    '! 音量键不可用或超时，默认中文') _im_out=$(printf '%s%s' '! ' "$(printf 'Volume keys unavailable or timed out, defaulting to Chinese')") ;;
    '- 沿用已保存的语言设置: 中文') _im_out=$(printf '%s%s' '- ' "$(printf 'Kept saved language: Chinese')") ;;
    '- 沿用已保存的语言设置: English') _im_out=$(printf '%s%s' '- ' "$(printf 'Kept saved language: English')") ;;
    *) _im_out=$(ui_fill "$_im_tpl" "$@") ;;
    esac
    printf '%s' "$_im_out"
}

# 安装期专用的按位代入（与 lib.sh 的 ui_fill 同实现；此处 lib.sh 未就位）
ui_fill() {
    [ "$#" -gt 1 ] || { printf '%s' "$1"; return 0; }
    printf '%s\n' "$1" | awk -v a="$2" -v b="${3-}" -v c="${4-}" -v d="${5-}" '{
        sub(/%s/, a); sub(/%s/, b); sub(/%s/, c); sub(/%s/, d); print }'
}

# ==================== 从 module.prop 读取元信息 ====================
read_prop() {
    sed -n "s/^$1[[:space:]]*=[[:space:]]*//p" "$MODPATH/module.prop" 2>/dev/null | head -n 1
}

NAME=$(read_prop name)
VER=$(read_prop version)
DESC=$(read_prop description)

[ -n "$NAME" ] || NAME="Module"
[ -n "$VER" ]  || VER="?"

ui_print "$(inst_msg '+ 正在安装 / Installing %s v%s' "$NAME" "$VER")"
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
    ui_print "$(inst_msg '检测到 KernelSU')"
elif [ "${APATCH:-}" = "true" ]; then
    ui_print "$(inst_msg '检测到 APatch')"
elif [ "${MAGISK:-}" = "true" ] || [ -d /data/adb/magisk ]; then
    ui_print "$(inst_msg '检测到 Magisk')"
    ui_print "$(inst_msg '! Magisk 可能不支持模块 WebUI，请使用 KsuWebUI 管理')"
else
    ui_print "$(inst_msg '! 未识别当前 root 方案，继续安装')"
fi

# ==================== 升级时保留配置 ====================
# config/ 三文件保留；Token 长期会话文件（run/session/tsess_*）保留，未过期重装不断登。
MODID=${MODID:-$(basename "${MODPATH:-}")}
OLD_UI_LANG=""
if [ -n "$MODID" ]; then
    OLD_MOD="/data/adb/modules/$MODID"
    if [ -f "$OLD_MOD/config/setting.conf" ] || [ -f "$OLD_MOD/config/services.conf" ]; then
        mkdir -p "$MODPATH/config" 2>/dev/null
        for cf in setting.conf services.conf web.conf; do
            [ -f "$OLD_MOD/config/$cf" ] || continue
            cp -f "$OLD_MOD/config/$cf" "$MODPATH/config/" 2>/dev/null \
                && ui_print "$(inst_msg '- 已保留配置 config/%s' "$cf")" \
                || ui_print "$(inst_msg '! 配置 config/%s 保留失败，将使用默认配置' "$cf")"
        done
        # 升级沿用旧语言：不重复询问，安装期输出按旧语言走
        OLD_UI_LANG=$(sed -n 's/^[[:space:]]*language[[:space:]]*=[[:space:]]*//p' "$MODPATH/config/setting.conf" 2>/dev/null | head -n 1 | tr -d '\r')
        case "$OLD_UI_LANG" in
        en|zh) INSTALL_LANG=$OLD_UI_LANG ;;
        esac
    fi
    if [ -d "$OLD_MOD/run/session" ]; then
        mkdir -p "$MODPATH/run/session" 2>/dev/null
        for sf in "$OLD_MOD"/run/session/tsess_*; do
            [ -f "$sf" ] || continue
            cp -f "$sf" "$MODPATH/run/session/" 2>/dev/null
        done
        if ls "$MODPATH"/run/session/tsess_* >/dev/null 2>&1; then
            ui_print "$(inst_msg '- 已保留长期登录会话（Token 未过期不断登）')"
        fi
    fi
fi

# ==================== 音量键选择界面语言 ====================
# 放在 DNS 选择之前：语言是全局基调，先定它；超时 5 秒默认中文（与 DNS 选择同范式）
if [ -n "$OLD_UI_LANG" ]; then
    # 升级：沿用旧设置，不打扰用户
    if [ "$INSTALL_LANG" = "en" ]; then
        ui_print "$(inst_msg '- 沿用已保存的语言设置: English')"
    else
        ui_print "$(inst_msg '- 沿用已保存的语言设置: 中文')"
    fi
else
    ui_print " "
    ui_print "****************************"
    ui_print "$(inst_msg '  请选择界面语言 / Choose interface language:')"
    ui_print "$(inst_msg '  音量 +  =  中文（默认）')"
    ui_print "$(inst_msg '  音量 -  =  English')"
    ui_print "****************************"
    ui_print "$(inst_msg '  请在 %s 秒内按下音量键，超时默认中文...' 5)"

    chooseport 5
    RC=$?
    if [ $RC -eq 1 ]; then
        INSTALL_LANG=en
        ui_print "$(inst_msg '- 已选择语言: English')"
    elif [ $RC -eq 0 ]; then
        INSTALL_LANG=zh
        ui_print "$(inst_msg '- 已选择语言: 中文')"
    else
        INSTALL_LANG=zh
        ui_print "$(inst_msg '! 音量键不可用或超时，默认中文')"
    fi

    # 落盘 language 键；不用 sed -i（toybox/busybox 均不支持），临时文件 + mv 原子替换
    SETF="$MODPATH/config/setting.conf"
    mkdir -p "$MODPATH/config" 2>/dev/null
    if [ -f "$SETF" ]; then
        grep -v '^[[:space:]]*language[[:space:]]*=' "$SETF" > "$SETF.tmp" 2>/dev/null || true
        printf 'language=%s\n' "$INSTALL_LANG" >> "$SETF.tmp" 2>/dev/null
        mv -f "$SETF.tmp" "$SETF" 2>/dev/null
        chmod 600 "$SETF" 2>/dev/null
    else
        printf 'language=%s\n' "$INSTALL_LANG" > "$SETF" 2>/dev/null
        chmod 600 "$SETF" 2>/dev/null
    fi
fi

# ==================== 音量键选择是否挂载 DNS ====================
RESOLV_PATH="$MODPATH/system/etc/resolv.conf"
SKIP_MARK="$MODPATH/skip_mount"
DNS_MOUNT=false

if [ -f "$RESOLV_PATH" ]; then
    ui_print " "
    ui_print "****************************"
    ui_print "$(inst_msg '  是否挂载 DNS 配置,用于解决一些服务需要的域名解析问题？')"
    ui_print "$(inst_msg '  (覆盖 /system/etc/resolv.conf)')"
    ui_print "$(inst_msg '  音量 +  =  挂载（启用）')"
    ui_print "$(inst_msg '  音量 -  =  不挂载（跳过）')"
    ui_print "****************************"
    ui_print "$(inst_msg '  请在 %s 秒内按下音量键，超时则跳过不挂载...' 10)"

    chooseport 10
    RC=$?
    if [ $RC -eq 0 ]; then
        ui_print "$(inst_msg '- 已选择: 挂载 DNS 配置')"
        DNS_MOUNT=true
    elif [ $RC -eq 1 ]; then
        ui_print "$(inst_msg '- 已选择: 不挂载 DNS 配置')"
        DNS_MOUNT=false
    else
        ui_print "$(inst_msg '! 音量键不可用或超时，默认不挂载')"
        DNS_MOUNT=false
    fi
else
    ui_print "$(inst_msg '- 模块内无 resolv.conf，跳过 DNS 选择')"
fi

# ==================== 根据 skip_mount 方案处理 ====================
if [ "$DNS_MOUNT" = "true" ]; then
    # 挂载：确保标记文件不存在
    # （升级场景下旧模块可能残留 skip_mount，必须清除）
    if [ -f "$SKIP_MARK" ]; then
        rm -f "$SKIP_MARK" && ui_print "$(inst_msg '- 已清除旧 skip_mount 标记')"
    fi
    ui_print "$(inst_msg '- resolv.conf 将在重启后挂载到 /system/etc/')"
else
    # 不挂载：创建标记文件，整个模块的 /system 均不挂载
    touch "$SKIP_MARK" \
        && ui_print "$(inst_msg '- 已创建 skip_mount，重启后不挂载 DNS 配置')" \
        || ui_print "$(inst_msg '! skip_mount 创建失败，DNS 配置将被挂载')"
fi
ui_print " "
if [ "$DNS_MOUNT" = "false" ]; then
    ui_print "$(inst_msg '- 后期若需挂载DNS配置，手动删除模块文件夹内skip_mount文件或执行:')"
    ui_print "$(inst_msg '  rm /data/adb/modules/%s/skip_mount 后重启即可' "$MODID")"
fi

# 可执行位修复（zip 解压可能丢 exec 位，无位则 CGI 404 / 后端 127）。
chmod 755 "$MODPATH/action.sh" "$MODPATH/service.sh" "$MODPATH/supervisor.sh" \
    "$MODPATH/httpd.sh" "$MODPATH/uninstall.sh" "$MODPATH/customize.sh" \
    "$MODPATH/webroot/cgi-bin/api.cgi" 2>/dev/null \
    && ui_print "$(inst_msg '- 已修复脚本可执行权限')" \
    || ui_print "$(inst_msg '! 可执行权限修复失败，外部访问 CGI 可能 404')"

# ==================== Termux 检测 ====================
if [ ! -d /data/data/com.termux/files/home ]; then
    ui_print "$(inst_msg '! 未检测到 Termux（/data/data/com.termux/files/home）')"
    ui_print "$(inst_msg '! Termux 服务功能不可用；自定义二进制服务与 WebUI 不受影响')"
fi

# ==================== 模块结束 ====================
ui_print " "
ui_print "$(inst_msg '- 安装完成，重启后生效')"
