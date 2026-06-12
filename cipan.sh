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
    
    echo "" >&2
    echo "${prompt}" >&2
    echo "  1) xfs    (默认)" >&2
    echo "  2) ext4" >&2
    echo "  3) ext3" >&2
    echo "  4) ext2" >&2
    echo "  5) btrfs" >&2
    echo "  6) ntfs" >&2
    echo "  7) fat32" >&2
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
    
    echo "正在检查并解除 /dev/${disk} 及其分区的挂载状态..."
    # 获取该磁盘下的所有子设备（分区）
    local parts
    parts=$(lsblk -nlo NAME "/dev/$disk" 2>/dev/null)
    # 第一行是磁盘本身，跳过；其余是分区
    local part_found=false
    while IFS= read -r dev_name; do
        if [ "$part_found" = false ]; then
            part_found=true
            continue
        fi
        local mp
        mp=$(lsblk -no MOUNTPOINT "/dev/$dev_name" 2>/dev/null)
        if [ -n "$mp" ]; then
            log_message "INFO" "正在解除挂载分区: /dev/${dev_name} (挂载点: ${mp})"
            umount -l "/dev/$dev_name" 2>/dev/null || true
            fuser -km "/dev/$dev_name" 2>/dev/null || true
            umount -f "/dev/$dev_name" 2>/dev/null || true
        fi
    done <<< "$parts"
    
    # 再尝试卸载磁盘本身
    local disk_mp
    disk_mp=$(lsblk -no MOUNTPOINT "/dev/$disk" 2>/dev/null)
    if [ -n "$disk_mp" ]; then
        log_message "INFO" "正在解除挂载磁盘: /dev/${disk} (挂载点: ${disk_mp})"
        umount -l "/dev/$disk" 2>/dev/null || true
        fuser -km "/dev/$disk" 2>/dev/null || true
        umount -f "/dev/$disk" 2>/dev/null || true
    fi
    
    # 等待设备释放
    sleep 3
    
    # 再次验证是否彻底无挂载
    if lsblk -no MOUNTPOINT "/dev/$disk" 2>/dev/null | grep -q '/'; then
        log_message "ERROR" "/dev/${disk} 仍有分区处于挂载状态，放弃格式化"
        echo "错误：/dev/${disk} 卸载失败，出于安全考虑放弃格式化。"
        return 1
    fi

    log_message "INFO" "开始擦除磁盘签名: /dev/${disk}"
    
    # 检查是否有 LVM/dm 设备使用该磁盘
    if command -v dmsetup &>/dev/null; then
        for dm_dev in $(dmsetup ls 2>/dev/null | awk '{print $1}'); do
            if dmsetup table "$dm_dev" 2>/dev/null | grep -q "$disk"; then
                log_message "INFO" "检测到 LVM/dm 设备 ${dm_dev} 使用 /dev/${disk}，正在移除..."
                dmsetup remove "$dm_dev" 2>/dev/null || true
            fi
        done
    fi
    # 检查是否有 mdadm 设备使用该磁盘
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
    # 检查是否有交换分区使用该磁盘
    if command -v swapon &>/dev/null; then
        if swapon --show 2>/dev/null | grep -q "$disk"; then
            log_message "INFO" "检测到交换分区使用 /dev/${disk}，正在关闭..."
            swapoff "/dev/$disk" 2>/dev/null || true
            for part in $(lsblk -nlo NAME "/dev/$disk" 2>/dev/null); do
                swapoff "/dev/$part" 2>/dev/null || true
            done
        fi
    fi
    sleep 1
    
    # 先尝试用 wipefs 擦除签名
    if wipefs -a "/dev/$disk" 2>/dev/null; then
        log_message "INFO" "wipefs 擦除签名完成: /dev/${disk}"
    else
        log_message "WARN" "wipefs 擦除失败，尝试用 dd 清除磁盘头部..."
        dd if=/dev/zero of="/dev/$disk" bs=1M count=10 status=progress 2>/dev/null || {
            log_message "ERROR" "dd 清除磁盘头部也失败: /dev/${disk}"
            echo "错误：无法清除 /dev/${disk} 的磁盘签名，设备可能仍被占用。"
            return 1
        }
        log_message "INFO" "dd 清除磁盘头部完成: /dev/${disk}"
        sync
        blockdev --rereadpt "/dev/$disk" 2>/dev/null || true
        sleep 2
        wipefs -a "/dev/$disk" 2>/dev/null || true
    fi
    log_message "INFO" "磁盘签名擦除完成: /dev/${disk}"
    
    log_message "INFO" "开始格式化磁盘(${fs_type}): /dev/${disk}"
    echo "正在格式化为 ${fs_type} 文件系统..."
    # 刷新内核块设备缓冲区，确保内核释放对旧文件系统的引用
    blockdev --flushbufs "/dev/$disk" 2>/dev/null || true
    sleep 1
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
        log_message "INFO" "跳过当前运行系统物理盘: /dev/${disk}"
        continue
    fi
    
    if lsblk -no MOUNTPOINT "/dev/$disk" | grep -E -q "^/+$|^/boot"; then
        log_message "WARN" "拒绝操作：在 /dev/${disk} 上检测到关键系统挂载点！"
        echo "拦截：/dev/${disk} 包含系统核心挂载点。"
        continue
    fi

    echo ""
    echo "发现可操作目标磁盘: /dev/$disk"
    execute_action "$disk"
done

log_message "INFO" "脚本执行完毕"
