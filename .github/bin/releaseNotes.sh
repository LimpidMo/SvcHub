#!/usr/bin/env bash
# 从 CHANGELOG.md 提取指定版本的段落，供 release 正文使用。
# 用法：bash .github/bin/releaseNotes.sh <version> [CHANGELOG.md] [输出文件]
# version 可带 v 前缀（如 v1.0.2），自动去掉后匹配 "## [1.0.2]" 节。
# 找不到对应节时输出一句兜底文案，保证 body_path 文件存在且流程不中断。

set -euo pipefail

VERSION="${1:?用法：releaseNotes.sh <version> [CHANGELOG.md] [输出文件]}"
CHANGELOG_FILE="${2:-CHANGELOG.md}"
OUTPUT_FILE="${3:-release_notes.md}"

# tag 常带 v 前缀，CHANGELOG 节标题不带，统一去掉
VERSION="${VERSION#v}"

if [ ! -f "$CHANGELOG_FILE" ]; then
    echo "releaseNotes: 找不到 $CHANGELOG_FILE" >&2
    printf 'Release %s\n' "$VERSION" > "$OUTPUT_FILE"
    exit 0
fi

# 取 "## [version]" 开头的节（标题行含日期后缀，不含标题行本身），到下一个同级 "## " 为止
awk -v prefix="## [$VERSION]" '
    index($0, prefix) == 1 { found = 1; next }
    found && /^## / { exit }
    found { print }
' "$CHANGELOG_FILE" | sed '/./,$!d' > "$OUTPUT_FILE"

if [ ! -s "$OUTPUT_FILE" ]; then
    echo "releaseNotes: CHANGELOG.md 中找不到 [$VERSION] 节" >&2
    printf 'Release %s\n\n详见 CHANGELOG.md。\n' "$VERSION" > "$OUTPUT_FILE"
fi
