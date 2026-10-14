# hdd-resume-post.sh 维护文档

> systemd 休眠/唤醒钩子（`system-sleep`）——系统唤醒后自动**恢复机械硬盘（HDD）
> 起转并重新挂载**。与主脚本 `auto-suspend.sh` 配合：主脚本负责休眠前卸载 + 停转，
> 本钩子负责唤醒后起转 + 挂载。

---

## 1. 脚本概述

`hdd-resume-post.sh` 安装在 `/lib/systemd/system-sleep/hdd-resume-post.sh`。
systemd 在系统休眠/唤醒时调用 `/lib/systemd/system-sleep/*` 下的可执行脚本，并传入
参数：`pre`（休眠前）或 `post`（唤醒后）。本脚本仅处理 `post` 分支。

核心思路（**与主脚本解耦**）：

- 唤醒钩子**不读取**主脚本休眠前写下的 `disk/disk.map`，而是**独立重扫 `/etc/fstab`**，
  动态定位机械盘并恢复。这样即使 `disk.map` 缺失/过期也能正确唤醒。
- 通过哨兵文件 `disk/SAFE_TO_RESUME` 判断"本次休眠前是否真的停转过快盘"：没停转则
  无需任何恢复动作，直接返回。

### 关联文件

| 文件 | 作用 |
|---|---|
| `/lib/systemd/system-sleep/hdd-resume-post.sh` | 本钩子（安装后需可执行） |
| `/etc/fstab` | 机械盘挂载清单来源（源列应为 `UUID=`/`LABEL=` 形式） |
| `/run/auto-suspend/disk/SAFE_TO_RESUME` | 哨兵：主脚本休眠前停转成功即创建；钩子据此判断是否需恢复 |
| `/run/auto-suspend/disk/disk.map` | 主脚本休眠前卸载记录（仅作排查参考，钩子不读取） |

---

## 2. 工作流程（post 分支）

```
post
  └─ SAFE_TO_RESUME 存在？ ──否──▶ return 0（本次未停转，无需恢复）
      │ 是
      ├─ 扫描 /etc/fstab（跳过 swap/tmpfs/proc/sysfs/... 与注释行）
      │    └─ findfs 解析源（UUID=/LABEL=）→ lsblk 校验 ROTA=1 → 收集物理母盘（去重）
      ├─ 未找到任何机械盘？ ──是──▶ 记录错误 + rm SAFE_TO_RESUME + return 0
      │ 否
      ├─ 逐个物理盘 dd iflag=direct 触发起转（串行，间隔 SPINUP_INTERVAL=3s）
      ├─ sleep SPINUP_DELAY=20s（等电机稳定）
      ├─ 按挂载点逐个 mount 恢复（已挂载则跳过；失败重试一次）
      ├─ systemd-run --on-active=30s 延迟恢复 NCQ（echo 32 > queue_depth）
      └─ rm -f SAFE_TO_RESUME（保留 disk.map 供排查）
```

### 各步骤说明

1. **哨兵判断**：`[[ -f "$SAFE_FILE" ]] || return 0`。`SAFE_TO_RESUME` 由主脚本
   `hdd_standby()` 在至少一块盘停转成功后 `touch` 创建。
2. **解析 `/etc/fstab`**：逐行读取 `src mnt fstype ...`，跳过注释与
   `swap / tmpfs / proc / sysfs / devpts / cgroup* / overlay / none / autofs`。
3. **定位与过滤**：`findfs "$src"` 将 `UUID=`/`LABEL=` 解析为设备路径；
   `lsblk -o UUID,PKNAME,ROTA,NAME -P` 判断 `ROTA=1`（机械盘）并求物理母盘 `PKNAME`
   （去重，保证 sdb1/sdb2 只让 sdb 起转一次）。无 UUID 的条目跳过并告警。
4. **空清单保护**：`target_hdds` 为空（例如 fstab 中无机械盘）时，记录错误
   「未找到任何自定义的机械硬盘」，清理哨兵后返回——避免误判。
5. **串行起转**：`dd if=/dev/<disk> of=/dev/null bs=512 count=1 iflag=direct`，
   `iflag=direct` 确保穿透缓存、真正触发物理 IO；每块盘间隔 `SPINUP_INTERVAL`。
