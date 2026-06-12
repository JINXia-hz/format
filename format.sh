#!/bin/sh
# format.sh - 自修复启动器
# 自动修复 Windows 换行符（CRLF -> LF）后执行主脚本

SCRIPT_DIR=$(dirname "$0")

# 修复 CRLF 换行符
sed -i 's/\r$//' "${SCRIPT_DIR}/cipan.sh" 2>/dev/null
sed -i 's/\r$//' "${SCRIPT_DIR}/security.sh" 2>/dev/null

# 执行主脚本
exec "${SCRIPT_DIR}/cipan.sh" "$@"
