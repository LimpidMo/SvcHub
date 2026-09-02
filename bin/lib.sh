#!/system/bin/sh
# SvcHub 公共库：配置读写（模块私有 config.json 明文）、进程 pid 管理、日志轮转与校验。
# 注意：调用方必须先设置 MODDIR=${0%/*} 再 source 本文件。

if [ -z "$MODDIR" ] || [ ! -d "$MODDIR" ]; then
    echo "lib.sh: MODDIR 未设置或不存在" >&2
    exit 1
fi

RUNDIR="$MODDIR/run"
LOG_DIR="$MODDIR/log"
SUPERLOG="$LOG_DIR/supervisor.log"
SPPID="$RUNDIR/supervisor.pid"
DISABLE_FILE="$MODDIR/disable"
CONFIG_FILE="$MODDIR/config.json"
TERMUX_HOME="/data/data/com.termux/files/home"
# Termux 应用运行 uid：测试命令以 su 切换该 uid 执行；取不到时回退 10000
TERMUX_UID=$(stat -c '%u' "$TERMUX_HOME" 2>/dev/null)
[ -z "$TERMUX_UID" ] && TERMUX_UID=10000
TERMUX_UID=$(stat -c '%u' "$TERMUX_HOME" 2>/dev/null || stat -c '%u' /data/data/com.termux 2>/dev/null)
# Termux 启动命令必须注入的环境（单引号保留 $PATH 让 su 内 shell 展开）；
TERMUX_ENV='export PREFIX=/data/data/com.termux/files/usr; export PATH=$PREFIX/bin:$PATH; export TMPDIR=$PREFIX/tmp; export LD_LIBRARY_PATH=$PREFIX/lib;'
DEFAULT_SERVER_DIR="/data/media/0/Server"

mkdir -p "$RUNDIR" "$LOG_DIR"

# ---------- 配置（模块私有 config.json，明文 JSON） ----------
# 不依赖 ksud module config，使用模块私有 config.json（兼容 KernelSU / Magisk / APatch）。
# 值经 JSON 转义存储，读取后仍需按白名单校验，绝不 eval/source。

# JSON 字符串编码：反斜杠、双引号、制表符、换行转义为单行
enc_js() {
    awk '{ gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); if (NR > 1) printf "\\n"; printf "%s", $0 }'
}

# JSON 字符串解码：\n \t \" \\ 还原为明文
dec_js() {
    awk '{ gsub(/\\n/, "\n"); gsub(/\\t/, "\t"); gsub(/\\"/, "\""); gsub(/\\\\/, "\\"); printf "%s", $0 }'
}

# 读取某个 key 的值（明文）；不存在/空则输出空
cfg_get() {
    local key=$1 val
    [ -f "$CONFIG_FILE" ] || return 0
    val=$(sed -n "s/^[[:space:]]*\"${key}\":[[:space:]]*\"\(.*\)\"[,]*$/\1/p" "$CONFIG_FILE")
    [ -n "$val" ] || return 0
    printf '%s' "$val" | dec_js
}

# 一次性把五项配置写成 config.json（原子替换）
write_config_json() {
    local si=$1 sd=$2 ts=$3 sv=$4 bc=$5 tmp="$CONFIG_FILE.tmp"
    {
        echo '{'
        printf '  "sleep_interval": "%s",\n'  "$(printf '%s' "$si" | enc_js)"
        printf '  "server_dir": "%s",\n'      "$(printf '%s' "$sd" | enc_js)"
        printf '  "termux_services": "%s",\n' "$(printf '%s' "$ts" | enc_js)"
        printf '  "services": "%s",\n'        "$(printf '%s' "$sv" | enc_js)"
        printf '  "boot_commands": "%s"\n'    "$(printf '%s' "$bc" | enc_js)"
        echo '}'
    } > "$tmp" && mv -f "$tmp" "$CONFIG_FILE"
}

