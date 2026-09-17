#!/usr/bin/env bash
# Export all variables from module.prop and CI config and export them with set-output

set -euo pipefail
# Export all config values from $1，保证文件末尾换行，避免与下一个文件首行粘连
export_all() {
    FILE="${1}"
    cat "${FILE}" >> "${GITHUB_OUTPUT}"
    printf '\n' >> "${GITHUB_OUTPUT}"
}

export_all "module.prop"
export_all ".github/config.prop"