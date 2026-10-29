#!/bin/sh
# lib 纯函数单测：在临时 MODDIR 中 source lib.sh，不碰仓库 config/。
# 用法：sh tools/test-lib.sh

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/svchub-lib.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

mkdir -p "$TMP/config"
cp "$ROOT/lib.sh" "$TMP/lib.sh"
cp -R "$ROOT/lib" "$TMP/lib"
MODDIR="$TMP"
SVCHUB_MOCK=1
export MODDIR SVCHUB_MOCK
. "$TMP/lib.sh" || { echo "FAIL source lib.sh"; exit 1; }

PASS=0
FAIL=0

check() { # name expected actual
	if [ "$2" = "$3" ]; then
		PASS=$((PASS + 1))
	else
		FAIL=$((FAIL + 1))
		printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
	fi
}

check_true() { # name command...
	local name=$1
	shift
	if "$@" >/dev/null 2>&1; then
		PASS=$((PASS + 1))
	else
		FAIL=$((FAIL + 1))
		printf 'FAIL %s (expected success)\n' "$name"
	fi
}

check_false() { # name command...
	local name=$1
	shift
	if "$@" >/dev/null 2>&1; then
		FAIL=$((FAIL + 1))
		printf 'FAIL %s (expected failure)\n' "$name"
	else
		PASS=$((PASS + 1))
	fi
}

# ---------- 关键回归：多行值不能被“键名行”截断 ----------
BOOT_COMMANDS=$(printf 'echo hi\nwifi_service_enabled=1\necho bye')
write_settings || check "write_settings rc" 0 1
load_settings
check "multiline value not truncated" "$BOOT_COMMANDS" "$(setting_var_get boot_commands)"
check "next key not shifted" "" "$(setting_var_get wifi_service_enabled)"

# ---------- 字符串编解码 ----------
v=$(printf 'a\\b"c\td\re')
check "enc_js escape" 'a\\b\"c\td\re' "$(printf '%s' "$v" | enc_js)"
check "enc_js roundtrip" "$v" "$(printf '%s' "$v" | enc_js | dec_js)"
ml=$(printf 'line1\nline2')
check "enc_js multiline" 'line1\nline2' "$(printf '%s' "$ml" | enc_js)"
check "dec_js multiline" "$ml" "$(printf '%s' "$ml" | enc_js | dec_js)"
rows=$(printf 'k1=a\\nb\nk2=plain')
# dec_js_rows 用 NUL 分隔，转成 | 后按字节比较
out=$(printf '%s\n' "$rows" | dec_js_rows | tr '\0' '|')
check "dec_js_rows bytes" 'k1|a
b|k2|plain|' "$out"

# ---------- 定时窗 ----------
check_true "sched cross-midnight inside" sched_in_window 23:00 07:00 23:30
check_true "sched cross-midnight late" sched_in_window 23:00 07:00 06:59
check_false "sched cross-midnight edge out" sched_in_window 23:00 07:00 07:00
check_false "sched cross-midnight noon out" sched_in_window 23:00 07:00 12:00
check_true "sched same-day inside" sched_in_window 08:00 17:00 12:00
check_false "sched same-day edge out" sched_in_window 08:00 17:00 17:00
check_false "sched stop==start" sched_in_window 08:00 08:00 08:00
check_false "sched invalid time" sched_in_window 24:00 17:00 12:00
check_true "sched full-day start" sched_in_window 00:00 23:59 00:00
check_false "sched full-day end" sched_in_window 00:00 23:59 23:59

# ---------- 名称与集合 ----------
check_true "valid_name ok" valid_name 'svc_a-1.2'
check_false "valid_name empty" valid_name ''
check_false "valid_name space" valid_name 'a b'
check_false "valid_name pipe" valid_name 'a|b'
check_false "valid_name chinese" valid_name '服务'
names=$(printf 'alpha\nbeta\ngamma')
check_true "name_in_set hit" name_in_set beta "$names"
check_false "name_in_set miss" name_in_set delta "$names"
check_false "name_in_set empty" name_in_set '' "$names"
check_true "word_in_set hit" word_in_set beta 'alpha beta gamma'
check_false "word_in_set miss" word_in_set bet 'alpha beta gamma'
check_true "is_int ok" is_int 123
check_false "is_int empty" is_int ''
check_false "is_int sign" is_int -1

# ---------- Wi-Fi SSID 匹配 ----------
check_true "ssid empty list allows any" wifi_ssid_match Home ''
check_false "ssid empty current fails" wifi_ssid_match '' 'Home'
check_true "ssid exact" wifi_ssid_match 'Home' 'Home'
check_true "ssid padded line" wifi_ssid_match 'Home' '  Home  '
check_false "ssid pipe line ignored" wifi_ssid_match 'Home' 'Home|Work'
check_true "ssid unicode" wifi_ssid_match '我家🏠' 'Office
我家🏠'

