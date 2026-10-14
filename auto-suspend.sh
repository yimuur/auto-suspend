#!/usr/bin/env bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
#
# /usr/local/sbin/auto-suspend.sh
#
# 功能：基于状态机 (FSM) 的自动休眠脚本
# 特点：
# 1. 显式状态管理：ACTIVE (活跃), IDLE (空闲), SUSPENDING (准备休眠), COOLDOWN (唤醒冷却)
# 2. 多维度指标：CPU 负载、机械硬盘 IO、固态硬盘 IO、网络流量、用户登录
# 3. 流量/IO 阈值自动学习，异常唤醒自动保护，休眠窗口可调，休眠冷却期
# 4. Fail-safe：任何异常（如配置、权限或环境问题）都不会触发休眠
# 5. 可观测性，状态转换时记录具体原因

set -u             # 遇到未定义变量时报错并退出
set -o pipefail    # 管道命令中任何子命令失败，整个管道返回非零值

# 路径设置
STATE_DIR="/run/auto-suspend"       # 状态存储目录（内存中）

STATE_FILE="$STATE_DIR/state"       # 状态持久化文件路径
LOCK_FILE="$STATE_DIR/lock"         # lock 文件路径
DISABLE_FILE="$STATE_DIR/disable"   # disable 文件路径

LOG_TAG="auto-suspend"              # 日志标签，方便 journalctl 过滤

# =========================================================
# 核心函数：日志（定义在文件前部，供 load_config 等早期逻辑调用）
# =========================================================
log() {
    # 将信息发送至 systemd 日志系统，带上指定标签
    systemd-cat -t "$LOG_TAG" echo "$*"
}

color_log() {
    # 1. 安全检查：如果没有参数，直接返回（防止 set -u 报错）
    [ $# -eq 0 ] && return 0

    local level="$1"
    shift # 移除级别参数，剩下的全是消息

    # 2. 组合消息：将剩下的参数组合成字符串
    local message="$*"

    # 3. 验证级别
    case "$level" in
        emerg|alert|crit|err|warning|notice|info|debug) ;;
        *) printf 'invalid log level: %s\n' "$level" >&2; return 1 ;;
    esac

    # 4. journald 输出（机器看）
    # 这里的 || true 防止管道破裂导致脚本退出
    printf '%s\n' "$message" | systemd-cat -p "$level" -t "$LOG_TAG" || true

    # 5. 终端彩色输出（人看）
    # 只有当标准输出连接到终端时才显示颜色
    if [ -t 1 ]; then
        case "$level" in
            emerg|alert|crit|err)
                printf '\033[1;31m[%s] %s\033[0m\n' "$level" "$message" >&2 ;;   # 红色加粗
            warning)
                printf '\033[1;33m[%s] %s\033[0m\n' "$level" "$message" >&2 ;;   # 黄色加粗
            notice)
                printf '\033[1;32m[%s] %s\033[0m\n' "$level" "$message" >&2 ;;   # 绿色加粗（journal 显示白色加粗）
            info)
                printf '\033[1;34m[%s] %s\033[0m\n' "$level" "$message" >&2 ;;   # 蓝色加粗（journal 显示普通白色）
            debug)
                printf '\033[0;36m[%s] %s\033[0m\n' "$level" "$message" >&2 ;;   # 青色
        esac
    fi
}

mkdir -p "$STATE_DIR" || exit 0     # 建立文件夹（顶层 return 在脚本执行时非法，统一用 exit 兜底）

# 使用文件锁防止多实例同时运行
# 将锁文件放入子目录，避免污染 /run 根目录且符合权限设定
exec 9>"$LOCK_FILE" || exit 0
flock -n 9 || exit 0

# 全局使能/禁止选项，可建立 touch /run/auto-suspend/disable 文件禁止脚本
[[ -f "$DISABLE_FILE" ]] && exit 0

# =========================================================
# 配置加载函数（从 JSON 文件读取配置）
# =========================================================
# 优先级：default.json -> config.json（覆盖）-> 内置 fallback 值

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 配置目录解析（部署后与 Web UI 共用同一份 config）：
# 1) 优先 systemd 单元注入的 AUTO_SUSPEND_CONFIG_DIR；
# 2) 否则默认本脚本同目录 config/；
# 3) 兜底：若默认位置没有配置，回退到 Web 安装目录，使手动运行（未注入环境变量）
#    也能读到 Web 写入的 config.json，避免“Web 改了配置 shell 不生效”。
WEB_CONFIG_DIR="/usr/local/share/auto-suspend/web/config"
CONFIG_DIR="${AUTO_SUSPEND_CONFIG_DIR:-$SCRIPT_DIR/config}"
if [[ ! -f "$CONFIG_DIR/default.json" && -f "$WEB_CONFIG_DIR/default.json" ]]; then
    CONFIG_DIR="$WEB_CONFIG_DIR"
fi
DEFAULT_CONFIG="$CONFIG_DIR/default.json"
USER_CONFIG="$CONFIG_DIR/config.json"

load_config() {
    # 检查是否安装了 jq
    if ! command -v jq >/dev/null 2>&1; then
        # jq 缺失会导致无法读取 JSON 配置，必须显式告警（否则静默回退内置值难以排查）
        color_log warning "！警告：未安装 jq，脚本无法读取配置文件，将使用内置默认值"
        return 0
    fi

    set +u  # 临时关闭严格模式

    # 1. 加载 default.json
    if [[ -f "$DEFAULT_CONFIG" ]]; then
        _load_config_jq "$DEFAULT_CONFIG"
    fi

    # 2. 加载 config.json（覆盖）
    if [[ -f "$USER_CONFIG" ]]; then
        _load_config_jq "$USER_CONFIG"
    fi

    set -u
}

# 使用 jq 解析 JSON 配置
_load_config_jq() {
    local config_file="$1"
    SUSPEND_ENABLED=$(jq -r '.general.suspend_enabled.value // "true"' "$config_file" 2>/dev/null || echo "true")
    ALLOW_HDD_STANDBY=$(jq -r '.general.allow_hdd_standby.value // "true"' "$config_file" 2>/dev/null || echo "true")
    DISABLE_BLUETOOTH=$(jq -r '.general.disable_bluetooth.value // "true"' "$config_file" 2>/dev/null || echo "true")
    DISABLE_USB_WAKEUP=$(jq -r '.general.disable_usb_wakeup.value // "true"' "$config_file" 2>/dev/null || echo "true")
    SUSPEND_HOUR_START=$(jq -r '.suspend_window.hour_start.value // 0' "$config_file" 2>/dev/null || echo "0")
    SUSPEND_HOUR_END=$(jq -r '.suspend_window.hour_end.value // 24' "$config_file" 2>/dev/null || echo "24")
    CHECK_INTERVAL_MIN=$(jq -r '.check_interval.minutes.value // 5' "$config_file" 2>/dev/null || echo "5")
    CHECK_INTERVAL_SEC=$(jq -r '.check_interval.seconds.value // 300' "$config_file" 2>/dev/null || echo "300")
    IDLE_MINUTES_REQUIRED=$(jq -r '.idle_detection.idle_minutes_required.value // 60' "$config_file" 2>/dev/null || echo "60")
    RESUME_COOLDOWN_MIN=$(jq -r '.idle_detection.resume_cooldown_minutes.value // 300' "$config_file" 2>/dev/null || echo "300")
    LEARN_WINDOW=$(jq -r '.learning_parameters.learn_window.value // 60' "$config_file" 2>/dev/null || echo "60")
    SAFETY_FACTOR=$(jq -r '.learning_parameters.safety_factor.value // 120' "$config_file" 2>/dev/null || echo "120")
    MIN_NET=$(jq -r '.network_thresholds.min_net.value // 409600' "$config_file" 2>/dev/null || echo "409600")
    MAX_NET=$(jq -r '.network_thresholds.max_net.value // 20971520' "$config_file" 2>/dev/null || echo "20971520")
    NET_ACTIVITY_FLOOR=$(jq -r '.network_thresholds.net_activity_floor.value // 5242880' "$config_file" 2>/dev/null || echo "5242880")
    MIN_HDD=$(jq -r '.hdd_thresholds.min_hdd.value // 128' "$config_file" 2>/dev/null || echo "128")
    MAX_HDD=$(jq -r '.hdd_thresholds.max_hdd.value // 4096' "$config_file" 2>/dev/null || echo "4096")
    MIN_SSD=$(jq -r '.ssd_thresholds.min_ssd.value // 2048' "$config_file" 2>/dev/null || echo "2048")
    MAX_SSD=$(jq -r '.ssd_thresholds.max_ssd.value // 20480' "$config_file" 2>/dev/null || echo "20480")
    CPU_LOAD_MAX=$(jq -r '.cpu_thresholds.cpu_load_max.value // "0.8"' "$config_file" 2>/dev/null || echo "0.8")
    WEB_ACCESS_LOG=$(jq -r '.web_access.web_access_log.value // "/usr/trim/nginx/logs/access.log"' "$config_file" 2>/dev/null || echo "/usr/trim/nginx/logs/access.log")
    WEB_ACTIVE_WINDOW=$(jq -r '.web_access.web_active_window.value // 1800' "$config_file" 2>/dev/null || echo "1800")
}