# 旧版 base64 行格式 config 一次性迁移到 config.json（仅当新文件不存在时）
if [ -f "$MODDIR/config" ] && [ ! -f "$CONFIG_FILE" ]; then
    _legacy_get() {
        local key=$1 line k b64
        while IFS= read -r line; do
            k=${line%%=*}
            [ "$k" = "$key" ] || continue
            b64=${line#*=}
            [ -n "$b64" ] || return 0
            printf '%s' "$b64" | base64 -d 2>/dev/null
            return 0
        done < "$MODDIR/config"
        return 0
    }
    write_config_json \
        "$(_legacy_get sleep_interval)" \
        "$(_legacy_get server_dir)" \
        "$(_legacy_get termux_services)" \
        "$(_legacy_get services)" \
        "$(_legacy_get boot_commands)"
    mv -f "$MODDIR/config" "$MODDIR/config.legacy"
fi

# ---------- su 可用性检测（兼容 KernelSU / Magisk / APatch） ----------

su_ready() {
    command -v su >/dev/null 2>&1 && return 0
    [ -e /system/bin/su ] && return 0
    [ -e /data/adb/ap/bin/su ] && return 0
    [ -e /data/adb/magisk/busybox ] && return 0
    return 1
}

# ---------- 校验 ----------

is_int() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    return 0
}

valid_name() {
    case "$1" in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
    return 0
}

# ---------- 日志 ----------

# 日志超过上限时保留最近一半，避免无限增长
rotate_log() {
    local log=$1 max=${2:-524288} sz
    [ -f "$log" ] || return 0
    sz=$(wc -c < "$log" 2>/dev/null | tr -d ' ')
    [ -n "$sz" ] && [ "$sz" -le "$max" ] && return 0
    if command -v tail >/dev/null 2>&1; then
        tail -c $((max / 2)) "$log" > "$log.tmp" 2>/dev/null && mv -f "$log.tmp" "$log" || : > "$log"
    else
        : > "$log"
    fi
}

# 从 stdin 逐行执行并记录（sh -c，不做 eval；# 注释行会保留执行）
run_command_lines() {
    local mark=$1 line log="$LOG_DIR/boot_commands.log"
    rotate_log "$log" 1048576
    {
        echo "=== $mark $(date '+%Y-%m-%d %H:%M:%S') ==="
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            echo "> $line"
            sh -c "$line"
            echo "[exit=$?]"
        done
    } >> "$log" 2>&1
}

# ---------- 会话清理 ----------
# 清空上一会话残留：run 目录删除全部残留 pid 文件；
# log 目录除开机命令日志全部删除。服务日志会在下次启动时重建。
clean_session_files() {
    local f base pid
    if [ -d "$RUNDIR" ]; then
        for f in "$RUNDIR"/*; do
            [ -e "$f" ] || continue
            base=${f##*/}
            rm -f "$f"
        done
    fi
    if [ -d "$LOG_DIR" ]; then
        for f in "$LOG_DIR"/*; do
            [ -f "$f" ] || continue
            base=${f##*/}
            [ "$base" = boot_commands.log ] && continue
            rm -f "$f"
        done
    fi
    return 0
}

# ---------- 进程管理（完全基于 pid 文件，杜绝按名模糊匹配） ----------
# 每个服务以 name 作为 $RUNDIR/<name>.pid 的索引，文件仅保存 setsid 进程组 leader 的 pid。
# 运行检测 = 首行 pid 存活；停止 = 向该 pid 的进程组发送 SIGKILL。

# 检查服务是否在运行：pid 文件存在且首行 pid 存活即在运行；进程已退出则顺手清理过期 pid 文件
svc_running() {
    local pidf="$RUNDIR/$1.pid"
    [ -f "$pidf" ] || return 1
    read -r pid < "$pidf" || { rm -f "$pidf"; return 1; }
    if kill -0 "$pid" 2>/dev/null; then
        return 0
    fi
    rm -f "$pidf"
    return 1
}

# 成员判断：$1=name 是否存在于换行分隔的名单 $2 中（零 fork，供批量结果查询）
name_in_set() {
    nl='
'
    case "$nl$2$nl" in
        *"$nl$1$nl"*) return 0 ;;
    esac
    return 1
}