# ---------- 高危命令 ----------
check "danger rm -rf /" "rm -rf /" "$(dangerous_line 'rm -rf /')"
check "danger rm -rf /*" "rm -rf /*" "$(dangerous_line 'rm -rf /*')"
check "danger mkfs" "mkfs.ext4 /dev/block/x" "$(dangerous_line 'mkfs.ext4 /dev/block/x')"
check "danger block dev" "dd of=/dev/block/sda" "$(dangerous_line 'dd of=/dev/block/sda')"
check "danger fork bomb" ":(){ :|:& };" "$(dangerous_line ':(){ :|:& };')"
check "safe partial rm" "" "$(dangerous_line 'rm -rf /data/local/tmp/x')"
check "safe echo text" "" "$(dangerous_line 'echo ":() { :; }"')"

# ---------- Token / 密码 ----------
tok=$(webui_gen_token)
check "token length" 64 "${#tok}"
hash=$(printf '%s' secret | webui_hash_password salt123)
check_true "password check ok" webui_check_password secret "$hash"
check_false "password check bad" webui_check_password wrong "$hash"
case "$hash" in
salt123\$*) check "password hash format" ok ok ;;
*) check "password hash format" 'salt$hex' "$hash" ;;
esac

# ---------- 会话失效（重启只清密码会话） ----------
now=$(date +%s)
printf '%s' "$((now + 3600))" > "$WEBUI_SESS_DIR/sess_alive"
printf '%s' "$((now + 3600))" > "$WEBUI_SESS_DIR/tsess_alive"
printf '%s' "$((now - 10))" > "$WEBUI_SESS_DIR/sess_dead"
webui_expire_password_sessions
check_false "expire removes valid password session" test -f "$WEBUI_SESS_DIR/sess_alive"
check_true "expire keeps token session" test -f "$WEBUI_SESS_DIR/tsess_alive"
check_true "expire keeps expired file for lazy cleanup" test -f "$WEBUI_SESS_DIR/sess_dead"
rm -f "$WEBUI_SESS_DIR"/sess_* "$WEBUI_SESS_DIR"/tsess_*

# ---------- JSON 助手 ----------
check "json_ok" '{"success":true}' "$(json_ok)"
check "json_fail escape" '{"success":false,"error":"a\"b\\c"}' "$(json_fail 'a"b\c')"

# ---------- i18n：中文恒等 + 英文查表 ----------
UI_LANG=zh
check "ui zh patrol" '巡检完成' "$(ui_msg '巡检完成')"
check "ui zh format" '巡检开始 interval=60s' "$(ui_msg '巡检开始 interval=%ss' 60)"
check "ui zh skip reason" '熄屏非白名单' "$(ui_msg '熄屏非白名单')"
check "ui zh percent safe" '100% 完成' "$(ui_msg '100% 完成')"
check "ui zh boot" '系统启动完成' "$(ui_msg '系统启动完成')"
check "ui zh disable" '检测到 disable，停止全部受管服务' "$(ui_msg '检测到 disable，停止全部受管服务')"
check "ui zh skip detail" '    跳过 demo (熄屏非白名单)' "$(ui_msg '    跳过 %s (%s)' demo '熄屏非白名单')"
check "ui zh schedule enter" '进入定时停止窗（08:00~17:00），已停止全部服务' "$(ui_msg '进入定时停止窗（%s~%s），已停止全部服务' '08:00' '17:00')"
check "ui zh screen off" '进入熄屏，停止非白名单服务' "$(ui_msg '进入熄屏，停止非白名单服务')"
check "ui zh wifi off" 'Wi-Fi 启停已关闭' "$(ui_msg 'Wi-Fi 启停已关闭')"
check "ui zh wifi ssid" '当前 Wi-Fi：Home' "$(ui_msg '当前 Wi-Fi：%s' 'Home')"
check "ui zh config encode" '配置编码错误' "$(ui_msg '配置编码错误')"
check "ui zh config empty" '配置内容为空' "$(ui_msg '配置内容为空')"
check "ui zh unknown key" '未知配置键' "$(ui_msg '未知配置键')"
check "ui zh httpd stop" 'httpd 已停止' "$(ui_msg 'httpd 已停止')"
check "ui zh login ok" '登录成功：127.0.0.1' "$(ui_msg '登录成功：%s' '127.0.0.1')"
check "ui zh dangerous" '包含高危命令，已拒绝执行：rm -rf /' "$(ui_msg '包含高危命令，已拒绝执行：%s' 'rm -rf /')"
check "ui zh boot cmd" '开机命令' "$(ui_msg '开机命令')"
check "ui zh password short" '密码至少 6 位' "$(ui_msg '密码至少 6 位')"
check "ui zh port busy" '端口 5555 被占用' "$(ui_msg '端口 %s 被占用' 5555)"
UI_LANG=en
check "ui en patrol" 'Patrol complete' "$(ui_msg '巡检完成')"
check "ui en format" 'Patrol start interval=60s' "$(ui_msg '巡检开始 interval=%ss' 60)"
check "ui en fallback" '未翻译的文案' "$(ui_msg '未翻译的文案')"
UI_LANG=zh

