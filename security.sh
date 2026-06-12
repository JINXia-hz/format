#!/bin/bash

# ============================================================
# 安全保护模块
# ============================================================

# 1红、2绿、3黄、4蓝、5紫、6青、7白
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
VIOLET=$(tput setaf 5)
YELLOW=$(tput setaf 3)
BOLD=$(tput bold)
RESET=$(tput sgr0)

# 避免无聊的警告
warning=(
    "${VIOLET}ADITUS PROHIBITUS${RESET}"
    "${RED}${BOLD}YOU SHALL NOT PASS${RESET}"
    "${YELLOW}${BOLD}ILS NE PASSERONT PAS${RESET}"
)

# 刑不可知则威不可测
timeunite=(29 31 37 41)

# 17个，需要确保时间增量，步数和面壁词个数互质，从而保证能够从任意一个位置开始，触发任意一条面壁词，避免用户无聊
mianbi=(
    "你盯着墙上的划痕，突然悟出了独孤九剑的第一式，剑法 +1" 
    "你看到一个老者舞剑，福至心灵，剑法 +2" 
    "你找到日月魔教长老遗泽，不过扉页写着「欲练此功，必先……」你赶紧塞了过去" 
    "后山瀑布轰鸣，你借瀑布练掌，掌法熟练度 +10" 
    "你面壁时突然气血翻涌，竟然打通了任督二脉，内力上限 +50" 
    "你静坐思过，进入了‘天人合一’的玄妙境界，悟性 +1" 
    "小师妹偷偷跑来找你，塞给你一个热乎的烤地瓜，心情 +5，饱食度 +10" 
    "大师兄路过，看你可怜，丢下一本《九阳神功》（翻开发现其实是《金瓶梅》），内功 -5" 
    "你试图在石壁上刻一个‘忍’字，结果因为字太丑，心情 -1" 
    "一只呆头鹅从你面前走过，你和它深情对视了半个时辰，身法毫无变化，但精神状态存疑" 
    "隔壁师弟在大喊大叫，似乎是因为偷看人家洗衣服被抓进来的，八卦之魂 +10" 
    "面壁时间太长，你站起来时腿麻了，直接摔了个狗啃泥，身法 -5" 
    "一只蚊子一直在你耳边嗡嗡叫，你一巴掌拍在自己脸上，生命值 -1，羞耻度 +10" 
    "后山风大，你着凉了，触发状态【风寒】：每秒有 5% 概率打个大喷嚏" 
    "你试图模仿绝世高手在石壁上留下掌印，结果用力过猛，手骨骨折，力量 -2" 
    "坐禅时睡着了，口水流了一地，浸湿了刚藏好的秘籍，秘籍字迹模糊度 +80%" 
    "一只神雕飞过，扔下一条蛇，你剖开仔细一看，蛇腹里包裹着一颗‘九转断肠红’，毒抗 +20" 
    "山壁突然崩塌一角，露出一具骷髅，膝下有一卷残破羊皮纸，你获得了【未知残卷】" 
    "猴群看你可怜，从树上丢下来几个野果，虽然有点酸，但内力隐隐有所触动"
)

# 日志文件路径
LOG_FILE="/var/log/disk_format.log"
LOG_PREV_HASH="0000000000000000000000000000000000000000000000000000000000000000"

# 便于阅读的日志文件路径
MERKLE_LOG_FILE="/var/log/disk_format.mtree"

log_message() {
    local level=$1
    local message=$2
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local log_line="[${timestamp}] [${level}] ${message}"
    local current_hash=$(printf "%s" "${LOG_PREV_HASH}${log_line}" | sha256sum | awk '{print $1}')
    printf "%s\n  └─ hash: %s\n  └─ prev: %s\n" "${log_line}" "${current_hash}" "${LOG_PREV_HASH}" >> "$LOG_FILE"
    LOG_PREV_HASH="$current_hash"
}

get_hash() { #系统哈希
    local seed derive_path
    seed=$(ip link show | grep -E "link/ether" | head -1 | awk '{print $2}')
    if [ -z "$seed" ]; then
        seed=$(cat /etc/machine-id 2>/dev/null || cat /sys/class/dmi/id/product_uuid 2>/dev/null || echo "unknown")
    fi
    derive_path="$1"
    echo "${seed}:${derive_path}" | md5sum | cut -c1-8 #保护父码不泄露
}

CREDIT=$(get_hash "Credit/0")
STATE_FILE="/etc/.disk_format_state${CREDIT}"
SECRET_SALT=$(get_hash "Salt/0") #文件签名盐
trap '' INT TERM TSTP HUP QUIT PIPE #捕捉陷阱

