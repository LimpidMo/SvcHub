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
check "setting.conf key count" 23 "$lines"
load_settings
check "settings boot roundtrip" "$BOOT_COMMANDS" "$(setting_var_get boot_commands)"
check "settings interval roundtrip" 25 "$(setting_var_get sleep_interval)"
check "setting_file_get" 25 "$(setting_file_get sleep_interval)"
check "settings language" zh "$(setting_var_get language)"
check "public key count" 20 "$(printf '%s\n' "$SETTING_PUBLIC_KEYS" | wc -w | tr -d ' ')"
check_true "public has webui_enabled" word_in_set webui_enabled "$SETTING_PUBLIC_KEYS"
check_true "public has update_proxy_prefix" word_in_set update_proxy_prefix "$SETTING_PUBLIC_KEYS"
check_true "public has update_check_interval" word_in_set update_check_interval "$SETTING_PUBLIC_KEYS"
check_false "public hides password hash" word_in_set webui_password_hash "$SETTING_PUBLIC_KEYS"
check_false "public hides token" word_in_set webui_token "$SETTING_PUBLIC_KEYS"
check_false "public hides default flag" word_in_set webui_password_default "$SETTING_PUBLIC_KEYS"
check_false "setting_var_load unknown" setting_var_load nope_key
check_false "setting_var_get unknown" setting_var_get nope_key

# ---------- 版本比较 ver_cmp ----------
check "ver_cmp newer" 1 "$(ver_cmp v0.31.0 v0.30.9)"
check "ver_cmp older" -1 "$(ver_cmp v0.30.9 v0.31.0)"
check "ver_cmp equal" 0 "$(ver_cmp v0.31.0 v0.31.0)"
check "ver_cmp no-v prefix" 0 "$(ver_cmp 1.0 1.0.0)"
check "ver_cmp patch" 1 "$(ver_cmp 1.0.1 1.0)"
check "ver_cmp prerelease lower" -1 "$(ver_cmp v1.0.0-beta v1.0.0)"
check "ver_cmp release higher" 1 "$(ver_cmp v1.0.0 v1.0.0-beta)"
check "ver_cmp prerelease order" -1 "$(ver_cmp v1.0.0-alpha v1.0.0-beta)"
# v 前缀两侧混用必须一致对待（本地 0.29.0 vs 远端 v0.31.0 是真实场景）
check "ver_cmp v-prefixed newer" 1 "$(ver_cmp v0.31.0 0.29.0)"
check "ver_cmp local no-v newer" 1 "$(ver_cmp 0.31.0 v0.29.0)"
check "ver_cmp v vs no-v equal" 0 "$(ver_cmp v0.31.0 0.31.0)"
check "ver_cmp no-v vs v equal" 0 "$(ver_cmp 0.31.0 v0.31.0)"
# git hash 后缀是构建元数据，与正式版等价（2.6.4-8428a89d 不比 v2.6.4 旧）
check "ver_cmp hash suffix equal" 0 "$(ver_cmp v2.6.4 2.6.4-8428a89d)"
check "ver_cmp hash vs newer minor" 1 "$(ver_cmp v2.7.0 2.6.4-8428a89d)"
# 预发布点分逐段比：数字标识按数值（字符串比较会误判 beta.9 > beta.10）
check "ver_cmp prerelease dotted numeric" 1 "$(ver_cmp v1.0.0-beta.10 v1.0.0-beta.9)"
check "ver_cmp prerelease dotted numeric rev" -1 "$(ver_cmp v1.0.0-beta.9 v1.0.0-beta.10)"
check "ver_cmp prerelease shorter older" -1 "$(ver_cmp v1.0.0-beta v1.0.0-beta.1)"
# + 构建元数据剥离：不剥会吞掉最后一个数字段（1.0.1+build 误判为 1.0.0）
check "ver_cmp plus metadata equal" 0 "$(ver_cmp v1.0.0+build.123 1.0.0)"
check "ver_cmp plus metadata newer" 1 "$(ver_cmp 1.0.1+build.123 v1.0.0)"
# 8 位纯数字日期段无溢出、前导 0 按数值等价
check "ver_cmp 8digit date" 1 "$(ver_cmp v20260812 v20260801)"
check "ver_cmp leading zero equal" 0 "$(ver_cmp v2026.09.01 v2026.9.1)"

