#!/bin/bash

set -u             # 遇到未定义变量时报错并退出
set -o pipefail    # 管道命令中任何子命令失败，整个管道返回非零值

# 路径设置
STATE_DIR="/run/auto-suspend"       # 状态存储目录（内存中）

# ----------------------------
# HDD 休眠参数
# ----------------------------
DISK_DIR="$STATE_DIR/disk"
MAP_FILE="$DISK_DIR/disk.map"
SAFE_FILE="$DISK_DIR/SAFE_TO_RESUME"
SPINUP_INTERVAL=3
SPINUP_DELAY=20                  # 起转延迟时间 s，防止启动大电流
LOG_TAG="auto-suspend"           # 日志标签，方便 journalctl 过滤

# =========================================================
# 核心函数：日志
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

main() {
    case "$1" in
        post)
            [[ -f "$SAFE_FILE" ]] || return 0

            color_log notice "尝试唤醒 [/etc/fstab] 中所有的 HDD..."

            local target_hdds=()
            local -A physical_dev_map # 用于物理盘去重

            # 1. 收集需要唤醒的磁盘信息
            while read -r src mnt fstype opts dump check; do
                [[ -z "$src" || "$src" =~ ^# ]] && continue   # 跳过注释符

                # 跳过特殊类型
                case "$fstype" in
                    swap|tmpfs|proc|sysfs|devpts|cgroup*|overlay|none|autofs) continue ;;
                esac

                # 根据 UUID 定位当前分区设备路径
                dev_path=$(findfs "$src" 2>/dev/null) || {
                    color_log warning "[HDD] 警告: 无法根据 UUID/LABEL 找到磁盘路径: ${src}"
                    continue
                }

                [[ -b "$dev_path" ]] || continue

                # 获取详细信息
                # 输出示例: a1b2-c3d4 sda 1 sda1
                # read -r uuid pkname is_rota dev_name <<< $(lsblk -n -o UUID,PKNAME,ROTA,NAME "$dev_path" | head -n1)
                # 使用 -P 格式确保变量抓取准确
                local lsblk_info
                local UUID PKNAME ROTA NAME

                lsblk_info=$(lsblk -n -o UUID,PKNAME,ROTA,NAME -P "$dev_path" | head -n1)

                # 提取变量
                eval "$lsblk_info"

                # 补全 pkname (如果本身就是物理盘)
                [[ -z "$PKNAME" ]] && PKNAME="$NAME"
                # 过滤非机械盘
                [[ "$ROTA" == "1" ]] || continue
                # 必须有 UUID (作为唤醒锚点)
                [[ -z "$UUID" ]] && log "警告：${mnt} (${NAME}) 无 UUID，跳过管理" && continue

                if [[ -n "$PKNAME" ]]; then
                    # 关联数组去重，确保 sdb1, sdb2 只会让 sdb 启动一次
                    physical_dev_map["$PKNAME"]=1
                fi

                target_hdds+=("$UUID|$mnt")

            done < /etc/fstab

	    # 2. 确认硬盘状态ok
            if [[ ${#target_hdds[@]} -eq 0 ]]; then
                color_log err "！错误：未找到任何自定义的机械硬盘，跳过唤醒阶段"
                rm -f "$SAFE_FILE"
		        return 0
            fi

            # 3. 串行启动循环 (Staggered Spin-up)
            for disk in "${!physical_dev_map[@]}"; do
                local dev_path="/dev/$disk"
                log "[HDD] 正在恢复起转 spin-up [${dev_path}]..."

                # 触发 I/O (读取 512字节) 唤醒硬盘
                # 使用 iflag=direct 确保穿透缓存，必须发生物理 I/O
                dd if="$dev_path" of=/dev/null bs=512 count=1 iflag=direct >/dev/null 2>&1 || true
                sleep "$SPINUP_INTERVAL"    # 延迟 顺序启动
            done

            sleep "$SPINUP_DELAY"
            # 4. 恢复挂载 (此时所有硬盘都已旋转稳定)
            while IFS='|' read -r uuid mnt; do
                [[ -d "$mnt" ]] || mkdir -p "$mnt"

                # 检测是否已经被系统挂载
                findmnt -rn "$mnt" >/dev/null && {
                    log "[HDD] 系统已挂载：${mnt}，跳过 (already mounted)"
                    continue
                }

                # 使用 mount 挂载点，系统会自动根据 fstab 里的配置 (UID/GID/Mask等) 进行挂载
                if mount "$mnt"; then
                    log "[HDD] 挂载成功：[UUID=${uuid}] -> [${mnt}]"
                    sleep 1
                else
                    log "[HDD] 挂载重试: ${mnt}"
                    sleep 2
                    mount "$mnt" || color_log err "[HDD] 错误: 无法挂载 ${mnt} | [UUID=${uuid}]"
                fi
            done < <(printf '%s\n' "${target_hdds[@]}")

            local disk_list="${!physical_dev_map[@]}"

            # 确保环境变量正确传递到 systemd-run 环境中
            systemd-run \
                --unit="hdd-ncq-resume" \
                --description="Resume HDD NCQ Performance" \
                --on-active=30s \
                --setenv=LOG_TAG="$LOG_TAG" \
                --setenv=PATH="/usr/sbin:/usr/bin:/sbin:/bin" \
                bash -c '
                    for disk in '"$disk_list"'; do
                        node="/sys/block/$disk/device/queue_depth"
                        if [[ -w "$node" ]]; then
                            echo 32 > "$node" 2>/dev/null
                            printf '%s' "[HDD] 恢复 $disk：NCQ = $(cat "$node")" | systemd-cat -p info -t "$LOG_TAG" || true
                        fi
                    done
                '

            rm -f "$SAFE_FILE"
            ;;
    esac
}

# 启动脚本
main "$@"