get_signature() { #文件签名
    local ack=$1
    local status=$2
    local lock_until=$3
    local violation_count=$4
    printf "%s" "${ack}:${status}:${lock_until}:${violation_count}:${SECRET_SALT}" | md5sum | awk '{print $1}'
}

save_state() { #唯二操作点，另一个是前尘云烟散
    local ack=$1
    local status=$2
    local lock_until=$3
    local violation_count=$4
    local sig=$(get_signature "$ack" "$status" "$lock_until" "$violation_count")
    chattr -i "$STATE_FILE" 2>/dev/null
    echo "${ack}:${status}:${lock_until}:${violation_count}:${sig}" > "$STATE_FILE"
    chattr +i "$STATE_FILE" 2>/dev/null #避免有意或无意的鲁莽删除
}

generate_merkle_tree_log() {
    local log_file=$1
    local merkle_file=$2
    local leaf_hashes=()
    local log_lines=()
    
    while IFS= read -r log_line && IFS= read -r hash_line && IFS= read -r prev_line; do
        local recorded_hash="${hash_line#*hash: }"
        leaf_hashes+=("$recorded_hash")
        log_lines+=("$log_line")
    done < "$log_file"
    
    local total=${#leaf_hashes[@]}
    
    {
        for ((i=0; i<total; i++)); do
            echo "[$((i+1))] ${log_lines[$i]}"
        done
        
        echo ""
        echo "========== Merkle Tree =========="
        
        for ((i=0; i<total; i++)); do
            printf "Leaf[%d]: %s\n" "$i" "${leaf_hashes[$i]}"
        done

        local current_level=("${leaf_hashes[@]}")
        local level=0
        local empty_hash=$(printf "" | sha256sum | awk '{print $1}')
        
        while [ ${#current_level[@]} -gt 1 ]; do
            local next_level=()
            local count=${#current_level[@]}
            
            if (( count % 2 == 1 )); then
                current_level+=("$empty_hash")
                ((count++))
            fi
            
            for ((i=0; i<count; i+=2)); do
                local combined=$(printf "%s%s" "${current_level[$i]}" "${current_level[$i+1]}" | sha256sum | awk '{print $1}')
                next_level+=("$combined")
                printf "Node[%d][%d]: %s\n" "$level" "$((i/2))" "$combined"
            done
            
            current_level=("${next_level[@]}")
            ((level++))
        done
        
        # 写入根节点
        printf "Root:        %s\n" "${current_level[0]}"
        echo "================================="
        
    } > "$merkle_file"
}

punishment(){ #思过崖在这里
    IFS=":" read -r ACK STATUS LOCK COUNT SIG < "$STATE_FILE"
    if [ "$ACK" != "1" ];then #防御性写法，避免可能的攻击
        log_message "ERROR" "punishment() 中 ACK 校验失败，异常退出"
        exit 1
    fi
    NOW=$(date +%s)
    local current_duration=$(( LOCK - NOW ))
    local workcount
    # 摇骰子决定是否要PoW重置罪孽
    LOGI=$(awk -v vc="${COUNT}" 'BEGIN {k=0.8; printf "%.0f", 40 / (1 + exp(-k*(vc-10)))}')
    ROUND=$(( ((COUNT % 5) + 1) / 3  )) #👈随着犯错导致log数量增加，可读性下降，我们希望在不改变期望的同时提升某次概率生成新日志
    TRIGGER_CHANCE=$(( ROUND * LOGI ))
    ROLL=$(( RANDOM % 100 ))
    
    if [ "$ROLL" -lt "$TRIGGER_CHANCE" ] || [ "$current_duration" -lt "0" ]; then #这里捕捉比0还小的刑期，肯定作弊了
        log_message "PoW" "预期接收McTLog，违规记数: ${COUNT}，当前刑期剩余: ${current_duration}秒"
        printf "\n${RED}${BOLD}【天谴】触发隐藏律令。死罪可免，活罪难逃！${RESET}\n"
        
        printf "天字号犯人 %s 入狱。本关考研你审核能力" "$(whoami)"
        HEAVY_LOCK_DURATION=$(( 301 * COUNT ))
        SL_LOCK_UNTIL=$(( NOW + HEAVY_LOCK_DURATION ))
        save_state "$ACK" "PUNISHED" "$SL_LOCK_UNTIL" "$COUNT"
        START_TIME=$(date +%s)
        for (( loop=1; loop<=COUNT; loop++ )); do
            workcount=0
            while IFS= read -r log_line && IFS= read -r hash_line && IFS= read -r prev_line; do
                recorded_hash="${hash_line#*hash: }"
                recorded_prev="${prev_line#*prev: }"
                calc_hash=$(printf "%s" "${recorded_prev}${log_line}" | sha256sum | awk '{print $1}')
                if [ "$calc_hash" != "$recorded_hash" ]; then
                    echo "胆大包天，竟敢篡改生死簿，即刻打散魂魄，褫夺许可，投入轮回！"
                    (( COUNT *= 2 ))
                    save_state "0" "CHEAT" "0" "$COUNT"
                    log_message "CLOSED" "检测到哈希链出错，已经封档"
                    mv "$LOG_FILE" "${LOG_FILE%.*}${calc_hash}.${LOG_FILE##*.}"
                    log_message "DETECTED" "检测到哈希链出错，已经存档"
                    echo "前尘云烟散！"
                    exit 1
                else
                    (( workcount++ ))
                    if (( workcount % 20 == 0 )) && (( COUNT > 0 )); then
                        (( COUNT-- ))
                    fi
                fi
            done < "$LOG_FILE"
        done
        
        # 生成可读性更高的新日志
        log_message "McTLog" "新日志生成，立照"
        generate_merkle_tree_log "$LOG_FILE" "$MERKLE_LOG_FILE"
        ordre=$(( RANDOM % ${#LOG_PREV_HASH} ))
        ordre_chif=${LOG_PREV_HASH:$ordre:1}
        truerandom=$(printf "%d" "0x${ordre_chif:-0}")
        saverandom=$(( truerandom + 1 ))
        (( COUNT = COUNT >= saverandom ? COUNT - saverandom : 0 ))
        
        END_TIME=$(date +%s)
        ELAPSED=$(( END_TIME - START_TIME ))
        log_message "INFO" "PoW 徭役完成，耗时 ${ELAPSED}秒，违规记数: ${COUNT}"
        printf "\n${GREEN}【出狱】历经 ${ELAPSED} 会元，你洗刷了罪孽${RESET}\n"
        CK_LOCK_UNTIL=$(( LOCK - HEAVY_LOCK_DURATION ))
        NOW=$(date +%s)
        current_duration=$(( CK_LOCK_UNTIL - NOW ))
        if [ "$current_duration" -lt "0" ]; then
            save_state "$ACK" "FORGIVED" "$CK_LOCK_UNTIL" "$COUNT"
        else
            log_message "INFO" "进入面壁，时长: ${current_duration}秒，违规记数: ${COUNT}"
            echo "将你赶去思过崖面壁 $current_duration 秒。"
            for ((i=current_duration; i>0; i-=5)); do
                printf "\r\033[K%s" "${mianbi[$((i % ${#mianbi[@]}))]}"
                sleep 5
            done
            save_state "$ACK" "FORGIVED" "0" "$COUNT" #这就可以再去运行了
            log_message "INFO" "面壁结束，状态已重置为 FORGIVED"
            printf "\n面壁结束\n"
            exit 0
        fi
        exit 0
    else
        log_message "INFO" "进入面壁，时长: ${current_duration}秒，违规记数: ${COUNT}"
        echo "将你赶去思过崖面壁 $current_duration 秒。"
        for ((i=current_duration; i>0; i-=5)); do
            printf "\r\033[K%s" "${mianbi[$((i % ${#mianbi[@]}))]}"
            sleep 5
        done
        save_state "$ACK" "FORGIVED" "0" "$COUNT" #这就可以再去运行了
        log_message "INFO" "面壁结束，状态已重置为 FORGIVED"
        printf "\n面壁结束\n"
        exit 0
    fi
}

signfile(){
    log_message "INFO" "首次运行，进入契约签署流程"
    echo "=================================================="
    echo "            首次运行：使用说明与风险提示            "
    echo "=================================================="
    echo "1. 本脚本用于格式化非系统分区的磁盘（XFS 文件系统）。"
    echo "2. 模式 1 为【交互模式】，格式化前会要求您输入 y 确认。"
    echo "3. 模式 2 为【自动模式】，将直接格式化所有非系统分区磁盘"
    echo "⚠⚠⚠ 格式化操作不可逆，数据将永久丢失。误删或任何惩罚性程序之意外皆系用户责任，于本程序无关"
    echo "=================================================="
    echo ""
    read -p "若已明确责任并知晓风险，请输入 'yes' 签署声明: " ack_input
    
    if [ "$ack_input" = "yes" ]; then
        # 用户输入 yes，创建契约
        log_message "INFO" "用户签署免责声明，创建契约"
        printf "%s声明自己承当运行程序一切后果，立契存照，于%s。\n" "$(whoami)" "$(date +"%Y-%m-%d %H:%M:%S" )"
        if [ -f "$STATE_FILE" ]; then
            IFS=":" read -r ACK STATUS LOCK VIOLATION_COUNT SIG < "$STATE_FILE"
        else
            LOCK=0
            VIOLATION_COUNT=0
        fi
        ACK=1
        save_state "$ACK" "ACKNOWLEGED" "$LOCK" "$VIOLATION_COUNT"
        echo "再次声明，格式化操作不可逆，数据将永久丢失，望慎之又慎。"
        echo "请重新运行脚本并携带参数1或2（如：./script.sh 1）或不携带则默认为1，不要输入其他字符，勿谓言之不预也。"
        exit 0
    else
        # 输入不是 yes，添加惩罚
        log_message "WARN" "用户拒绝签署免责声明，触发惩罚"
        echo "拒绝签署免责声明。"
        ACK=0
        VIOLATION_COUNT=5
        NOW=$(date +%s)
        LOCK_DURATION=$((31 * VIOLATION_COUNT))
        LOCK_UNTIL=$((NOW + LOCK_DURATION))
        save_state "$ACK" "REJECTED" "$LOCK_UNTIL" "$VIOLATION_COUNT" #这里不进入惩罚反正进去也因为ACK=0直接跳掉
        exit 1
    fi
}

# ============================================================
# 程序入口 - 状态检查
# ============================================================
security_init() {
    if [ -f "$STATE_FILE" ]; then
        IFS=":" read -r ACK STATUS LOCK VIOLATION_COUNT SIG < "$STATE_FILE"
        if [ "$ACK" != 1 ]; then
            signfile
            exit 1
        fi
        log_message "INFO" "检测到状态文件，状态: ${STATUS}，违规记数: ${VIOLATION_COUNT}"
        CALC_SIG=$(get_signature "$ACK" "$STATUS" "$LOCK" "$VIOLATION_COUNT")
        if [ "$SIG" != "$CALC_SIG" ]; then
            log_message "WARN" "状态文件签名校验失败，违规记数: ${VIOLATION_COUNT}，触发惩罚"
            (( VIOLATION_COUNT = ( VIOLATION_COUNT + 5 ) * 2 ))
            NOW=$(date +%s)
            first_hex_sig=${SIG:0:1}
            dec_val=$(printf "%d" "0x$first_hex_sig")
            use_val=$((dec_val % 4))
            unite=${timeunite[$use_val]}
            LOCK_DURATION=$((unite * VIOLATION_COUNT))
            NEW_LOCK_UNTIL=$((NOW + LOCK_DURATION))
            STATUS="PUNISHED"
            save_state "$ACK" "$STATUS" "$NEW_LOCK_UNTIL" "$VIOLATION_COUNT"
        fi

        NOW=$(date +%s)

        if [ "$STATUS" == "PUNISHED" ]; then
            REMAINING=$((LOCK - NOW))
            UNLOCK_TIME=$(date -d "@$LOCK" "+%Y-%m-%d %H:%M:%S")
            idx=$((VIOLATION_COUNT % ${#warning[@]})) 
            log_message "INFO" "检测到惩罚状态，剩余: ${REMAINING}秒，违规记数: ${VIOLATION_COUNT}"
            printf "%s\n" "${warning[$idx]}"
            echo "历史违规记数: $VIOLATION_COUNT 次"
            echo "解封倒计时: $REMAINING 秒 (具体解封时间: $UNLOCK_TIME)"
            punishment
            exit 1
        fi
    else
        signfile
        exit 1
    fi
}

security_init

validate_input() {
    local prompt=$1
    local pattern=$2
    local default=$3
    local max_retry=${4:-3}
    local input
    local attempt=0
    
    while [ "$attempt" -lt "$max_retry" ]; do
        read -p "${prompt}" input
        input="${input:-$default}"
        
        if [[ "$input" =~ $pattern ]]; then
            echo "$input"
            return 0
        fi
        
        attempt=$((attempt + 1))
        local remain=$((max_retry - attempt))
        
        if [ "$remain" -gt 0 ]; then
            echo "输入无效，请重新输入（剩余 ${remain} 次机会）"
        fi
    done
    
    # 超过重试次数，触发惩罚
    log_message "WARN" "多次无效输入，触发惩罚机制"
    ((VIOLATION_COUNT++))
    echo "恶意输入 (￣︿￣) 成功激怒系统。"
    NOW=$(date +%s)
    bitri_sig=${SIG:1:2}
    dec_val=$(printf "%d" "0x${bitri_sig:-0}")
    use_val=$((dec_val % 4))
    unite=${timeunite[$use_val]}
    LOCK_DURATION=$((unite * VIOLATION_COUNT))
    NEW_LOCK_UNTIL=$((NOW + LOCK_DURATION))
    save_state "$ACK" "PUNISHED" "$NEW_LOCK_UNTIL" "$VIOLATION_COUNT"
    punishment
    exit 1
}