# 调用配置加载函数
load_config

# =========================================================
# 内置默认配置参数（作为 fallback）
# =========================================================

SUSPEND_ENABLED=${SUSPEND_ENABLED:-true}
ALLOW_HDD_STANDBY=${ALLOW_HDD_STANDBY:-true}
DISABLE_BLUETOOTH=${DISABLE_BLUETOOTH:-true}
DISABLE_USB_WAKEUP=${DISABLE_USB_WAKEUP:-true}

SUSPEND_HOUR_START=${SUSPEND_HOUR_START:-0}
SUSPEND_HOUR_END=${SUSPEND_HOUR_END:-24}

CHECK_INTERVAL_MIN=${CHECK_INTERVAL_MIN:-5}
CHECK_INTERVAL_SEC=${CHECK_INTERVAL_SEC:-300}
IDLE_MINUTES_REQUIRED=${IDLE_MINUTES_REQUIRED:-60}
RESUME_COOLDOWN_MIN=${RESUME_COOLDOWN_MIN:-300}

LEARN_WINDOW=${LEARN_WINDOW:-60}
SAFETY_FACTOR=${SAFETY_FACTOR:-120}

MIN_NET=${MIN_NET:-409600}
MAX_NET=${MAX_NET:-20971520}
NET_ACTIVITY_FLOOR=${NET_ACTIVITY_FLOOR:-5242880}

MIN_HDD=${MIN_HDD:-128}
MAX_HDD=${MAX_HDD:-4096}

MIN_SSD=${MIN_SSD:-2048}
MAX_SSD=${MAX_SSD:-20480}

CPU_LOAD_MAX=${CPU_LOAD_MAX:-0.8}

WEB_ACCESS_LOG=${WEB_ACCESS_LOG:-/usr/trim/nginx/logs/access.log}
WEB_ACTIVE_WINDOW=${WEB_ACTIVE_WINDOW:-1800}

# ----------------------------
# HDD 休眠参数（不在配置文件中）
# ----------------------------
DISK_DIR="$STATE_DIR/disk"
MAP_FILE="$DISK_DIR/disk.map"
SAFE_FILE="$DISK_DIR/SAFE_TO_RESUME"
UMOUNT_RETRY=2              # 卸载重试次数
UMOUNT_INTERVAL=3           # 两次卸载间隔 s

VERSION="Ver: 2.0"          # 脚本版本号
DISKSTATS=""                # 全局变量，保存当前周期的磁盘读写数据快照

# 检查全局休眠开关
[[ "$SUSPEND_ENABLED" == "true" ]] || exit 0


# 计算系统自启动以来的单调递增时间
now_uptime() {
    cut -d. -f1 /proc/uptime
}

# =========================================================
# FSM 状态定义，STATE_FILE 初始化
# =========================================================
# ACTIVE | IDLE | SUSPENDING | COOLDOWN
STATE="ACTIVE"
STATE_TS=0
IDLE_DURATION=0
REQUEST_SUSPEND_TS=0
LAST_RESUME_TS=0
SUSPEND_FAIL_CNT=0

# =========================================================
# 状态持久化函数
# =========================================================
load_state() {
    # 如果状态文件不存在，直接返回默认值
    [[ -f "$STATE_FILE" ]] || {
        color_log debug "======【自动休眠程序已启动 [${VERSION}]，系统开始监测...】======"
        return 0
    }
    # 按行解析 key=value 格式的文件
    while IFS='=' read -r k v; do
        case "$k" in
            STATE)
                case "$v" in
                    ACTIVE|IDLE|SUSPENDING|COOLDOWN)
                        STATE="$v"
                        ;;
                    *)
                        STATE="ACTIVE"    # 验证合法性，不在已知列表内的状态一律强制重置为 ACTIVE
                        ;;
                esac
                ;;
            # 对时间戳和时长变量进行数字校验后赋值
            STATE_TS|IDLE_DURATION|REQUEST_SUSPEND_TS|LAST_RESUME_TS|SUSPEND_FAIL_CNT)
                [[ "$v" =~ ^[0-9]+$ ]] && declare -g "$k=$v"
                ;;
            *)
                # 忽略未知字段，防止污染 FSM
                ;;
        esac
    done < "$STATE_FILE"

    # ---- 完整性修复（sanity）----
    # STATE_TS 使用 epoch 秒（与 REQUEST_SUSPEND_TS/LAST_RESUME_TS 同基准），
    # 供 Web UI 状态倒计时（state_ts + 所需时间 - 当前时间）正确计算
    : "${STATE_TS:=${EPOCHSECONDS:-$(date +%s)}}"
    : "${IDLE_DURATION:=0}"
    : "${SUSPEND_FAIL_CNT:=0}"
}

save_state() {
    mkdir -p "$STATE_DIR" || return 0   # 建立文件夹
    # 覆盖写入当前的 FSM 状态变量，原子写入
    local tmp="$STATE_FILE.tmp"
    cat <<EOF > "$tmp" && mv "$tmp" "$STATE_FILE"
STATE=$STATE
STATE_TS=$STATE_TS
IDLE_DURATION=$IDLE_DURATION
REQUEST_SUSPEND_TS=$REQUEST_SUSPEND_TS
LAST_RESUME_TS=$LAST_RESUME_TS
SUSPEND_FAIL_CNT=$SUSPEND_FAIL_CNT
EOF
}

set_state() {
    local new="$1"           # 传入的新状态
    local tag="$2"           # 状态标签（如 [IDLE] / [BUSY] [CPU] / [ERROR]），作为日志前缀
    local reason="$3"        # 获取状态改变的原因
    local snapshot="${4:-}"  # 如有，获取状态改变时 metric 判忙的详细参数快照
    local now dur level

    [[ "$STATE" == "$new" ]] && return 0     # 状态相同则不处理

    # STATE_TS 采用 epoch 秒（与 REQUEST/LAST 同基准，供 Web UI 倒计时使用）
    now=${EPOCHSECONDS:-$(date +%s)}
    # 首次运行/重启后 STATE_TS 为 0：此时没有“上次变更时间”，间隔按 已开机时间 处理，
    # 避免把系统运行时长误报为“间隔 X 分钟”
    if (( STATE_TS > 0 )); then
        dur=$(( (now - STATE_TS) / 60 ))
    else
        dur=$(( now_uptime() / 60 ))
    fi

    # 根据状态标签推导日志级别（写入 journald PRIORITY，供 Web UI 按级别着色）：
    # 错误/异常唤醒 → err/warning，准备休眠 → notice，用户活动(SSH/WEB) → debug，其余 → info
    case "$tag" in
        *ERROR*)   level="err" ;;
        *RESUMED*) level="warning" ;;
        *SUSPENDING*) level="notice" ;;
        *USER*)    level="debug" ;;
        *)         level="info" ;;
    esac

    if [[ -n "$snapshot" ]]; then
        color_log "$level" "${tag} FSM: ${STATE} -> ${new} 【间隔 ${dur} 分钟 | ${reason} | ${snapshot}】"    # 记录状态转换
    else
        color_log "$level" "${tag} FSM: ${STATE} -> ${new} 【间隔 ${dur} 分钟 | ${reason}】"
    fi

    STATE="$new"
    STATE_TS="$now"     # 更新状态变更的时间点
}

