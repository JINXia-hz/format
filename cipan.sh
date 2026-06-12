#!/bin/bash

# 加载安全保护模块（自动执行安全检查）
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
source "${SCRIPT_DIR}/security.sh"

set -euo pipefail

# 支持的格式化命令映射表
declare -A FS_CMDS=(
    ["xfs"]="mkfs.xfs -f"
    ["ext4"]="mkfs.ext4 -F"
    ["ext3"]="mkfs.ext3 -F"
    ["ext2"]="mkfs.ext2 -F"
    ["btrfs"]="mkfs.btrfs -f"
    ["ntfs"]="mkfs.ntfs -F"
    ["fat32"]="mkfs.fat -F32"
)

select_type() {
    local prompt=$1
    local fs_choice
    
    echo ""
    echo "${prompt}"
    echo "  1) xfs    (默认)"
    echo "  2) ext4"
    echo "  3) ext3"
    echo "  4) ext2"
    echo "  5) btrfs"
    echo "  6) ntfs"
    echo "  7) fat32"
    fs_choice=$(validate_input "请输入编号 (1-7，默认 1): " "^[1-7]$" "1") 
    case "${fs_choice:-1}" in
        1) echo "xfs" ;;
        2) echo "ext4" ;;
        3) echo "ext3" ;;
        4) echo "ext2" ;;
        5) echo "btrfs" ;;
        6) echo "ntfs" ;;
        7) echo "fat32" ;;
        *) echo "xfs" ;;
    esac
}
# 模式选择
echo "进入模式选择前请核对所有磁盘情况"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE,MODEL

echo ""
echo "=================================================="
echo "              请选择确认模式                       "
echo "=================================================="
echo "  1) 交互确认模式 - 每个磁盘格式化前询问确认"
echo "  2) 自动确认模式 - 不询问，直接格式化所有磁盘"
echo "=================================================="
confirm_mode=$(validate_input "请输入编号 (1-2，默认 1): " "^[12]$" "1")

echo ""
echo "=================================================="
echo "            请选择文件系统指定方式                 "
echo "=================================================="
echo "  1) 统一格式 - 所有磁盘使用同一种文件系统"
echo "  2) 单次指定 - 每个磁盘单独选择文件系统"
echo "=================================================="
fs_mode=$(validate_input "请输入编号 (1-2，默认 1): " "^[12]$" "1")

# 统一格式模式：提前选择文件系统
UNIFIED_FS=""
if [ "$fs_mode" -eq 1 ]; then
    UNIFIED_FS=$(select_type "请选择所有磁盘的统一文件系统类型:")
    echo "已选择统一文件系统: ${UNIFIED_FS}"
fi

log_message "INFO" "脚本启动，确认模式: ${confirm_mode}，文件系统指定方式: ${fs_mode}，统一格式: ${UNIFIED_FS:-无}"

# 安全审查结束，业务开始
ROOT_DEV=$(findmnt -n -o SOURCE /)
SYS_DISK=$(lsblk -no PKNAME "$ROOT_DEV" | head -n1)
if [ -z "$SYS_DISK" ]; then
    SYS_DISK=$(basename "$ROOT_DEV")
fi
SYS_DISK=$(echo "$SYS_DISK" | sed -E 's/p[0-9]+$//; s/[0-9]+$//')

log_message "INFO" "系统盘: /dev/${SYS_DISK}"

echo "正在尝试解除所有非系统分区的挂载..."
cat /proc/mounts | grep -E '^/dev/sd|^/dev/nvme' | grep -vE "/dev/${SYS_DISK}" | awk '{print $2}' | while IFS= read -r mount_point; do
    log_message "INFO" "正在解除挂载: ${mount_point}"
    if umount -l "$mount_point" 2>/dev/null; then
        log_message "INFO" "解除挂载成功: ${mount_point}"
    else
        log_message "WARN" "解除挂载失败: ${mount_point}"
    fi
done