# ---------- 归档格式识别（按 magic bytes，不靠扩展名） ----------
printf '\037\213\010\000\000\000' > "$TMP/t.gz"
printf 'PK\003\004\000\000\000' > "$TMP/t.zip"
printf '\375\067\172\130\132\000' > "$TMP/t.xz"
printf 'BZh91AY&SY' > "$TMP/t.bz2"
printf 'ustar' > "$TMP/t.tar"
check "archive kind gz" gz "$(update_archive_kind "$TMP/t.gz")"
check "archive kind zip" zip "$(update_archive_kind "$TMP/t.zip")"
check "archive kind xz" xz "$(update_archive_kind "$TMP/t.xz")"
check "archive kind bz2" bz2 "$(update_archive_kind "$TMP/t.bz2")"
check "archive kind tar" tar "$(update_archive_kind "$TMP/t.tar")"

# ---------- 资产模板占位 ----------
check "asset {ver}" "memos_0.31.0_linux_arm64.tar.gz" "$(update_resolve_asset 'memos_{ver}_linux_arm64.tar.gz' v0.31.0)"
check "asset {tag}" "v0.31.0.zip" "$(update_resolve_asset '{tag}.zip' v0.31.0)"
check "asset plain" "app-linux.zip" "$(update_resolve_asset 'app-linux.zip' v0.31.0)"

# ---------- 更新条目校验 ----------
check "update row ok" "" "$(printf '%s\n' 'memos|usememos/memos|memos_{ver}_linux_arm64.tar.gz|./memos/memos|file|memos||./memos/memos --version' | validate_update_rows)"
check "update row dup name" 2 "$(printf '%s\n' 'a|x/y|f.zip|p|file||' 'a|x/y|f.zip|p|file||' | validate_update_rows)"
check "update row bad repo" 1 "$(printf '%s\n' 'a|badrepo|f.zip|p|file||' | validate_update_rows)"
check "update row bad mode" 1 "$(printf '%s\n' 'a|x/y|f.zip|p|zip||' | validate_update_rows)"
check "update row raw mode ok" "" "$(printf '%s\n' 'a|x/y|f.bin|p|raw||' | validate_update_rows)"
check "update row abs target" 1 "$(printf '%s\n' 'a|x/y|f.zip|/abs/p|file||' | validate_update_rows)"
check "update row dotdot target" 1 "$(printf '%s\n' 'a|x/y|f.zip|../p|file||' | validate_update_rows)"
check "update row empty asset" 1 "$(printf '%s\n' 'a|x/y||p|file||' | validate_update_rows)"
check "update row bad name" 1 "$(printf '%s\n' 'a b|x/y|f.zip|p|file||' | validate_update_rows)"
check "update row vercmd pipe rejected" 1 "$(printf '%s\n' 'a|x/y|f.zip|p|file|||v --version | head -1' | validate_update_rows)"

# ---------- 更新条目读写（9 段：ins_ver=7 vercmd=8 update_ver=9） ----------
UPDATE_ENTRIES='memos|usememos/memos|memos_{ver}_linux_arm64.tar.gz|./memos/memos|file|memos|v0.30.9|./memos/memos --version|v0.31.0
easy|easytier/easytier|easytier-linux-x86_64.zip|./easytier/easytier-core|file|||'
write_update_conf || check "write_update_conf rc" 0 1
UPDATE_ENTRIES=""
load_update_conf
check "update entry count" 2 "$(printf '%s\n' "$UPDATE_ENTRIES" | grep -c .)"
check "update entry ins_ver" "v0.30.9" "$(printf '%s\n' "$UPDATE_ENTRIES" | head -n 1 | awk -F'|' '{print $7}')"
check "update entry vercmd" "./memos/memos --version" "$(printf '%s\n' "$UPDATE_ENTRIES" | head -n 1 | awk -F'|' '{print $8}')"
check "update entry update_ver" "v0.31.0" "$(printf '%s\n' "$UPDATE_ENTRIES" | head -n 1 | awk -F'|' '{print $9}')"
check "pick_update_entry" "usememos/memos" "$(pick_update_entry memos | awk -F'|' '{print $2}')"
check "pick_update_entry miss" "" "$(pick_update_entry nope)"
check "list_update_names" "memos easy" "$(list_update_names | tr '\n' ' ' | sed 's/ $//')"
# 版本字段回写：文件与内存同步（getupdates 的 JSON 依赖内存副本）
update_set_ins_ver memos v0.31.1
update_set_update_ver memos v0.31.1
check "set ins_ver memory" "v0.31.1" "$(printf '%s\n' "$UPDATE_ENTRIES" | head -n 1 | awk -F'|' '{print $7}')"
check "set ins_ver file" "v0.31.1" "$(awk -F'|' '$1=="memos"{print $7}' "$UPDATE_CONF")"
check "set update_ver memory" "v0.31.1" "$(printf '%s\n' "$UPDATE_ENTRIES" | head -n 1 | awk -F'|' '{print $9}')"
# 末段缺省时补齐到 9 段
printf 'a|x/y|f.zip|p|file||\nb|x/y|f.zip|p|file\n' > "$UPDATE_CONF"
UPDATE_ENTRIES=""
load_update_conf
check "update row pad to 10" "a|x/y|f.zip|p|file|||||" "$(printf '%s\n' "$UPDATE_ENTRIES" | head -n 1)"
check "update row pad last" "b|x/y|f.zip|p|file|||||" "$(printf '%s\n' "$UPDATE_ENTRIES" | tail -n 1)"
# 非法行跳过，其余条目照常生效
printf 'a|x/y|f.zip|p|file||\nbadline\nc|x/y|f.zip|p|file||\n' > "$UPDATE_CONF"
UPDATE_ENTRIES=""
load_update_conf
check "update invalid line skipped" 2 "$(printf '%s\n' "$UPDATE_ENTRIES" | grep -c .)"

