#!/bin/bash
# 加载安全保护模块（自动执行安全检查）
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
source "${SCRIPT_DIR}/security.sh"

# 移除了 set -e 避免误杀，但保留 -u (未定义变量拦截) 和 -o pipefail (管道报错拦截)
set -uo pipefail

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
SYS_DISK=$(lsblk -no PKNAME "$ROOT_DEV" | head -n1 | xargs || true)
if [ -z "$SYS_DISK" ]; then
    SYS_DISK=$(basename "$ROOT_DEV" || true)
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
    
    # 磁盘基础校验
    if [ -z "$disk" ] || [[ ! "$disk" =~ ^[a-zA-Z0-9_-]+$ ]] || [ ! -b "/dev/$disk" ]; then
        log_message "ERROR" "磁盘参数异常或不存在: /dev/${disk}"
        echo "错误：磁盘参数异常或不存在: /dev/${disk}"
        return 1
    fi
    
    echo "正在检查并解除 /dev/${disk} 的占用状态..."
    
    # 获取该磁盘下的所有子设备，倒序处理保证先卸载底层分区
    local all_devs
    all_devs=$(lsblk -nlo NAME "/dev/$disk" 2>/dev/null || true)
    
    # 1. 常规卸载逻辑（不再死磕守护进程）
    while IFS= read -r dev_name; do
        [ -z "$dev_name" ] && continue
        local mp
        mp=$(lsblk -no MOUNTPOINT "/dev/$dev_name" 2>/dev/null | grep -v "^$" || true)
        if [ -n "$mp" ]; then
            log_message "INFO" "解除挂载分区: /dev/${dev_name} (挂载点: ${mp})"
            umount "$mp" 2>/dev/null || true
            # 如果普通卸载失败，尝试一次强制卸载
            if mountpoint -q "$mp"; then
                umount -f "$mp" 2>/dev/null || true
            fi
        fi
    done <<< "$(echo "$all_devs" | tac)"
    
    # 2. 清理基本的 LVM / MD / Swap 占用
    if command -v swapon &>/dev/null; then
        while IFS= read -r dev_name; do
            [ -z "$dev_name" ] && continue
            swapon --show 2>/dev/null | grep -q "$dev_name" && swapoff "/dev/$dev_name" 2>/dev/null || true
        done <<< "$all_devs"
    fi
    
    if command -v dmsetup &>/dev/null; then
        for dm_dev in $(dmsetup ls 2>/dev/null | awk '{print $1}' || true); do
            dmsetup table "$dm_dev" 2>/dev/null | grep -q "$disk" && dmsetup remove "$dm_dev" 2>/dev/null || true
        done
    fi

    # 3. 验证是否仍被占用（如果卸载不掉，说明有应用正使用，直接跳过保护）
    if lsblk -no MOUNTPOINT "/dev/$disk" 2>/dev/null | grep -q '/'; then
        log_message "ERROR" "/dev/${disk} 卸载失败，仍处于占用状态，放弃格式化"
        echo "跳过：/dev/${disk} 仍被系统占用，无法安全卸载。"
        return 1
    fi

    # 4. 擦除磁盘签名与分区表
    log_message "INFO" "开始擦除磁盘签名与分区表: /dev/${disk}"
    echo "正在擦除 /dev/${disk} 的分区和签名数据..."
    
    # 擦除文件系统魔数
    if ! wipefs -a -f "/dev/$disk" 2>/dev/null; then
        log_message "WARN" "wipefs 执行遇到异常，尝试继续: /dev/${disk}"
    fi
    
    # 擦除 GPT/MBR 结构
    if command -v sgdisk &>/dev/null; then
        sgdisk -Z "/dev/$disk" >/dev/null 2>&1 || true
    else
        dd if=/dev/zero of="/dev/$disk" bs=1M count=30 status=none 2>/dev/null || true
    fi
    sync

    # 5. 通知系统内核和 udev 刷新状态（核心防脱节逻辑，不可省略）
    blockdev --flushbufs "/dev/$disk" 2>/dev/null || true
    
    if command -v partprobe &>/dev/null; then
        partprobe "/dev/$disk" 2>/dev/null || true
    else
        blockdev --rereadpt "/dev/$disk" 2>/dev/null || true
    fi
    
    # 等待 udev 后台任务完成，防止与 mkfs 抢锁
    sleep 2
    if command -v udevadm &>/dev/null; then
        udevadm settle --timeout=5 2>/dev/null || true
    fi
    
    # 6. 执行格式化
    echo "正在格式化为 ${fs_type} 文件系统..."
    log_message "INFO" "执行格式化指令: $cmd /dev/$disk"
    
    if $cmd "/dev/$disk" 2>&1; then
        log_message "INFO" "格式化完成: /dev/${disk} (${fs_type})"
        echo "✅ /dev/$disk 格式化完成 (${fs_type})。"
        return 0
    else
        log_message "ERROR" "格式化失败: /dev/${disk} (${fs_type})"
        echo "❌ 错误：/dev/$disk 格式化失败！"
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
            echo "$(lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE,MODEL /dev/$disk || true)"
            echo "=================================================="
            confirm=$(validate_input "确定要格式化 /dev/$disk 为 ${fs_type} 吗？(y/N)，输入 q 退出: " "^[yYnNqQ]$" "n")
            check_quit "$confirm"
            if [[ "$confirm" =~ ^[yY]$ ]]; then
                log_message "INFO" "用户确认格式化磁盘: /dev/${disk}，文件系统: ${fs_type}"
                format_disk "$disk" "$fs_type"
            else
                log_message "INFO" "用户取消格式化磁盘: /dev/${disk}"
                echo "操作已取消。"
            fi
            ;;
        2)
            echo "--------------------------------------------------"
            echo "自动格式化 /dev/$disk (${fs_type}) ..."
            log_message "INFO" "自动模式格式化磁盘: /dev/${disk}，文件系统: ${fs_type}"
            format_disk "$disk" "$fs_type"
            ;;
    esac
}

for disk in $(lsblk -dno NAME,TYPE 2>/dev/null | awk '$2=="disk" {print $1}' || true); do
    if [ "$disk" == "$SYS_DISK" ] ; then
        log_message "INFO" "跳过当前运行系统物理盘: /dev/${disk}"
        continue
    fi
    
    if lsblk -no MOUNTPOINT "/dev/$disk" 2>/dev/null | grep -E -q "^/+$|^/boot"; then
        log_message "WARN" "拒绝操作：在 /dev/${disk} 上检测到关键系统挂载点！"
        echo "拦截：/dev/${disk} 包含系统核心挂载点。"
        continue
    fi

    echo ""
    echo "发现可操作目标磁盘: /dev/$disk"
    execute_action "$disk"
done

# 脚本正常结束，生成 Merkle 树日志
generate_merkle_tree_log "$LOG_FILE" "$MERKLE_LOG_FILE"
log_message "INFO" "脚本执行完毕"