format_disk() {
    local disk=$1
    local fs_type=$2
    local cmd="${FS_CMDS[$fs_type]}"
    
    # 磁盘参数有效性检查
    if [ -z "$disk" ]; then
        log_message "ERROR" "磁盘参数为空，拒绝执行格式化"
        echo "错误：磁盘参数为空，操作已终止。"
        return 1
    fi
    
    # 检查磁盘设备是否存在（排除路径穿越风险，只允许 sd/nvme/vd 等合法前缀）
    if [[ ! "$disk" =~ ^[a-z]+[0-9]*$ ]]; then
        log_message "ERROR" "磁盘名称格式非法: ${disk}"
        echo "错误：磁盘名称 '${disk}' 格式非法，操作已终止。"
        return 1
    fi
    
    if [ ! -b "/dev/$disk" ]; then
        log_message "ERROR" "磁盘设备不存在: /dev/${disk}"
        echo "错误：磁盘设备 /dev/${disk} 不存在，操作已终止。"
        return 1
    fi
    
    # 二次确认：检查该设备确实是磁盘（而非分区、loop、ram等）
    local device_type
    device_type=$(lsblk -dno TYPE "/dev/$disk" 2>/dev/null)
    if [ "$device_type" != "disk" ]; then
        log_message "ERROR" "设备不是磁盘类型: /dev/${disk} (类型: ${device_type})"
        echo "错误：/dev/${disk} 不是磁盘设备（类型: ${device_type}），操作已终止。"
        return 1
    fi
    
    if [ -z "$cmd" ]; then
        log_message "ERROR" "不支持的文件系统类型: ${fs_type}"
        echo "错误：不支持的文件系统类型 '${fs_type}'"
        return 1
    fi
    
    log_message "INFO" "开始擦除磁盘签名: /dev/${disk}"
    wipefs -a "/dev/$disk"
    log_message "INFO" "磁盘签名擦除完成: /dev/${disk}"
    
    log_message "INFO" "开始格式化磁盘(${fs_type}): /dev/${disk}"
    echo "正在格式化为 ${fs_type} 文件系统..."
    if $cmd "/dev/$disk" 2>&1; then
        log_message "INFO" "格式化完成: /dev/${disk} (${fs_type})"
        echo "/dev/$disk 格式化完成 (${fs_type})。"
        return 0
    else
        log_message "ERROR" "格式化失败: /dev/${disk} (${fs_type})"
        echo "错误：/dev/$disk 格式化失败！"
        return 1
    fi
}

execute_action() {
    local disk=$1
    local fs_type
    
    if [ "$fs_mode" -eq 1 ]; then
        fs_type="$UNIFIED_FS"
    else
        fs_type=$(select_type "请选择 /dev/${disk} 的文件系统类型:")
    fi
    
    case "$confirm_mode" in
        1)
            echo "=================================================="
            echo "$(lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE,MODEL /dev/$disk)"
            echo "=================================================="
            confirm=$(validate_input "确定要格式化 /dev/$disk 为 ${fs_type} 吗？(y/N): " "^[yYnN]$" "n")
            if [[ "$confirm" =~ ^[yY]$ ]]; then
                log_message "INFO" "用户确认格式化磁盘: /dev/${disk}，文件系统: ${fs_type}"
                format_disk "$disk" "$fs_type"
            else
                log_message "INFO" "用户取消格式化磁盘: /dev/${disk}"
                echo "操作已取消。"
            fi
            ;;
        2)
            echo "自动格式化 /dev/$disk (${fs_type}) ..."
            log_message "INFO" "自动模式格式化磁盘: /dev/${disk}，文件系统: ${fs_type}"
            format_disk "$disk" "$fs_type"
            ;;
    esac
}

for disk in $(lsblk -dno NAME,TYPE | awk '$2=="disk" {print $1}'); do
    if [ "$disk" == "$SYS_DISK" ] ; then
        log_message "INFO" "跳过系统盘: /dev/${disk}"
        continue
    fi
    MOUNT_COUNT=$(lsblk -no MOUNTPOINT /dev/$disk | grep -c /)
    if [ "$MOUNT_COUNT" -eq 0 ]; then
        echo "发现需格式化磁盘: /dev/$disk"
        log_message "INFO" "发现需格式化磁盘: /dev/${disk}"
        execute_action "$disk"
    else
        echo "发现受保护磁盘: /dev/$disk ，自动跳过。"
        log_message "INFO" "跳过受保护磁盘(有挂载点): /dev/${disk}"
    fi
done

log_message "INFO" "脚本执行完毕"