# =========================================================
# 环境条件判断
# =========================================================
within_suspend_window() {
    # 判断当前小时是否在设定的可休眠时段内
    local h
    h=$((10#$(date +%H)))      # 获取当前小时，并强制转为十进制

    # 24小时全天候允许的情况
    (( SUSPEND_HOUR_START == 0 && SUSPEND_HOUR_END == 24 )) && return 0

    if (( SUSPEND_HOUR_START <= SUSPEND_HOUR_END )); then
        # 常规时间段（如 2:00 - 18:00）
        (( h >= SUSPEND_HOUR_START && h < SUSPEND_HOUR_END ))
    else
        # 跨天时间段（如 22:00 - 次日 6:00）
        (( h >= SUSPEND_HOUR_START || h < SUSPEND_HOUR_END ))
    fi
}

cooldown_active() {
    # 检查系统是否仍处于唤醒后的保护冷却期
    (( LAST_RESUME_TS > 0 )) || return 1
    local now=${EPOCHSECONDS:-$(date +%s)}
    (( now - LAST_RESUME_TS < RESUME_COOLDOWN_MIN * 60 ))
}

# 自动转换函数，支持从 Byte 转换到最高 PB 的单位，并保留两位小数
format_bytes() {
    local bytes=${1:-0}

    # 防御非法输入
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0

    awk -v b="$bytes" 'BEGIN {
        split("B KB MB GB TB PB", unit, " ");
        if (b == 0) {
            print "0 B";
            exit;
        }

        i = int(log(b) / log(1024));
        if (i > 5) i = 5;   # 防止超过 PB 越界

        if (i == 0)
            printf "%d %s\n", b, unit[1];
        else
            printf "%.2f %s\n", b / (1024 ^ i), unit[i + 1];
    }'
}

# =========================================================
# 阈值学习函数
# =========================================================
learn_threshold() {
    local file="$1"
    local value="$2"
    local min="$3"
    local max="$4"
    local -n outvar="$5"    # -n 创建一个引用，操作 outvar 就等于操作传入的变量

    # 1. 写入数据（时间戳 + 数值，空格分隔；图表据此还原实际时间并标记忙期）
    # 阈值学习（下方 P90 计算）不受状态限制，保持原有学习口径。
    # P90 阈值在本函数末尾追加到该行最后一列（先写时间戳+数值，算完后再补写）
    echo "$(date +%s) $value" >> "$file"

    # 2. 维护窗口（防止文件无限增长）
    # 定期清理，在这里简单做一下 tail，超出 20 行后再一次性清理，减少 I/O 操作，提高效率
    if (( $(wc -l < "$file") > (LEARN_WINDOW + 20) )); then
        tail -n "$LEARN_WINDOW" "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    fi

    # 3. 获取行数
    local count
    count=$(wc -l < "$file")
    # 样本太少时不计算，直接返回（使用上一次的值）；该行 P90 列设为 "min"
    if (( count < 24 )); then
        sed -i "${count}s/$/ $min/" "$file"
        return 0
    fi

    # ---------------------------------------------------------
    # 核心修改：计算 P90
    # ---------------------------------------------------------

    # 步骤 A: 计算 90% 位置的行号 (索引)
    # 公式: index = count * 0.9 (Shell 只有整数运算，所以 *9/10)
    local idx=$(( count * 90 / 100 ))

    # 兜底: 如果算出来是 0 (样本极少时)，修正为 1
    (( idx == 0 )) && idx=1

    # 步骤 B: 排序并取出该位置的值
    # sort -k2,2n : 按第 2 列（数值）排序；sed -n Np 取第 N 个；awk 提取数值列
    local p
    p=$(sort -k2,2n "$file" | sed -n "${idx}{p;q}" | awk '{print $2}')

    # ---------------------------------------------------------

    # 4. 应用安全因子 (Safety Factor)
    # 此时 p 是 P90，我们通常希望阈值比 P90 再高一点点，比如 1.1 或 1.2 倍
    local learned
    learned=$(( p * SAFETY_FACTOR / 100 ))

    # 5. 边界限制 (Clamping)
    (( learned < min )) && learned=$min
    (( learned > max )) && learned=$max

    # 6. 将本次采样点计算完的 P90 阈值追加到该行最后一列（供 web 直接读取显示，不再另算）
    sed -i "${count}s/$/ $learned/" "$file"

    # 7. 输出
    outvar=$learned
}

# =========================================================
# metric 输出统一变量
# =========================================================
# metric 忙时统一输出示例：BUSY=1 TYPE=HDD LEVEL=WARN REASON="disk io active" SNAPSHOT="io=120 iops"
# 调用 reset_metric_out 函数重置变量
reset_metric_out() {
    METRIC_BUSY=0       # 0 - 闲，1 - 忙
    METRIC_TYPE=""
    METRIC_LEVEL=""
    METRIC_REASON=""
    METRIC_SNAPSHOT=""
}

# =========================================================
# 指标采集 (Metrics) - 确保不产生副作用
# =========================================================

metric_cpu() {
    # 检查 Load Average 是否低于设定阈值
    local load

    load=$(awk '{print $2}' /proc/loadavg 2>/dev/null) || load=0
    if awk -v l="$load" -v m="$CPU_LOAD_MAX" 'BEGIN{exit !(l>m)}'; then    # 调用 awk 比较小数
        METRIC_BUSY=1
        METRIC_TYPE="CPU"
        METRIC_LEVEL="BUSY"
        METRIC_REASON="近 ${CHECK_INTERVAL_MIN} 分钟内 CPU 利用率 ${load}%"
        METRIC_SNAPSHOT="固定阈值 = ${CPU_LOAD_MAX}%"
    fi
}

# 统一读取 diskstats，一次完成
read_diskstats() {
    # 遍历所有块设备目录
    for dev_path in /sys/class/block/*; do
        # 确保路径存在（防止 glob 匹配失败）
        [[ -e "$dev_path" ]] || continue

        # 获取设备名（如 sda, nvme0n1）
        local dev="${dev_path##*/}"

        # --- 过滤逻辑 ---
        # 1. 只处理整盘，跳过分区：检查是否存在 /sys/class/block/DEVICE/partition 文件
        [[ -e "$dev_path/partition" ]] && continue

        # 2. 排除虚拟设备：回环盘(loop)、内存盘(ram/zram)、Device Mapper(dm-)、RAID(md)
        [[ "$dev" =~ ^(loop|ram|zram|dm-|md|nbd) ]] && continue

        # 3. 确保 stat 文件存在并可读
        [[ ! -f "$dev_path/stat" ]] && continue
        [[ -f "/sys/class/block/$dev/queue/rotational" ]] || continue

        # --- 数据提取 ---
        # /sys/block/DEVICE/stat 文件的列定义：
        # 使用 printf "%.0f" 强制输出为十进制整数，避免 1.23e+08 格式
        # $3 为读扇区，$7 为写扇区
        awk -v d="$dev" '{printf "%s %.0f\n", d, ($3 + $7)}' "$dev_path/stat"
    done
}