# ---------- 资产映射（name|digest|size） ----------
ASSETMAP='checksums.txt|aaa|589
memos_0.31.0_linux_arm64.tar.gz|bbb|20181109
memos_0.31.0_linux_amd64.tar.gz|ccc|21825067'
check "asset digest" bbb "$(update_asset_digest "$ASSETMAP" memos_0.31.0_linux_arm64.tar.gz)"
check "asset size" 20181109 "$(update_asset_size "$ASSETMAP" memos_0.31.0_linux_arm64.tar.gz)"
check "asset size missing" "" "$(update_asset_size "$ASSETMAP" nope.tar.gz)"

# ---------- 真实 GitHub API 形态的资产解析 ----------
# uploader 嵌套对象含 {、URL 值含 {?x}、digest 为 null（老资产）——回归「资产恒为空」的 Critical
API_SAMPLE='{
  "tag_name": "v0.31.0",
  "assets": [
    {
      "url": "https://api.github.com/repos/o/r/releases/assets/1",
      "id": 1,
      "name": "checksums.txt",
      "label": null,
      "uploader": {
        "login": "u",
        "html_url": "https://github.com/u{?x}",
        "type": "User"
      },
      "content_type": "text/plain",
      "state": "uploaded",
      "size": 589,
      "digest": "sha256:aaa",
      "browser_download_url": "https://github.com/o/r/releases/download/v0.31.0/checksums.txt"
    },
    {
      "url": "https://api.github.com/repos/o/r/releases/assets/2",
      "id": 2,
      "name": "app.tar.gz",
      "uploader": { "login": "u" },
      "size": 100,
      "digest": null
    },
    {
      "url": "https://api.github.com/repos/o/r/releases/assets/3",
      "id": 3,
      "name": "app2.tar.gz",
      "size": 200,
      "digest": "sha256:bbb"
    }
  ]
}'
printf '%s' "$API_SAMPLE" | awk "$UPDATE_ASSETS_AWK" > "$TMP/assets.out"
check "api assets parsed count" 2 "$(grep -c . "$TMP/assets.out")"
check "api assets first" "checksums.txt|aaa|589" "$(head -n 1 "$TMP/assets.out")"
check "api assets second" "app2.tar.gz|bbb|200" "$(tail -n 1 "$TMP/assets.out")"

# ---------- 嵌套归档提取（demo.zip 内 test/binary，甚至 zip 套 gz） ----------
NEST="$TMP/nest"
rm -rf "$NEST"; mkdir -p "$NEST/pkg/test"
printf 'BINARY-OK' > "$NEST/pkg/test/svchub-server"
# 嵌套形态一：包内子目录（demo.tar.gz 内 test/svchub-server）
tar -czf "$NEST/demo.tar.gz" -C "$NEST/pkg" test
rm -rf "$NEST/out1"
r1=$(update_extract_payload "$NEST/demo.tar.gz" "$NEST/out1" 'svchub-server')
check "nested subdir extraction" yes "$(case "$r1" in *svchub-server*) [ -f "$r1" ] && echo yes || echo no;; *) echo no;; esac)"
# 嵌套形态二：归档里套归档（tar.gz 内 inner.tar.gz 内 binary）
tar -czf "$NEST/inner.tar.gz" -C "$NEST/pkg" test
tar -czf "$NEST/outer.tar.gz" -C "$NEST" inner.tar.gz
rm -rf "$NEST/out2"
r2=$(update_extract_payload "$NEST/outer.tar.gz" "$NEST/out2" 'svchub-server')
check "nested archive-in-archive" yes "$(case "$r2" in *svchub-server*) [ -f "$r2" ] && echo yes || echo no;; *) echo no;; esac)"
# 内层内容与源一致（解两层后得到的还是那个二进制）
check "nested payload content" "BINARY-OK" "$(cat "$r2" 2>/dev/null)"
# 内层解包成功但没有目标文件：直接失败（外层是归档，装回去等于装垃圾）
T2="$TMP/nest2"
rm -rf "$T2"; mkdir -p "$T2/pkg"
printf 'OTHER' > "$T2/other.txt"
tar -czf "$T2/inner.tar.gz" -C "$T2" other.txt
tar -czf "$T2/outer.tar.gz" -C "$T2" inner.tar.gz
rm -rf "$T2/out"
r3=$(update_extract_payload "$T2/outer.tar.gz" "$T2/out" 'svchub-server')
check "nested missing target fails" "" "$r3"