# 从配置行列表提取 name 列（每行一个，跳过空行）
list_names() {
    awk -F'|' '$1 != "" { print $1 }'
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

# 启动服务：$1=名称 $2=工作目录 $3=su 附加参数 $4=命令文本
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
    rotate_log "$log"
    # 优先按 PATH 解析 su；解析不到时依次尝试常见绝对路径（兼容 KernelSU / Magisk / APatch）
    su_bin=$(command -v su 2>/dev/null)
    if [ -z "$su_bin" ]; then
        for p in /system/bin/su /data/adb/ap/bin/su /data/adb/magisk/busybox; do
            [ -e "$p" ] && { su_bin="$p"; break; }
        done
    fi
    [ -n "$su_bin" ] || su_bin="/system/bin/su"
    (
        cd "$dir"
        : > "$log"
        setsid "$su_bin" $extra -c "$cmdtext; wait" </dev/null >>"$log" 2>&1 &
        leader=$!
        printf '%s\n' "$leader" > "$pidf"
    ) >> "$log" 2>&1 &
    return 0
}

# 按 pid 文件终止：读取首行 pid，向整个进程组发送 SIGKILL
kill_by_name() {
    local name=$1 pidf="$RUNDIR/$1.pid" pid
    [ -f "$pidf" ] || return 1
    read -r pid < "$pidf" || return 1

    # 向整个进程组发送 SIGKILL
    kill -9 -- -"$pid" 2>/dev/null
}


# 停止服务：按 pid 文件终止进程组，清理 pid 文件与该服务日志
stop_svc() {
    local name=$1 pidf="$RUNDIR/$1.pid" i=0
    valid_name "$name" || return 0
    kill_by_name "$name"
    rm -f "$LOG_DIR/$1.log"
    # 短等待直至进程消失（防 fork 竞争残留）
    while [ "$i" -lt 20 ]; do
        svc_running "$name" || break
        sleep 0.2
        i=$((i + 1))
    done
    rm -f "$pidf"
    return 0
}

# 停止全部已配置服务
stop_all() {
    printf '%s\n' "$(cfg_get termux_services)" | while IFS='|' read -r name port extra auto cmd; do
        [ -n "$name" ] && stop_svc "$name"
    done
    printf '%s\n' "$(cfg_get services)" | while IFS='|' read -r name port auto cmd; do
        [ -n "$name" ] && stop_svc "$name"
    done
}

# ---------- 配置加载成 shell 变量（读取后再次校验） ----------

load_cfg_sh() {
    SLEEP_INTERVAL=$(cfg_get sleep_interval)
    SERVER_DIR=$(cfg_get server_dir)
    TERMUX_SERVICES=$(cfg_get termux_services)
    SERVICES=$(cfg_get services)
    BOOT_COMMANDS=$(cfg_get boot_commands)

    [ -n "$SLEEP_INTERVAL" ] || SLEEP_INTERVAL=60
    is_int "$SLEEP_INTERVAL" || SLEEP_INTERVAL=60
    # 保活间隔最小 5 秒，最大 86400 秒
    [ "$SLEEP_INTERVAL" -lt 5 ] && SLEEP_INTERVAL=5
    [ "$SLEEP_INTERVAL" -gt 86400 ] && SLEEP_INTERVAL=86400

    [ -n "$SERVER_DIR" ] || SERVER_DIR="$DEFAULT_SERVER_DIR"
}

# 按名称从配置取整行（awk 保留 cmd 中的 |；返回整行 $0）
pick_termux() {
    printf '%s\n' "$TERMUX_SERVICES" | awk -F'|' -v n="$1" '$1==n { print; exit }'
}

pick_binary() {
    printf '%s\n' "$SERVICES" | awk -F'|' -v n="$1" '$1==n { print; exit }'
}

# 查询某名称在两类配置中的 auto 值（start/stop/空）
should_run() {
    local name=$1 a
    a=$(printf '%s\n' "$TERMUX_SERVICES" | awk -F'|' -v n="$name" '$1==n { print $4; exit }')
    [ -n "$a" ] || a=$(printf '%s\n' "$SERVICES" | awk -F'|' -v n="$name" '$1==n { print $3; exit }')
    printf '%s' "$a"
}