# 判断并处理累积型 metric 的时间跨度异常（spike rebase）
# 参数：$1:路径, $2:当前值, $3:周期（s）, $4:prev 输出引用
rebase_if_gap() {
    local prev_file="$1"
    local cur="$2"
    local interval="$3"
    local -n prev_out="$4"    # -n 创建一个引用
    local last_update prev_val
    local now="${EPOCHSECONDS:-$(date +%s)}"

    # 1. 基础存在性检查
    if [[ ! -f "$prev_file" ]]; then
        echo "$cur" > "$prev_file"
        return 0 # 首次运行，告知上层跳过判定
    fi

    # 2. 提取上次保存数据的时间戳
    last_update=$(stat -c %Y "$prev_file" 2>/dev/null || echo 0)
    read -r prev_val < "$prev_file" 2>/dev/null || prev_val="-1"

    # 3. 健壮性校验：处理内容损坏或非法时间戳
    if [[ ! "$prev_val" =~ ^[0-9]+$ ]] || (( last_update <= 0 )); then
        echo "$cur" > "$prev_file"
        return 0
    fi

    # 4. 时间跨度校验
    local delta_t=$(( now - last_update ))

    if (( delta_t > interval * 3 / 2 )); then
        # 发现 Spike 风险：由于高优先级指标阻塞导致采样点断档
        # log "[SPIKE] ${prev_file##*/}: gap=$((delta_t/60))m, rebase and skip spike"
        echo "$cur" > "$prev_file"
        return 0  # 通过退出状态码（0 代表重置/跳过，1 代表正常）
    fi

    # 5. 校验通过，向引用变量同步 prev_val 值，供上层计算 io
    prev_out="$prev_val"
    echo "$cur" > "$prev_file"

    return 1     # 正常状态，可以进行 io 计算和学习
}

metric_hdd() {
    local name cur prev io threshold
    local -A seen=()   # 记录本轮出现的 HDD
    local busy=0       # 繁忙标志，0 = 闲，1 = 忙
    local busy_hdd="" busy_th=0
    local busy_io=0
    local current_dev_list=""

    [[ -z "$DISKSTATS" ]] && return 0           # 无磁盘数据则直接退出函数，不报错

    # 扫描机械硬盘：每个硬盘 IO 阈值独立判断
    while read -r name cur; do
        [[ "$(cat /sys/class/block/$name/queue/rotational)" == "1" ]] || continue

        seen["$name"]=1     # ★ 标记该 HDD 本轮存在

        # 将所有检测到的 HDD 名称拼成一个字符串（如 sda,sdb），后续直接对比指纹决定是否清除缓存
        current_dev_list="${current_dev_list}${name},"

        # 时间窗口校验,解决长延时累积产生的 Spike 问题,如果是首次运行或时间断档，直接跳过
        rebase_if_gap "$STATE_DIR/hdd.$name.prev" "$cur" "$CHECK_INTERVAL_SEC" prev && continue

        io=$(( cur - prev ))
        (( io < 0 )) && { log "[HDD] Counter < 0, reset to 0"; io=0; }     # ★ 防御：计数器回绕 / 接口丢失 / 重置

        # 学习阈值参数
        threshold=$MIN_HDD
        learn_threshold "$STATE_DIR/hdd.$name.samples" \
            "$io" "$MIN_HDD" "$MAX_HDD" threshold

        # 机械硬盘非常灵敏：只要有一块盘 io > threshold 就标记繁忙(1)
        if (( io > threshold )); then
            busy=1
            busy_io="$io"
            busy_hdd="$name"
            busy_th="$threshold"
        fi
    done <<< "$DISKSTATS"

    local last_dev_list=""
    [[ -f "$STATE_DIR/hdd.device.finger" ]] && last_dev_list=$(cat "$STATE_DIR/hdd.device.finger")

    # 清理未出现的 HDD 缓存
    if [[ "$current_dev_list" != "$last_dev_list" ]]; then
        # 只有在设备列表发生变动时（增加、移除、热插拔）才执行清理循环
        local file dev
        for file in "$STATE_DIR"/hdd.*.{prev,samples}; do
            [[ -e "$file" ]] || continue

            dev="${file##*/}"   # 1. ##*/ 去掉路径：hdd.sda.prev
            dev="${dev#*.}"     # 2. #*. 去掉第一个点及其左边：sda.prev
            dev="${dev%.*}"     # 3. %.* 去掉最后一个点及其右边：sda (不论后缀是 .prev 还是 .samples 都通用)

            [[ -n "${seen[$dev]:-}" ]] && continue

            log "[HDD] ${dev} removed, clean cache ${file##*/}"
            rm -f "$file" 2>/dev/null || true
        done
        # 更新指纹文件
        echo "$current_dev_list" > "$STATE_DIR/hdd.device.finger"
    fi

    local busy_io_bytes=$(( busy_io * 512 ))  # sector -> bytes
    local busy_th_bytes=$(( busy_th * 512 ))

    if (( busy == 1 )); then
        METRIC_BUSY=1             # 0 - 闲，1 - 忙
        METRIC_TYPE="HDD(${busy_hdd})"
        METRIC_LEVEL="BUSY"
        METRIC_REASON="机械硬盘读写总量：$(format_bytes "$busy_io_bytes")/${CHECK_INTERVAL_MIN}m"
        METRIC_SNAPSHOT="HDD(${busy_hdd})=$(format_bytes "$busy_th_bytes")"
    fi
}

metric_ssd() {
    local name cur prev io total=0
    local threshold=$MIN_SSD
    local -A seen=()   # 记录本轮出现的 SSD
    local current_dev_list=""

    [[ -z "$DISKSTATS" ]] && return 0                   # 无磁盘数据则直接退出函数，不报错

    # 扫描 SSD 活动：允许在设定的阈值内存在少量 IO 活动
    while read -r name cur; do
        [[ "$(cat /sys/class/block/$name/queue/rotational)" == "0" ]] || continue

        seen["$name"]=1     # ★ 标记该 SSD
        # 将所有检测到的 SSD 名称拼成一个字符串（如 nvme0n1,nvme1n1），后续直接对比指纹决定是否清除缓存
        current_dev_list="${current_dev_list}${name},"

        # 时间窗口校验,解决长延时累积产生的 Spike 问题,如果是首次运行或时间断档，直接跳过本轮
        rebase_if_gap "$STATE_DIR/ssd.$name.prev" "$cur" "$CHECK_INTERVAL_SEC" prev && continue

        io=$(( cur - prev ))
        (( io < 0 )) && { log "[SSD] Counter < 0, reset to 0"; io=0; }        # ★ 防御：计数器回绕 / 接口丢失 / 重置

        total=$(( total + io ))
    done <<< "$DISKSTATS"           # 使用 Here-string，比进程替换在处理空值时更稳

    # 阈值学习
    (( total > 0 )) && learn_threshold "$STATE_DIR/ssd.samples" \
                            "$total" "$MIN_SSD" "$MAX_SSD" threshold

    local last_dev_list=""
    [[ -f "$STATE_DIR/ssd.device.finger" ]] && last_dev_list=$(cat "$STATE_DIR/ssd.device.finger")

    # 清理未出现的 SSD 缓存
    if [[ "$current_dev_list" != "$last_dev_list" ]]; then
        # 只有在设备列表发生变动时（增加、移除、热插拔）才执行清理循环
        local file dev
        for file in "$STATE_DIR"/ssd.*.prev; do
            [[ -e "$file" ]] || continue        # [[ -e ]] 检查防止 glob 匹配不到文件时返回原始字符串

            dev="${file##*/}"   # ssd.nvme0n1.prev
            dev="${dev#*.}"     # nvme0n1.prev
            dev="${dev%.*}"     # nvme0n1

            [[ -n "${seen[$dev]:-}" ]] && continue

            log "[SSD] ${dev} removed, clean cache ${file##*/}"
            rm -f "$file" 2>/dev/null || true
        done

        # 更新指纹文件
        echo "$current_dev_list" > "$STATE_DIR/ssd.device.finger"
    fi

    local total_bytes=$(( total * 512 ))  # sector -> bytes
    local threshold_bytes=$(( threshold * 512 ))

    if (( total > threshold )); then
        METRIC_BUSY=1             # 0 - 闲，1 - 忙
        METRIC_TYPE="SSD"
        METRIC_LEVEL="BUSY"
        METRIC_REASON="固态硬盘读写总量：$(format_bytes "$total_bytes")/${CHECK_INTERVAL_MIN}m"
        METRIC_SNAPSHOT="SSD=$(format_bytes "$threshold_bytes")"
    fi
}