# ---------- 本地版本探测（目标路径 + 参数） ----------
# 造假二进制：version/--version/-v/v 四种参数各回不同版本形态，验证逐个探测与提取
mkdir -p "$TMP/bin"
printf '#!/bin/sh\ncase "$1" in\nversion) echo "memos version 0.29.0" ;;\n--version) echo "0.29.0" ;;\n-v) echo "v0.29.0" ;;\nv) echo "0.29.0 (build 7)" ;;\n*) echo "usage: app <cmd>" ;;\nesac\n' > "$TMP/bin/app"
chmod +x "$TMP/bin/app"
SERVER_DIR="$TMP"
check "probe args version" "0.29.0" "$(update_local_version 'version' './bin/app')"
check "probe args --version" "0.29.0" "$(update_local_version '--version' './bin/app')"
check "probe args -v" "v0.29.0" "$(update_local_version '-v' './bin/app')"
check "probe args v" "0.29.0" "$(update_local_version 'v' './bin/app')"
# 留空：按 --version/version/-v/v 逐个兜底，第一个出版本号的胜出
check "probe empty args fallback" "0.29.0" "$(update_local_version '' './bin/app')"
# 填了错误参数也应兜底成功（先试用户参数，失败再逐个试）
check "probe wrong arg fallback" "0.29.0" "$(update_local_version '--verison' './bin/app')"
# 无目标路径拒绝
check "probe no target" "" "$(update_local_version 'version')"
# 新形态输出识别：+ 元数据 / hash 后缀 / 点分预发布，与 ver_cmp 的剥离规则两侧一致
printf '#!/bin/sh\necho "memos version 0.31.0+build.5"\n' > "$TMP/bin/p1"
printf '#!/bin/sh\necho "easytier 2.6.4-8428a89d"\n' > "$TMP/bin/p2"
printf '#!/bin/sh\necho "app v1.0.0-beta.10"\n' > "$TMP/bin/p3"
chmod +x "$TMP/bin/p1" "$TMP/bin/p2" "$TMP/bin/p3"
check "probe plus metadata" "0.31.0+build.5" "$(update_local_version '--version' './bin/p1')"
check "probe hash suffix" "2.6.4-8428a89d" "$(update_local_version 'version' './bin/p2')"
check "probe dotted prerelease" "v1.0.0-beta.10" "$(update_local_version 'version' './bin/p3')"
# 识别+比较端到端：提取带 + 的版本与远端正式版应判相等
check "vercmp plus vs plain equal" 0 "$(ver_cmp v0.31.0 0.31.0+build.5)"
check "vercmp newer vs dotted prerelease" 1 "$(ver_cmp v1.0.1 v1.0.0-beta.10)"
# 四种真实输出形态：memos 输出不带 v，远端 tag 带 v —— 提取与比较都要成立
check "vercmp local no-v vs remote v" 1 "$(ver_cmp v0.31.0 0.29.0)"
check "vercmp v vs no-v equal" 0 "$(ver_cmp v0.31.0 0.31.0)"
# 原始输出回传（排查用）：命令在子 shell 跑，只能靠文件带回来
rm -f "$TMP/verraw.txt"
check "probe raw file value" "0.29.0" "$(update_local_version 'version' './bin/app' "$TMP/verraw.txt")"
check "probe raw captured" "memos version 0.29.0" "$(cat "$TMP/verraw.txt" 2>/dev/null | tr -d '\n')"

# ---------- 代理前缀：末尾无 / 自动补（拼接依赖） ----------
UPDATE_PROXY_PREFIX="https://x.test"
write_settings
check "proxy prefix append slash" "https://x.test/https://api.github.com/repos/a/b/releases/latest" "$(update_api_url a/b)"
check "proxy prefix keep slash" "https://x.test/https://github.com/a/b/releases/download/v1/f" "$(update_download_url a/b v1 f)"
UPDATE_PROXY_PREFIX=""
write_settings
check "proxy prefix empty direct" "https://api.github.com/repos/a/b/releases/latest" "$(update_api_url a/b)"

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