6. **恢复挂载**：按 `UUID|挂载点` 列表，`findmnt` 已挂载则跳过；否则
   `mount <挂载点>`（选项沿用 fstab），失败 sleep 2s 重试一次。
7. **恢复 NCQ**：用 `systemd-run --on-active=30s` 延迟执行 `echo 32 > queue_depth`，
   避免脚本退出后计时器失效；期间日志打点。
8. **清理哨兵**：只删除 `SAFE_TO_RESUME`，保留 `disk.map` 便于排查。

---

## 3. 参数（脚本顶部常量）

| 变量 | 默认值 | 说明 |
|---|---|---|
| `STATE_DIR` | `/run/auto-suspend` | 运行时状态目录 |
| `DISK_DIR` | `$STATE_DIR/disk` | 磁盘休眠子目录 |
| `MAP_FILE` | `$DISK_DIR/disk.map` | 主脚本写入的卸载记录（本脚本已不读取，保留变量） |
| `SAFE_FILE` | `$DISK_DIR/SAFE_TO_RESUME` | 哨兵标记 |
| `SPINUP_INTERVAL` | 3 | 顺序起转间隔（s） |
| `SPINUP_DELAY` | 20 | 起转后等待电机稳定（s） |
| `LOG_TAG` | `auto-suspend` | 日志标签（`journalctl -t auto-suspend`） |

---

## 4. 日志与调试

```bash
# 查看唤醒钩子相关日志
journalctl -t auto-suspend --since "5 minutes ago"

# 手动触发一次 post（模拟唤醒，仅调试用）
sudo /lib/systemd/system-sleep/hdd-resume-post.sh post

# 查看当前 fstab 中机械盘解析结果
findmnt -rn -o TARGET,SOURCE,FSTYPE
lsblk -o NAME,ROTA,PKNAME,UUID
```

常见日志：

- `[HDD] 正在恢复起转 spin-up [...]`：进入起转阶段。
- `[HDD] 挂载成功：[UUID=...] -> [...]`：挂载恢复成功。
- `[HDD] 警告: 无法根据 UUID/LABEL 找到磁盘路径: <src>`：fstab 源不可用 `findfs` 解析。
- `[HDD] 错误: 无法挂载 <mnt> ...`：挂载两次失败。
- `！错误：未找到任何自定义的机械硬盘，跳过唤醒阶段`：fstab 中无机械盘。

---

## 5. 常见故障排查

| 现象 | 排查方向 |
|---|---|
| 唤醒后 HDD 未起转 | 确认 `disk/SAFE_TO_RESUME` 存在（主脚本休眠前确实停转过）；`journalctl -t auto-suspend` 看是否进入起转阶段 |
| 挂载失败 | 检查 `/etc/fstab` 该行语法与 `findmnt` 输出；`mount <mnt>` 手动验证；确认设备已就绪 |
| `findfs` 警告找不到磁盘 | fstab 源列需为 `UUID=`/`LABEL=`；裸路径（如 `/dev/sdb1`）无法解析 |
| 起转后仍被系统判忙/无响应 | 检查 `SPINUP_DELAY` 是否足够（大容量/多盘可调大）；确认 `queue_depth` 文件可写 |
| NCQ 未恢复 | `cat /sys/block/<disk>/device/queue_depth` 应为 32；`systemd-run --unit=hdd-ncq-resume` 是否报错 |

---

## 6. 维护注意事项

- 安装后必须保留可执行权限：`chmod 755 /lib/systemd/system-sleep/hdd-resume-post.sh`。
- 钩子只处理 `post` 分支；`pre` 分支为空（休眠前动作由主脚本完成）。
- 若想"完全手动恢复"，可先删除哨兵再执行钩子：它会被哨兵检查直接跳过——所以
  需要手动恢复时应先 `touch /run/auto-suspend/disk/SAFE_TO_RESUME`（仅测试时）。
- 本脚本与 `auto-suspend.sh` 的 `disk.map` 已解耦，删除 `disk.map` 不影响唤醒。
- 大机箱/多盘场景可上调 `SPINUP_INTERVAL` 与 `SPINUP_DELAY` 防止启动电流过冲。