# ---------- 设置项 schema 往返 ----------
SLEEP_INTERVAL=25
SERVER_DIR='/data/media/0/Server'
BOOT_COMMANDS=$(printf 'echo "a b"\nprintf "%%s\\n" x')
WIFI_SERVICE_ENABLED=0
WIFI_SERVICE_NAMES=''
WIFI_SERVICE_NAMES_OFF=''
WIFI_SSIDS=''
SCHEDULE_ENABLED=0
SCHEDULE_STOP=''
SCHEDULE_START=''
SCREEN_SERVICE_ENABLED=0
SCREEN_SERVICE_NAMES=''
SCREEN_RESUME_NAMES=''
TERMUX_ROOT_NAMES=''
PATROL_ENABLED=1
WAKE_LOCK_ENABLED=0
UI_LANG=zh
WEBUI_ENABLED=1
WEBUI_PASSWORD_HASH=''
WEBUI_PASSWORD_DEFAULT=0
WEBUI_TOKEN=''
write_settings || check "write_settings rc" 0 1
raw_boot=$(grep '^boot_commands=' "$SETTING_FILE")
case "$raw_boot" in
*'\n'*) check "setting.conf escaped newline" yes yes ;;
*) check "setting.conf escaped newline" yes "$raw_boot" ;;
esac
lines=$(grep -c '^[a-z_]*=' "$SETTING_FILE")
check "setting.conf key count" 21 "$lines"
load_settings
check "settings boot roundtrip" "$BOOT_COMMANDS" "$(setting_var_get boot_commands)"
check "settings interval roundtrip" 25 "$(setting_var_get sleep_interval)"
check "setting_file_get" 25 "$(setting_file_get sleep_interval)"
check "settings language" zh "$(setting_var_get language)"
check "public key count" 18 "$(printf '%s\n' "$SETTING_PUBLIC_KEYS" | wc -w | tr -d ' ')"
check_true "public has webui_enabled" word_in_set webui_enabled "$SETTING_PUBLIC_KEYS"
check_false "public hides password hash" word_in_set webui_password_hash "$SETTING_PUBLIC_KEYS"
check_false "public hides token" word_in_set webui_token "$SETTING_PUBLIC_KEYS"
check_false "public hides default flag" word_in_set webui_password_default "$SETTING_PUBLIC_KEYS"
check_false "setting_var_load unknown" setting_var_load nope_key
check_false "setting_var_get unknown" setting_var_get nope_key

# 全键往返：漏一个 load/set 分支会在这里暴露
i=0
for k in $SETTING_KEYS; do
	i=$((i + 1))
	setting_var_set "$k" "marker-$i"
done
write_settings
load_settings
i=0
for k in $SETTING_KEYS; do
	i=$((i + 1))
	check "roundtrip $k" "marker-$i" "$(setting_var_get "$k")"
done

# ---------- 默认密码标志：迁移与轻量状态 ----------
# 旧配置无标志时按哈希推断：默认密码哈希 → 1（强制改密），改过 → 0
prepare_legacy_config() { # $1=密码：其哈希写入配置后剥掉标志行，让迁移从「无键」状态开始
	WEBUI_PASSWORD_HASH=$(printf '%s' "$1" | webui_hash_password saltsalt)
	WEBUI_PASSWORD_DEFAULT=""
	write_settings
	grep -v '^webui_password_default=' "$SETTING_FILE" > "$TMP/noflag.conf" && cp "$TMP/noflag.conf" "$SETTING_FILE"
}
WEBUI_ENABLED=1
prepare_legacy_config "$WEBUI_DEFAULT_PASSWORD"
webui_password_default_migrate
check "migrate default admin flag" 1 "$(setting_file_get webui_password_default)"
check "migrate flag in memory" 1 "$WEBUI_PASSWORD_DEFAULT"
check "webui status fast" '1 1 1' "$(webui_status_fast)"
prepare_legacy_config 'changed'
webui_password_default_migrate
check "migrate changed password flag" 0 "$(setting_file_get webui_password_default)"

# ---------- 服务项 schema 往返（end_cmd 含 |） ----------
TERMUX_SERVICES='svc-a|80|start|echo a|echo end | tee /dev/null'
BINARY_SERVICES='svc-b||stop|echo b|false'
write_services || check "write_services rc" 0 1
case "$(head -n 1 "$SERVICES_FILE")" in
'# svc-v1.4.0'*) check "services marker" ok ok ;;
*) check "services marker" '# svc-v1.4.0' "$(head -n 1 "$SERVICES_FILE")" ;;
esac
TERMUX_SERVICES=""
BINARY_SERVICES=""
load_services
check "termux row roundtrip" 'svc-a|80|start|echo a|echo end | tee /dev/null' "$TERMUX_SERVICES"
check "binary row roundtrip" 'svc-b||stop|echo b|false' "$BINARY_SERVICES"
check "pick termux" 'svc-a|80|start|echo a|echo end | tee /dev/null' "$(pick_termux svc-a)"

printf 'PASS %s / FAIL %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
