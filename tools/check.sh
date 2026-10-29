#!/bin/sh
# 快速校验（无设备、无桥）：语法 + lib 单测 + 重复函数 + i18n + 打包清单。
# 用法：sh tools/check.sh
ROOT=$(cd "$(dirname "$0")/.." && pwd)
FAIL=0

say() { printf '%s\n' "$*"; }
fail() { FAIL=1; printf 'FAIL %s\n' "$*"; }

# 1. shell 语法
for f in "$ROOT"/*.sh "$ROOT"/lib/*.sh "$ROOT"/webroot/cgi-bin/*.cgi; do
	[ -f "$f" ] || continue
	sh -n "$f" || fail "syntax: ${f#$ROOT/}"
done
say "syntax: ok"

# 2. 重复函数定义（customize.sh 安装期自带 ui_fill，属有意重复，不参与比较）
DUP=$(grep -h -o '^[A-Za-z_][A-Za-z0-9_]*()' \
	"$ROOT"/lib.sh "$ROOT"/lib/*.sh "$ROOT"/action.sh "$ROOT"/service.sh \
	"$ROOT"/supervisor.sh "$ROOT"/httpd.sh "$ROOT"/uninstall.sh \
	"$ROOT"/webroot/cgi-bin/api.cgi 2>/dev/null | sort | uniq -d)
if [ -n "$DUP" ]; then
	fail "duplicate functions: $(printf '%s' "$DUP" | tr '\n' ' ')"
else
	say "duplicate functions: ok"
fi

# 3. lib 纯函数单测
if sh "$ROOT/tools/test-lib.sh"; then
	say "lib tests: ok"
else
	fail "lib tests"
fi

# 4. 双语文案一致性
if node "$ROOT/tools/check-i18n.js"; then
	say "i18n: ok"
else
	fail "i18n"
fi

# 5. 打包清单与 exec 位
PY=python
command -v "$PY" >/dev/null 2>&1 || PY=python3
if "$PY" "$ROOT/tools/pack.py" --check; then
	say "pack check: ok"
else
	fail "pack check"
fi

if [ "$FAIL" -eq 0 ]; then
	say "ALL OK"
else
	say "FAILED"
fi
exit "$FAIL"