metric_net() {
    # 采集网络活动：使用白名单模式 (Allowlist)
    # 仅匹配物理网卡前缀：
    # - en* : 涵盖 eno1 (板载), enp3s0 (PCIe), ens33 (虚拟化透传)
    # - eth* : 涵盖传统命名 eth0
    # - wl* : 涵盖无线网卡 wlan0, wlp2s0 (如果需要监控 Wi-Fi)
    # - br* : 网桥用户：如果有 br0 (Bridge)
    # - bond* : Bonding用户：如果是 bond0，流量可能主要体现在 bond 接口上
    local cur prev io=0
    local threshold=$MIN_NET

    # 1. 健壮的 awk 解析：处理接口名粘连问题
    # 使用 sub() 统一清理掉接口名及冒号，确保 $1 之后永远是纯数字
    # /proc/net/dev 的 NR > 2：跳过前两行表头，这是必须的，否则 awk 可能会尝试对字符串进行算术加法。
    cur=$(awk '
        NR > 2 {
            idx = index($0, ":")
            if (idx <= 0) next
            iface = substr($0, 1, idx - 1)
            gsub(/[ \t]+/, "", iface)       # 额外清理接口名两端的空格
            if (iface !~ /^(en|eth|wl|br|bond)/) next
            line = substr($0, idx + 1)
            n = split(line, f)
            if (n < 9) next
            sum += f[1] + f[9]
        }
        END { printf "%.0f", sum + 0 }   # <--- 这里：强制输出整数，避免科学计数法
    ' /proc/net/dev)

    # 2. 安全校验
    [[ "$cur" =~ ^[0-9]+$ ]] || cur=0

    # 时间窗口校验,解决长延时累积产生的 Spike 问题,如果是首次运行或时间断档，直接退出
    rebase_if_gap "$STATE_DIR/net.prev" "$cur" "$CHECK_INTERVAL_SEC" prev && return 0

    io=$(( cur - prev ))
    (( io < 0 )) && { log "[NET] Counter < 0, reset to 0"; io=0; }      # ★ 防御：计数器回绕 / 接口丢失 / 重置

    learn_threshold "$STATE_DIR/net.samples" \
        "$io" "$MIN_NET" "$MAX_NET" threshold

    # hard floor：只要网络流量在设置边界阈值以上，此次检测就判定为忙
    # 流量高于阈值则判定忙
    if (( io > NET_ACTIVITY_FLOOR || io > threshold )); then
        METRIC_BUSY=1             # 0 - 闲，1 - 忙
        METRIC_TYPE="NET"
        METRIC_LEVEL="BUSY"
        METRIC_REASON="网络总流量：$(format_bytes "$io")/${CHECK_INTERVAL_MIN}m"
        METRIC_SNAPSHOT="NET=$(format_bytes "$threshold")"
    fi
}

metric_ssh() {
    local found_user=""
    local threshold="${WEB_ACTIVE_WINDOW:-300}"
    local now="${EPOCHSECONDS:-$(date +%s)}"
    local last_atime=0

    # 1. 使用 awk 提取 UID(第2列) 、USER(第3列)和 TTY(最后1列)
    # 2. 使用进程替换 < <(...) 避免子 Shell 无法返回变量的问题
    while read -r u_id u_name u_tty; do
        [[ "$u_id" -ge 1000 ]] || continue
        [[ "$u_tty" =~ ^pts/[0-9]+$ ]] || continue

        local dev="/dev/$u_tty"
        [[ -e "$dev" ]] || continue    # 排除非活跃会话

        local atime
        atime=$(stat -c %X "$dev" 2>/dev/null) || continue

        if (( now - atime < threshold )); then
            # 只要发现一个活跃用户，记录并退出循环
            found_user="UID=$u_id USER=$u_name TTY=$u_tty"
            last_atime=$atime
            break
        fi
    done < <(loginctl list-sessions --no-legend 2>/dev/null | awk '{ print $2, $3, $NF }')

    if [[ -n "$found_user" ]]; then
        METRIC_BUSY=1             # 0 - 闲，1 - 忙
        METRIC_TYPE="SSH"
        METRIC_LEVEL="USER"
        METRIC_REASON="检测到 $(( (now - last_atime) / 60 )) 分钟前有 SSH 访问操作"
        METRIC_SNAPSHOT="${found_user}"
    fi
}

metric_web() {
    # 日志路径 fallback 设计
    local log="$WEB_ACCESS_LOG"
    [[ -f "$log" ]] || log="/usr/trim.old/nginx/logs/access.log"
    [[ -f "$log" ]] || return 0

    local window="${WEB_ACTIVE_WINDOW:-300}"
    local now="${EPOCHSECONDS:-$(date +%s)}"    # 防止在 Bash 4.x（Debian 10 / 老 NAS）下 直接退出脚本

    # 1. 优先判断文件修改时间，只有时间近才深入解析内容
    local last_mod
    last_mod=$(stat -c %Y "$log" 2>/dev/null) || return 0

    local dur=$(( now - last_mod ))
    if (( dur > window )); then
        return 0   # 文件长时间未更新，必然无 Web 活跃
    fi

    # 2. 扫描日志并提取关键信息文件有更新，只扫描最近 100 行
    local info
    info=$( tail -n 100 "$log" | awk -v now="$now" -v win="$window" '
        # awk的BEGIN块：创建月份缩写到数字的映射。例如，mon["Jan"]=1
        BEGIN {
            split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", m)
            for (i = 1; i <= 12; i++) mon[m[i]] = i
        }
        {
            # 匹配 [28/Jan/2026:17:19:25]，如匹配失败，则跳过该行
            # 兼容性写法：不使用 {n} 量词，不使用 match 的第三个参数
            # 正则合并到一行，增加对左方括号的匹配以提高精确度
            if (match($0, /\[[0-9][0-9]\/[A-Za-z][A-Za-z][A-Za-z]\/[0-9][0-9][0-9][0-9]:[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) {

                # RSTART+1 是为了跳过左方括号 "["
                # RLENGTH-1 是为了只取时间部分: 28/Jan/2026:17:19:25
                s = substr($0, RSTART + 1, RLENGTH - 1)

                # 按 / 和 : 分割
                split(s, t, "[:/]")

                # 将匹配到的时间转换为Unix时间戳，确保服务器 date 命令输出的时区与 Nginx 日志中的 +0800（或类似偏移）是一致的
                # t[1]=Day, t[2]=MonthStr, t[3]=Year, t[4]=H, t[5]=M, t[6]=S
                ts = mktime(sprintf("%d %02d %02d %02d %02d %02d",
                    t[3], mon[t[2]], t[1], t[4], t[5], t[6]))

                if (ts == 0 || now - ts > win)
                    next

                # 排除噪声（静态资源、健康检查及错误码）等非用户访问
                if ($0 ~ /(favicon|health|metrics|ping|\.js|\.css|\.png|\.woff|\.ico)/) next
                if ($0 ~ /"(HEAD|OPTIONS)/) next
                if ($9 ~ /^[45]/) next  # 排除 4xx 5xx 错误访问

                # --- 提取关键信息并输出 ---
                # $1: IP, $4: 时间, $6: 方法, $7: URL, $9: 状态码
                # 去掉 $4 中的左括号和 $6 中的左引号
                time_str = substr($4, 2)
                req = substr($6, 2)
                printf "用户[%s] 在 %s 通过 [%s] 请求了 %s (状态:%s)", $1, time_str, req, $7, $9

                found=1    # 命中真实 Web 活跃
                exit       # 提前结束输入
            }
        }
        END {exit !found}
    ')

    if [[ $? -eq 0 && -n "$info" ]]; then
        METRIC_BUSY=1             # 0 - 闲，1 - 忙
        METRIC_TYPE="WEB"
        METRIC_LEVEL="USER"
        METRIC_REASON="检测到 $((dur/60)) 分钟前有 WEB 访问记录"
        METRIC_SNAPSHOT="${info}"
    fi
}

# =========================================================
# 统一 busy 判断
# =========================================================
METRICS_SER=(
    # 用户登录、WEB 访问、CPU 忙 视为真实忙碌状态，不执行 net/ssd/hdd metrics
    # 串行组，优先级从高到低
    metric_ssh
    metric_web
    metric_cpu
)

METRICS_PAR=(
    # 只有当 无用户登录、无 WEB 访问、CPU 闲时（真实空闲时间），再判断 NET、SSD、HDD 是否空闲并学习阈值
    # 并行组，优先级相同
    metric_net
    metric_ssd
    metric_hdd
)

# 综合判断函数
is_busy() {
    local metric
    local reason="" snapshot=""
    local par_busy=0

    # 1. 第一阶段：高优先级串行检测 (SSH, WEB, CPU_LOAD 等)
    # 只要这里有一个忙，就直接判定为忙，不执行后续逻辑
    reset_metric_out
    for metric in "${METRICS_SER[@]}"; do
        "$metric"
        if (( METRIC_BUSY )); then
            return 0  # 状态机直接拿到当前的全局 METRIC_* 变量
        fi
    done

    # 2. 第二阶段：并行检测与学习 (NET, SSD, HDD 等)
    # 我们遍历完这一组，以便它们都能执行 rebase_if_gap 逻辑并更新计数器
    DISKSTATS=$(read_diskstats 2>/dev/null) || return 0   # 扫描所有 disk
    for metric in "${METRICS_PAR[@]}"; do
        reset_metric_out
        "$metric"
        if (( METRIC_BUSY )); then
            (( par_busy++ ))   # 正确的算术自增
            # 聚合忙碌信息，使用 ${VAR:-} 防止 set -u 报错
            reason="${reason}${METRIC_REASON:-无原因} & "
            snapshot="${snapshot}${METRIC_SNAPSHOT:-无快照}, "

            # 记录第一个忙碌项的状态，防止 par_busy=1 时信息丢失
            if (( par_busy == 1 )); then
                local first_type="$METRIC_TYPE"
                local first_level="$METRIC_LEVEL"
            fi
        fi
    done

    # 3. 如果并行组有忙碌项，统一封装后返回
    if (( par_busy > 0 )); then
        if (( par_busy > 1 )); then
            METRIC_TYPE="MULTI"
            METRIC_LEVEL="BUSY"
            METRIC_REASON="${reason% & }"   # 移除末尾的 " & "
            METRIC_SNAPSHOT="动态阈值：${snapshot%, }"   # 移除末尾的 ", "
        else
            # 只有一个任务忙碌，保留那个任务的原始类型和级别
            METRIC_TYPE="${first_type}"
            METRIC_LEVEL="${first_level}"
            METRIC_REASON="${reason% & }"
            METRIC_SNAPSHOT="动态阈值：${snapshot%, }"
        fi

        return 0
    fi

    # 4. 全都空闲
    return 1
}

# =========================================================
# 休眠前：解析 UUID -> 卸载 -> 停转
# =========================================================
hdd_standby() {
    mkdir -p "$DISK_DIR"

    if [[ -f "$SAFE_FILE" ]]; then
        color_log err "！错误：检测到上次休眠时残留的磁盘卸载信息，请手动处理并清空 [${DISK_DIR}] 文件夹"
        return 0
    fi

    : > "$MAP_FILE"

    local mounted_hdds=()
    # 主流程：逐条挂载点处理
    while read -r mnt src fstype _; do
        # 跳过特殊类型
        case "$fstype" in
            swap|*tmpfs|proc|sysfs|devpts|cgroup*|overlay|none|autofs) continue ;;
        esac

        local dev_path
        # 实际设备（可能是 /dev/sdb1 / devmapper）
        dev_path=$(findmnt -n -o SOURCE --target "$mnt") || continue
        [[ -b "$dev_path" ]] || continue

        # 获取详细信息（使用 -P 格式确保变量抓取准确）
        local lsblk_info
        local UUID PKNAME ROTA NAME

        lsblk_info=$(lsblk -n -o UUID,PKNAME,ROTA,NAME -P "$dev_path" | head -n1)

        # 提取变量
        eval "$lsblk_info"

        # 补全 pkname (如果本身就是物理盘)
        pk="${PKNAME:-$NAME}"
        # 过滤非机械盘
        [[ "$ROTA" == "1" ]] || continue
        # 必须有 UUID (作为唤醒锚点)
        [[ -z "$UUID" ]] && log "警告：${mnt} (${NAME}) 无 UUID，跳过管理" && continue

        mounted_hdds+=("$UUID|$pk|$mnt")

    done < <(findmnt -rn -o TARGET,SOURCE,FSTYPE)

    # 强制数据落盘，sync (全局)
    if ! timeout 8s sync; then
        color_log warning "警告：数据同步超时或失败，跳过磁盘管理"
        return 1
    fi

    # 关联数组：用于物理盘去重 (key: 物理盘名, value: 1=可停转, 0=需跳过)
    declare -A physical_disks

    # 尝试卸载
    for hdd in "${mounted_hdds[@]}"; do
        IFS='|' read -r uuid pk mnt <<< "$hdd"
        local umount_ok=0
        for ((i=1; i<=UMOUNT_RETRY; i++)); do
            if umount "$mnt" 2>/dev/null; then
                umount_ok=1
                break
            fi
            sleep "$UMOUNT_INTERVAL"
        done

        if [[ $umount_ok -eq 1 ]]; then
            # 核心：保存 UUID 和 挂载点
            echo "$uuid|$pk|$mnt" >> "$MAP_FILE"
            log "[HDD] 磁盘卸载成功：${mnt} (UUID=${uuid})"
            [[ -z "${physical_disks[$pk]:-}" ]] && physical_disks[$pk]=1
        else
            color_log warning "[HDD] 磁盘卸载失败：${mnt}，取消对应物理盘停转"
            physical_disks["$pk"]=0
        fi
    done

    udevadm settle --timeout=5
    sleep 0.5

    # 5. 物理停转 (仅当该盘所有分区都成功卸载时)
    local any_spun_down=0
    for disk in "${!physical_disks[@]}"; do
        if [[ "${physical_disks[$disk]}" == "1" ]]; then
            [[ -b "/dev/$disk" ]] || continue
            # 设置 NCQ = 1 稳定 resume + 低并发
            if echo 1 > /sys/block/$disk/device/queue_depth 2>/dev/null; then
                log "[HDD] 设置 ${disk}：NCQ = $(< /sys/block/${disk}/device/queue_depth)"
            fi
            sleep 0.2
            blockdev --flushbufs /dev/$disk 2>/dev/null
            # 下达停转指令
            if hdparm -y "/dev/$disk" >/dev/null 2>&1; then
                log "[HDD] 停转指令已下达：[/dev/${disk}]..."
                any_spun_down=1
                sleep 0.2
            fi
        fi
    done

    # 标记状态为安全，允许 Resume 阶段执行
    [[ $any_spun_down -eq 0 ]] && log "[HDD] 未停转任何 HDD"
    [[ $any_spun_down -eq 1 ]] && touch "$SAFE_FILE"
}

# =========================================================
# 尝试开启网卡 WOL，采用遍历机制（不依赖硬编码网卡名）和双层激活机制（系统层 PCIe 唤醒 + 网卡层 Magic Packet）
# =========================================================
try_enable_wol() {
    local iface wake ethtool_out wol_support wol_status cur_state

    for iface in /sys/class/net/*; do
        iface="${iface##*/}"
        [[ "$iface" == "lo" ]] && continue

        # 仅处理物理网卡
        [[ -e "/sys/class/net/$iface/device" ]] || continue

        # Layer 1: 系统层 ACPI / PCIe wakeup
        wake="/sys/class/net/$iface/device/power/wakeup"
        if [[ -w "$wake" ]]; then
            read -r cur_state < "$wake"
            if [[ "$cur_state" != "enabled" ]]; then
                echo enabled > "$wake" 2>/dev/null || true
                log "[WOL] SYS: Enabled ACPI wakeup for [${iface}]"
            fi
        fi

        # Layer 2: NIC 层 Wake-on-LAN
        command -v ethtool >/dev/null 2>&1 || continue

        # ★ 只调用一次 ethtool
        ethtool_out=$(ethtool "$iface" 2>/dev/null) || continue

        # 是否支持 Magic Packet
        wol_support=$(awk '/^[[:space:]]*Supports Wake-on:/ {print $NF}' <<<"$ethtool_out")
        if [[ "$wol_support" == "" || "$wol_support" == "d" ]]; then
            color_log warning "[WOL] NIC: 网卡 [${iface}] 不支持 Wake-on-LAN"
            continue
        fi

        if [[ "$wol_support" != *g* ]]; then
            color_log warning "[WOL] NIC: 网卡 [${iface}] 不支持 Magic Packet"
            continue
        fi

        # 当前 WoL 状态
        wol_status=$(awk '/^[[:space:]]*Wake-on:/ {print $NF}' <<<"$ethtool_out")

        # 仅在未开启时才设置 + 打日志
        if [[ "$wol_status" != "g" ]]; then
            ethtool -s "$iface" wol g >/dev/null 2>&1 || true
            sleep 0.2
            # 重新读取一次状态用于确认
            wol_status=$(ethtool "$iface" 2>/dev/null |
                         awk '/^[[:space:]]*Wake-on:/ {print $NF}')
            if [[ "$wol_status" == "g" ]]; then
                log "[WOL] NIC: Enabled Magic Packet for [${iface}]"
            fi
        fi
    done
}

# ============================================================
# 停用蓝牙 (通用解绑 + 模块卸载)，防止某些设备阻止系统进入睡眠
# ============================================================
disable_bluetooth_module() {
    # 停止服务
    systemctl stop bluetooth.service 2>/dev/null
    sleep 0.1

    local found_bt=false
    local btusb_loaded=false
    local btusb_bound=false
    local hci_present=false

    # 定位并解绑 USB 蓝牙硬件（防止父设备重复解绑）
    local unbound_devs=()
    for if_path in /sys/bus/usb/devices/*:*; do
        [[ -f "$if_path/bInterfaceClass" ]] || continue

        if [[ "$(<"$if_path/bInterfaceClass")" == "e0" ]] && \
           [[ "$(<"$if_path/bInterfaceSubClass")" == "01" ]]; then

            local dev="${if_path%:*}"
            dev="${dev##*/}"

            if [[ ! " ${unbound_devs[*]} " =~ " $dev " ]]; then
                echo "$dev" > /sys/bus/usb/drivers/usb/unbind 2>/dev/null
                log "[BT] 已解绑蓝牙模块: ${dev}"
                unbound_devs+=("$dev")
                found_bt=true
            fi
        fi
    done

    # btusb 模块是否加载
    [[ -d /sys/module/btusb ]] && btusb_loaded=true

    # btusb 是否真实绑定 USB 设备
    if [[ -d /sys/bus/usb/drivers/btusb ]]; then
        for dev in /sys/bus/usb/drivers/btusb/*-*; do
            [[ -e "$dev" ]] || continue       # [[ -e ]] 检查防止 glob 匹配不到文件时返回原始字符串
            [[ -e "$dev/uevent" ]] || continue
            btusb_bound=true
            break
        done
    fi

    # 是否仍存在 HCI 节点（蓝牙协议栈残留）
    ls /sys/class/bluetooth/hci* >/dev/null 2>&1 && hci_present=true

    # 情况 A：完全干净，无需处理
    if [[ "$found_bt" == "false" && \
          "$btusb_loaded" == "false" && \
          "$hci_present" == "false" ]]; then
        log "[BT] 未发现活跃的蓝牙模块"
        return 0
    fi

    # 情况 B：需要清理的异常态
    # - 驱动加载但无设备 (僵尸)
    # - 或者 HCI 节点还在 (残留)
    # - 或者刚刚执行了解绑 (确保清理)
    if [[ "$btusb_loaded" == "true" && "$btusb_bound" == "false" ]] || \
       [[ "$hci_present" == "true" ]] || \
       [[ "$found_bt" == "true" ]]; then

        log "[BT] 检测到异常状态，执行驱动清理 (loaded=${btusb_loaded} bound=${btusb_bound} hci=${hci_present})..."

        # 卸载驱动模块 (顺序: 协议栈 -> 底层)
        local bt_modules=("bnep" "rfcomm" "btrtl" "btintel" "btbcm" "btusb" "bluetooth")
        for mod in "${bt_modules[@]}"; do
            if lsmod | grep -q "^$mod"; then
                # 尝试卸载，如果失败则稍等 0.1s 再试一次（应对瞬时 busy）
                if modprobe -r "$mod" 2>/dev/null || \
                   (sleep 0.1 && modprobe -r "$mod" 2>/dev/null); then
                    log "[BT] 卸载驱动模块: ${mod}"
                    sleep 0.2
                fi
            fi
        done

        ! ls /sys/class/bluetooth/hci* >/dev/null 2>&1 && log "[BT] 蓝牙停用成功"
    else
        log "[BT] 无需操作"
    fi
}

# ============================================================
# 禁用 USB 唤醒 (状态检查 + 驱动链接验证)
# ============================================================
disable_usb_wakeup() {
    # 1 USB 设备级处理
    for dev in /sys/bus/usb/devices/*; do
        # 仅处理有活跃驱动绑定的设备
        [[ -L "$dev/driver" ]] || continue

        # 禁用唤醒（先确认文件存在再读取，避免对缺失文件产生 stderr 噪声）
        if [[ -f "$dev/power/wakeup" ]]; then
            local wakeup
            wakeup=$(<"$dev/power/wakeup")
            if [[ "$wakeup" != "disabled" ]]; then
                log "[USB] Device wakeup: ${dev##*/} [${wakeup}] -> [disabled]"
                echo "disabled" > "$dev/power/wakeup" 2>/dev/null
            fi
        fi

        # 设置电源模式为 auto (协助顺利休眠，解决 -16 错误)
        if [[ -f "$dev/power/control" ]]; then
            local control
            control=$(<"$dev/power/control")
            if [[ "$control" != "auto" ]]; then
                log "[USB] Power control: ${dev##*/} [${control}] -> [auto]"
                echo "auto" > "$dev/power/control" 2>/dev/null
            fi
        fi
    done

    # 2 USB Host Controller (PCI) wakeup (禁用控制器级唤醒)
    for pci_dev in /sys/bus/pci/devices/*; do
        [[ -L "$pci_dev/driver" ]] || continue
        local driver=$(basename "$(readlink "$pci_dev/driver")")

        case "$driver" in
            xhci_hcd|ehci-pci|ohci-pci|uhci-hcd)
                if [[ -f "$pci_dev/power/wakeup" ]] && [[ "$(<"$pci_dev/power/wakeup")" != "disabled" ]]; then
                    echo "disabled" > "$pci_dev/power/wakeup" 2>/dev/null
                    log "[USB] PCI HCD wakeup: ${pci_dev##*/} (${driver}) -> [disabled]"
                fi
                ;;
        esac
    done
}

hooks_before_suspend() {
    # 若配置允许，关闭蓝牙模块，防止影响休眠
    if [[ "$DISABLE_BLUETOOTH" == "true" ]]; then
        color_log notice "已设置休眠前停用蓝牙模块，扫描所有 Bluetooth Module..."
        disable_bluetooth_module
    fi

    # 若配置允许，禁止 USB 设备唤醒，防止异常唤醒
    if [[ "$DISABLE_USB_WAKEUP" == "true" ]]; then
        color_log notice "已设置休眠前禁止 USB 设备唤醒，扫描所有 USB Device..."
        disable_usb_wakeup
    fi

    # 尝试打开网卡 WOL，以便下次从网络唤醒
    color_log notice "尝试打开所有网卡 WOL，以便下次从网络唤醒..."
    try_enable_wol
}

# =========================================================
# FSM 有限状态机主逻辑
# =========================================================
main() {
    load_state # 加载之前的状态数据

    case "$STATE" in
        ACTIVE) # 活跃状态：持续监测，一旦环境空闲则转入 IDLE
            if ! is_busy; then
                IDLE_DURATION=$CHECK_INTERVAL_MIN
                set_state IDLE "[IDLE]" "系统已处于空闲状态"
            fi
            ;;

        IDLE) # 空闲累加状态：持续监测并在时间达标后触发休眠
            if is_busy; then
                # 环境一旦转为繁忙，重置时长并回归 ACTIVE 状态
                IDLE_DURATION=0
                set_state ACTIVE "[${METRIC_LEVEL}] [${METRIC_TYPE}]" "${METRIC_REASON}" "${METRIC_SNAPSHOT}"
            else
                # 依然空闲，累加时长
                IDLE_DURATION=$(( IDLE_DURATION + CHECK_INTERVAL_MIN ))

                # 判断是否同时满足：累计时长、允许时段、非唤醒冷却期
                if (( IDLE_DURATION >= IDLE_MINUTES_REQUIRED )) &&
                   within_suspend_window &&
                   ! cooldown_active; then
                    set_state SUSPENDING "[SUSPENDING]" "系统空闲时长已达休眠条件，继续保持空闲状态 ${CHECK_INTERVAL_MIN} 分钟后，系统将自动开始休眠..."
                fi

                if (( IDLE_DURATION == IDLE_MINUTES_REQUIRED )); then
                    within_suspend_window || log "系统空闲时长已达休眠条件，但仍处于非休眠窗口期，允许时段：(${SUSPEND_HOUR_START} 时 -> ${SUSPEND_HOUR_END} 时)"
                    if cooldown_active; then
                        local now_cd=${EPOCHSECONDS:-$(date +%s)}
                        local remain_min=$(( (LAST_RESUME_TS + RESUME_COOLDOWN_MIN * 60 - now_cd) / 60 ))
                        (( remain_min < 0 )) && remain_min=0
                        log "系统空闲时长已达休眠条件，但仍处于休眠冷却阶段，冷却剩余时间： ${remain_min} 分钟"
                    fi
                fi
            fi
            ;;

        SUSPENDING) # 准备执行休眠
            # 当前周期有用户活动则取消休眠
            if is_busy; then
                set_state ACTIVE "[${METRIC_LEVEL}] [${METRIC_TYPE}]" "${METRIC_REASON}" "${METRIC_SNAPSHOT}"
            else
                hooks_before_suspend     # 调用休眠前的钩子函数

                # 若配置允许，停转 HDD
                if [[ "$ALLOW_HDD_STANDBY" == "true" ]]; then
                    color_log notice "已允许休眠前停转机械硬盘，扫描系统中已挂载的 HDD..."
                    hdd_standby
                fi

                local run_time
                if (( LAST_RESUME_TS > 0)); then
                    run_time=$(( ${EPOCHSECONDS:-$(date +%s)} - LAST_RESUME_TS ))
                else
                    run_time=$(now_uptime)
                fi
                color_log notice "即将执行休眠，本次运行时长：$(( run_time / 3600 )) 小时 $(( (run_time % 3600) / 60 )) 分钟"
                color_log warning "执行休眠..."
                # 记录请求休眠时间点
                # /proc/uptime 记录的是系统运行的单调时间（Monotonic Time），它通常不包含系统处于休眠（Suspend/Sleep）状态的时间
                REQUEST_SUSPEND_TS="${EPOCHSECONDS:-$(date +%s)}"

                systemctl suspend || color_log err "！错误：休眠失败（systemctl suspend 返回非 0）"
                sleep 6

                # 唤醒后立即在脚本内切换状态，不依赖外部 hook，外部 hook 只做唤醒 HDD 动作
                LAST_RESUME_TS="${EPOCHSECONDS:-$(date +%s)}"
                local sleep_time=$(( LAST_RESUME_TS - REQUEST_SUSPEND_TS ))

                if (( sleep_time > 60 )); then
                    color_log notice "系统已正常唤醒，本次休眠时长：$(( sleep_time / 3600 )) 小时 $(( (sleep_time % 3600) / 60 )) 分钟"
                    IDLE_DURATION=0
                    SUSPEND_FAIL_CNT=0
                    set_state COOLDOWN "[COOLDOWN]" "系统已进入休眠冷却阶段，时间：${RESUME_COOLDOWN_MIN} 分钟"  # <--- 在这里切换为冷却状态

                    # ★关键修正★：切换状态后，立即强制保存一次
                    # 这样即使脚本随后的几毫秒崩溃，下次启动读取到的也是 COOLDOWN 状态
                    save_state
                else
                    SUSPEND_FAIL_CNT=$(( SUSPEND_FAIL_CNT + 1 ))
                    set_state ACTIVE "[RESUMED]" "系统唤醒过快，本次休眠时间仅：${sleep_time}s，(计数: ${SUSPEND_FAIL_CNT})"
                    color_log warning "！警告：[连续唤醒过快] 计数达 2 次时，系统将自动禁用脚本"
                    save_state

                    # 唤醒后的休眠时间小于 30s 达到 2 次则认为是异常唤醒，自动禁用脚本
                    if [[ $SUSPEND_FAIL_CNT -eq 2 ]]; then
                        color_log err "！错误：系统连续 ${SUSPEND_FAIL_CNT} 次 [休眠 -> 唤醒] 时间小于 60s，已自动创建 "${DISABLE_FILE}" 禁用脚本！"
                        touch "$DISABLE_FILE"
                        SUSPEND_FAIL_CNT=0
                    fi
                fi
            fi
            ;;

        COOLDOWN) # 唤醒后的保护状态
            # 检查是否已脱离冷却期
            if ! cooldown_active; then
                set_state ACTIVE "[ACTIVE]" "休眠冷却阶段 (${RESUME_COOLDOWN_MIN} 分钟) 已结束，系统开始重新监测..."
            fi
            ;;

        *) # 防护逻辑：未知状态则重置为 ACTIVE
            set_state ACTIVE "[ERROR]" "异常状态: ${STATE}, 正在重置..."
            ;;
    esac

    save_state # 保存当前状态，供下一周期使用
}

# 启动脚本
main "$@"