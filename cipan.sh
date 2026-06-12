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

# 检测用户是否输入 q 退出，若是则生成日志后优雅退出
check_quit() {
    local input=$1
    if [[ "$input" == "q" || "$input" == "Q" ]]; then
        log_message "INFO" "用户请求退出，生成 Merkle 树日志"
        generate_merkle_tree_log "$LOG_FILE" "$MERKLE_LOG_FILE"
        echo "用户请求退出，已生成日志。"
        exit 0
    fi
}

select_type() {
    local prompt=$1
    local fs_choice
    
    echo "" >&2
    echo "${prompt}" >&2
    echo "  1) xfs    (默认)" >&2
    echo "  2) ext4" >&2
    echo "  3) ext3" >&2
    echo "  4) ext2" >&2
    echo "  5) btrfs" >&2
    echo "  6) ntfs" >&2
    echo "  7) fat32" >&2
    fs_choice=$(validate_input "请输入编号 (1-7，默认 1，输入 q 退出): " "^[1-7qQ]$" "1")
    check_quit "$fs_choice"
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
confirm_mode=$(validate_input "请输入编号 (1-2，默认 1，输入 q 退出): " "^[12qQ]$" "1")
check_quit "$confirm_mode"

echo ""
echo "=================================================="
echo "            请选择文件系统指定方式                 "
echo "=================================================="
echo "  1) 统一格式 - 所有磁盘使用同一种文件系统"
echo "  2) 单次指定 - 每个磁盘单独选择文件系统"
echo "=================================================="
fs_mode=$(validate_input "请输入编号 (1-2，默认 1，输入 q 退出): " "^[12qQ]$" "1")
check_quit "$fs_mode"

# 统一格式模式：提前选择文件系统
UNIFIED_FS=""
if [ "$fs_mode" -eq 1 ]; then
    UNIFIED_FS=$(select_type "请选择所有磁盘的统一文件系统类型:")
    echo "已选择统一文件系统: ${UNIFIED_FS}"
fi

log_message "INFO" "脚本启动，确认模式: ${confirm_mode}，文件系统指定方式: ${fs_mode}，统一格式: ${UNIFIED_FS:-无}"

# 安全审查结束，业务开始
ROOT_DEV=$(findmnt -n -o SOURCE / || echo "")
if [ -z "$ROOT_DEV" ]; then
    log_message "ERROR" "无法识别根分区路径，脚本紧急终止！"
    echo "错误：无法获取根分区分区信息。"
    exit 1
fi

# 获取物理根磁盘名称
SYS_DISK=$(lsblk -no PKNAME "$ROOT_DEV" | head -n1 | xargs)
if [ -z "$SYS_DISK" ]; then
    SYS_DISK=$(basename "$ROOT_DEV")
fi
# 移除末尾的分区数字或 p+数字（如 nvme0n1p2 -> nvme0n1, sda1 -> sda）
SYS_DISK=$(echo "$SYS_DISK" | sed -E 's/p[0-9]+$//; s/[0-9]+$//')

if [ -z "$SYS_DISK" ]; then
    log_message "ERROR" "系统盘解析为空，脚本紧急终止！"
    echo "核心错误：无法安全识别系统盘，为防误抹除，脚本已退出。"
    exit 1
fi

log_message "INFO" "识别到当前系统盘为: /dev/${SYS_DISK}"

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
    
    if [[ ! "$disk" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_message "ERROR" "磁盘名称格式非法: ${disk}"
        echo "错误：磁盘名称 '${disk}' 格式不合规，跳过该设备。"
        return 1
    fi
    
    if [ ! -b "/dev/$disk" ]; then
        log_message "ERROR" "磁盘设备不存在: /dev/${disk}"
        echo "错误：磁盘设备 /dev/${disk} 不存在，操作已终止。"
        return 1
    fi
    
    # 二次确认：检查该设备确实是磁盘
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
    
    echo "正在检查并解除 /dev/${disk} 及其分区的占用状态..."
    
    # 获取该磁盘下的所有子设备（含磁盘本身）
    local all_devs
    all_devs=$(lsblk -nlo NAME "/dev/$disk" 2>/dev/null)
    
    # 1. 强制终止进程并卸载 (由内向外：先处理分区，再处理磁盘)
    # 使用 tac 倒序处理，确保先处理最底层的挂载点
    while IFS= read -r dev_name; do
        local mp
        mp=$(lsblk -no MOUNTPOINT "/dev/$dev_name" 2>/dev/null | grep -v "^$")
        if [ -n "$mp" ]; then
            log_message "INFO" "正在终止占用 /dev/${dev_name} 进程并解除挂载: ${mp}"
            # 严格按照：杀进程 -> 正常卸载 -> 强制卸载 的顺序
            fuser -km "$mp" 2>/dev/null || true
            sleep 1
            umount "$mp" 2>/dev/null || true
            if mountpoint -q "$mp"; then
                umount -f "$mp" 2>/dev/null || true
            fi
        fi
    done <<< "$(echo "$all_devs" | tac)"
    
    # 2. 清理 Swap/LVM/MD 占用 (在删除分区表前必须先停用这些)
    # 关闭 Swap
    if command -v swapon &>/dev/null; then
        while IFS= read -r dev_name; do
            if swapon --show 2>/dev/null | grep -q "$dev_name"; then
                log_message "INFO" "检测到交换分区使用 /dev/${dev_name}，正在关闭..."
                swapoff "/dev/$dev_name" 2>/dev/null || true
            fi
        done <<< "$all_devs"
    fi
    
    # 移除 LVM
    if command -v dmsetup &>/dev/null; then
        for dm_dev in $(dmsetup ls 2>/dev/null | awk '{print $1}'); do
            if dmsetup table "$dm_dev" 2>/dev/null | grep -q "$disk"; then
                log_message "INFO" "检测到 LVM/dm 设备 ${dm_dev} 使用 /dev/${disk}，正在移除..."
                dmsetup remove "$dm_dev" 2>/dev/null || true
            fi
        done
    fi
    
    # 停止 MD 阵列
    if command -v mdadm &>/dev/null; then
        for md_dev in /dev/md*; do
            if [ -b "$md_dev" ]; then
                if mdadm --detail "$md_dev" 2>/dev/null | grep -q "$disk"; then
                    log_message "INFO" "检测到 md 设备 ${md_dev} 使用 /dev/${disk}，正在停止..."
                    mdadm --stop "$md_dev" 2>/dev/null || true
                fi
            fi
        done
    fi
    
    sleep 2

    # 再次验证是否彻底无挂载
    if lsblk -no MOUNTPOINT "/dev/$disk" 2>/dev/null | grep -q '/'; then
        log_message "ERROR" "/dev/${disk} 仍有分区处于挂载状态，放弃格式化"
        echo "错误：/dev/${disk} 卸载失败，出于安全考虑放弃格式化。"
        return 1
    fi

    # 3. 彻底擦除文件系统签名与分区表
    log_message "INFO" "开始擦除磁盘签名与分区表: /dev/${disk}"
    echo "正在擦除 /dev/${disk} 的分区和签名数据..."
    
    # 先擦除所有魔数签名
    wipefs -a -f "/dev/$disk" 2>/dev/null || true
    
    # 销毁分区表（优先用 sgdisk，处理 GPT 最彻底）
    if command -v sgdisk &>/dev/null; then
        sgdisk -Z "/dev/$disk" 2>/dev/null || true
    else
        # 没有 sgdisk 时，用 dd 擦除头部，并尝试擦除尾部(GPT备份表)
        dd if=/dev/zero of="/dev/$disk" bs=1M count=30 status=none 2>/dev/null || true
        local disk_size_blocks
        disk_size_blocks=$(blockdev --getsz "/dev/$disk" 2>/dev/null || echo 0)
        if [ "$disk_size_blocks" -gt 0 ]; then
            # 计算倒数第 30MB 的位置
            local seek_pos=$(( disk_size_blocks * 512
