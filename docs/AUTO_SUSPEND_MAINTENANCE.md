# auto-suspend.sh 维护文档

> 基于状态机（FSM）的 Linux NAS 自动休眠脚本。本文档面向运维/维护人员，说明脚本的
> 运行机制、状态目录文件、配置、指标采集、休眠/唤醒流程以及常见故障排查。

---

## 1. 脚本概述

`auto-suspend.sh` 由 systemd timer（`auto-suspend.timer`）按固定周期触发（默认每
5 分钟），每次执行完成一次"采样 → 判断 → 状态迁移"周期，并把状态持久化到
`/run/auto-suspend/state`，供下次运行恢复。

设计要点：

- **Fail-safe**：任何异常（配置缺失、jq 未安装、权限不足、未知状态）都不会触发休眠。
- **显式状态机**：`ACTIVE → IDLE → SUSPENDING → COOLDOWN → ACTIVE`。
- **多维度空闲判断**：SSH/Web 用户、CPU 负载、网络流量、机械硬盘 IO、固态硬盘 IO。
- **阈值自学习**：基于历史采样的 P90 动态学习各 IO/流量阈值，并叠加安全因子。
- **可观测性**：状态转换、忙碌原因、休眠/唤醒时长均写入 journald（`journalctl -t auto-suspend`）。

### 关联文件

| 文件 | 作用 |
|---|---|
| `/usr/local/sbin/auto-suspend.sh` | 主脚本 |
| `/lib/systemd/system-sleep/hdd-resume-post.sh` | 唤醒后恢复 HDD 起转与挂载的钩子 |
| `/etc/systemd/system/auto-suspend.timer` | 周期触发定时器（开机后 10min、之后每 5min） |
| `/etc/systemd/system/auto-suspend.service` | 执行主脚本的 oneshot 服务 |
| `config/default.json` | 默认配置（脚本与 Web UI 共用；部署后位于 `/usr/local/share/auto-suspend/web/config/`） |
| `config/config.json` | 用户覆盖配置（仅存与默认不同的项；部署后与 Web 共用同一目录，Web 修改即可被主脚本读取） |

---

## 2. 状态目录与运行时文件

所有运行时状态保存在内存文件系统 `/run/auto-suspend`（系统重启后自动清空）：

| 文件 | 说明 |
|---|---|
| `state` | 状态机持久化文件（`STATE`、`STATE_TS`、`IDLE_DURATION`、`REQUEST_SUSPEND_TS`、`LAST_RESUME_TS`、`SUSPEND_FAIL_CNT`），`key=value` 每行一条 |
| `lock` | 文件锁（`flock`），防止多实例并发 |
| `disable` | **禁用标记**：连续 2 次快速唤醒后由脚本自动创建，存在即禁止脚本执行；可由 Web UI「手动移除禁用限制」或手动 `rm` 删除 |
| `hdd.<dev>.prev` | 各机械硬盘累计扇区计数快照（用于计算周期差值） |
| `hdd.<dev>.samples` | 各机械硬盘周期 IO 采样，每行 `<epoch秒> <扇区数>` |
| `ssd.<dev>.prev` | 各 SSD 累计扇区计数快照 |
| `ssd.samples` | SSD 合计周期 IO 采样 |
| `net.prev` | 物理网卡累计流量快照（字节） |
| `net.samples` | 网络周期流量采样（字节） |
| `hdd.device.finger` / `ssd.device.finger` | 设备列表指纹，用于热插拔/增减设备时清理缓存 |
| `disk/disk.map` | 休眠前成功卸载的机械硬盘记录，每行 `UUID|物理盘|挂载点`（供排查参考；唤醒钩子已改为独立扫描 `/etc/fstab`，不再读取该文件） |
| `disk/SAFE_TO_RESUME` | 休眠前确认已停转 HDD 的哨兵标记，唤醒钩子据此执行恢复流程 |

> 说明：`.samples` 仅在 IDLE 空闲状态下记录（即 SSH/Web/CPU 均空闲时才采样），
> 因此图表中的采样体现的是"空闲时的读写活动"。

---

## 3. 状态机（FSM）

| 状态 | 含义 | 进入条件 | 退出条件 |
|---|---|---|---|
| `ACTIVE` | 活跃监测 | 初始 / 检测到忙碌 / 冷却结束 / 快速唤醒 | 连续空闲 → `IDLE` |
| `IDLE` | 空闲累加 | 环境空闲 | 忙碌 → `ACTIVE`；累计时长达标且在窗口内、非冷却 → `SUSPENDING` |
| `SUSPENDING` | 准备休眠 | 空闲时长 ≥ `idle_minutes_required` | 忙碌 → `ACTIVE`；否则执行休眠钩子并 `systemctl suspend` |
| `COOLDOWN` | 唤醒冷却 | 正常唤醒（休眠时长 > 60s） | 冷却时间结束 → `ACTIVE` |

关键细节：

- `IDLE_DURATION` 以 `CHECK_INTERVAL_MIN` 为步长累加。
- 休眠窗口 `within_suspend_window()`：
  - `start=0 && end=24` → 全天允许；
  - `start <= end` → 当天 `[start, end)`；
  - `start > end` → 跨天 `[start, 24:00) ∪ [0:00, end)`。
- 冷却期 `cooldown_active()`：以 `LAST_RESUME_TS + RESUME_COOLDOWN_MIN*60` 与当前时间比较。
- 状态写入采用"临时文件 + `mv`"原子替换，防止崩溃产生半截文件。

---

## 4. 配置项

配置来源优先级：`default.json`（`config/`，随安装包分发）→ `config.json`（用户覆盖）
→ 脚本内置 fallback。若未安装 `jq`，脚本直接使用内置默认值。

> 部署后主脚本通过 `auto-suspend.service` 注入的 `AUTO_SUSPEND_CONFIG_DIR` 指向 Web 的
> 配置目录（`/usr/local/share/auto-suspend/web/config/`），与 Web UI 共用同一份
> `default.json` / `config.json`，因此从 Web 修改的配置能直接被主脚本读取生效。

| 配置项 | 默认值 | 说明 |
|---|---|---|
| `general.suspend_enabled` | true | 总开关，false 时脚本直接退出 |
| `general.allow_hdd_standby` | true | 休眠前是否停转机械硬盘 |
| `general.disable_bluetooth` | true | 休眠前是否停用蓝牙模块 |
| `general.disable_usb_wakeup` | true | 休眠前是否禁用 USB 唤醒 |
| `suspend_window.hour_start` | 0 | 允许休眠窗口开始小时 |
| `suspend_window.hour_end` | 24 | 允许休眠窗口结束小时 |
| `check_interval.minutes/seconds` | 5 / 300 | 监测周期（需与 systemd timer 一致） |
| `idle_detection.idle_minutes_required` | 60 | 连续空闲所需分钟数 |
| `idle_detection.resume_cooldown_minutes` | 300 | 唤醒冷却分钟数 |
| `learning_parameters.learn_window` | 60 | 阈值学习窗口（采样点数） |
| `learning_parameters.safety_factor` | 120 | 安全因子（%），120 = 学得阈值上浮 20% |
| `network_thresholds.min_net / max_net / net_activity_floor` | 409600 / 20971520 / 5242880 | 网络阈值下界/上界/硬性下限（字节） |
| `hdd_thresholds.min_hdd / max_hdd` | 128 / 4096 | 每盘 HDD 扇区阈值下界/上界 |
| `ssd_thresholds.min_ssd / max_ssd` | 2048 / 20480 | SSD 合计扇区阈值下界/上界 |
| `cpu_thresholds.cpu_load_max` | 0.8 | CPU 5 分钟平均负载上限 |
| `web_access.web_access_log` | /usr/trim/nginx/logs/access.log | Nginx 访问日志路径 |
| `web_access.web_active_window` | 1800 | Web 活跃检测时间窗口（秒） |

> 修改配置建议通过 Web UI「配置」选项卡完成；也可直接编辑 `config.json` 后由定时器
> 下个周期自动生效（脚本每次运行都重新读取配置）。**`check_interval` 需同步修改
> systemd timer 的 `OnUnitActiveSec`。**

---

## 5. 指标采集与阈值学习

### 5.1 指标分层

`is_busy()` 分两阶段：

1. **串行高优先级**（命中任一即忙，不再执行后续）：`metric_ssh` → `metric_web` → `metric_cpu`
2. **并行组**（真实空闲时才执行并学习阈值）：`metric_net`、`metric_ssd`、`metric_hdd`

### 5.2 计数器与 Spike 防护

- 各累计计数（`.prev`）通过 `rebase_if_gap()` 校验时间跨度：若距上次更新超过
  `interval * 1.5`，判定为采样断档，重置基准并跳过本轮，避免累积量差造成伪忙。
- 计数器回绕（`io < 0`）会被防御性重置为 0 并记录日志。
- 忙碌原因/阈值快照中的字节数通过 `format_bytes()` 自动换算为可读单位
  （B ~ PB，保留 2 位小数）；磁盘指标先将扇区 ×512 换算为字节再显示。

### 5.3 P90 阈值学习（`learn_threshold`）

```
样本数 < 24          -> 不学习，沿用上次阈值
idx = count * 90 / 100（1 起索引，最小值 1）
P90 = 排序后第 idx 个样本值
阈值 = clamp(P90 * safety_factor / 100, min, max)
```

> 与 Web UI 图表中的 P90 口径完全一致（前端 `computeP90` 使用
> `Math.floor(len*90/100) - 1`，对应 shell 的 1 起索引）。

---

## 6. 休眠流程

进入 `SUSPENDING` 且本轮不忙时按序执行：

1. `hooks_before_suspend()`
   - 停用蓝牙（`disable_bluetooth_module`）：解绑 USB 蓝牙 → 卸载驱动模块 → 校验 HCI。
   - 禁用 USB 唤醒（`disable_usb_wakeup`）：设备级 `wakeup=disabled`、`control=auto`，PCI 控制器级禁用。
   - 开启网卡 WOL（`try_enable_wol`）：系统 ACPI wakeup + ethtool Magic Packet。
2. 若 `allow_hdd_standby`：`hdd_standby()`
   - 用 `findmnt -rn -o TARGET,SOURCE,FSTYPE` 枚举**当前已挂载**的文件系统
     （动态获取，不再依赖 `/etc/fstab` 静态解析）；跳过 `swap / *tmpfs / proc / sysfs / devpts / cgroup* / overlay / none / autofs` 等特殊类型；
   - `findmnt` 反查设备路径 → `lsblk` 校验 `ROTA=1`（机械盘）并补全物理盘名；
   - 逐盘卸载（含重试），成功者记录 `UUID|物理盘|挂载点`（3 字段）到 `disk/disk.map`；
   - `sync` 落盘；`udevadm settle`；
   - 每块物理盘设置 NCQ=1 → `blockdev --flushbufs` → `hdparm -y` 停转；
   - 只要有盘停转成功即 `touch disk/SAFE_TO_RESUME`。
3. 记录 `REQUEST_SUSPEND_TS`，执行 `systemctl suspend`。
4. 唤醒后（脚本内直接处理，不依赖外部钩子）：
   - 休眠时长 > 60s → 记录 `LAST_RESUME_TS`、清零失败计数、切 `COOLDOWN` 并立即 `save_state`；
   - 休眠时长 ≤ 60s → 失败计数 +1，切回 `ACTIVE`；计数达 2 次时创建 `disable` 禁用脚本。

---

## 7. 唤醒流程

systemd 在唤醒后调用 `/lib/systemd/system-sleep/hdd-resume-post.sh post`（详细说明见
[HDD_RESUME_POST_MAINTENANCE.md](HDD_RESUME_POST_MAINTENANCE.md)）：

1. 检查哨兵 `disk/SAFE_TO_RESUME`：不存在则直接返回（本次休眠未停转任何 HDD）；
2. **独立重扫 `/etc/fstab`**（不再读取 `disk.map`）：`findfs` 解析 `UUID=`/`LABEL=`
   源 → `lsblk` 校验 `ROTA=1`（机械盘）并求物理母盘去重；
3. 未找到任何机械盘 → 记录错误并清理哨兵，跳过唤醒；
4. 逐物理盘 `dd iflag=direct` 触发物理 IO 起转（串行 + 间隔，防止启动大电流）；
5. 等待 `SPINUP_DELAY` 后按挂载点逐个 `mount` 恢复（挂载选项沿用 `/etc/fstab`）；
6. `systemd-run --on-active=30s` 延迟恢复 NCQ（`echo 32 > .../queue_depth`）；
7. 清理哨兵 `disk/SAFE_TO_RESUME`（保留 `disk.map` 供排查）。

> 注意事项：唤醒钩子依赖 `/etc/fstab` 中机械盘源列使用 `UUID=`/`LABEL=` 形式
> （`findfs` 无法解析裸设备路径）；若上次休眠未正常完成，残留的哨兵会由主脚本
> `hdd_standby()` 检测并报错，需人工清理 `disk/` 后重试。

---

## 8. 日志与调试

```bash
# 查看最近日志（推荐）
journalctl -t auto-suspend -n 50

# 跟踪最新日志
journalctl -t auto-suspend -f

# 按时间过滤
journalctl -t auto-suspend --since "10 minutes ago"

# 查看服务状态
systemctl status auto-suspend.timer auto-suspend.service auto-suspend-web.service
```

日志中的 `FSM: A -> B 【间隔 X 分钟 | 原因 | 快照】` 为状态迁移记录；忙碌原因与
动态阈值快照会附在迁移日志中，是排查"为什么不休眠"的第一手依据。

---

## 9. 常见故障排查

| 现象 | 排查方向 |
|---|---|
| 系统从不休眠 | `journalctl -t auto-suspend` 看忙碌原因；检查 `suspend_enabled`、`disable` 文件是否存在；确认当前是否在休眠窗口内 |
| 休眠后立即唤醒 | 查看唤醒钩子/`systemctl suspend` 返回；检查 USB 唤醒、WOL 误触发、`disable_usb_wakeup` 是否生效 |
| 连续快速唤醒导致脚本被禁用 | 出现 `disable` 文件；确认无异常唤醒源后，Web UI 点「手动移除禁用限制」或 `rm /run/auto-suspend/disable` |
| HDD 唤醒失败/挂载失败 | 查看 `hdd-resume-post.sh` 日志；确认 `/etc/fstab` 中源为 `UUID=`/`LABEL=` 且哨兵 `disk/SAFE_TO_RESUME` 存在；`lsblk` 核对物理盘名 |
| 阈值明显偏低/偏高 | 检查 `safety_factor`；清空对应 `.samples` 后让脚本重新学习（`rm /run/auto-suspend/*.samples`） |
| Web UI 日志显示"日志暂不可用" | 确认 Web 服务进程有 `journalctl` 权限（生产环境通常以 root 运行）；`systemctl status auto-suspend-web` |

---

## 10. 维护注意事项

- **不要**在系统休眠期间手动运行脚本：`lock` 与 `systemctl suspend` 本身有保护，但并发运行可能造成状态竞争。
- 修改 `check_interval` 时必须同步调整 `auto-suspend.timer` 的 `OnUnitActiveSec`。
- 升级安装时 `auto-suspend-install.sh` 会**保留**已有的 `config/config.json`，其余文件覆盖。
- 卸载会删除 `/run/auto-suspend`（运行时数据）与已安装文件，不影响数据盘。
- 主脚本与 Web UI 共用 `AUTO_SUSPEND_CONFIG_DIR` 指向的配置目录；若手动单独执行主脚本
  （未注入该环境变量），会回退到 `$SCRIPT_DIR/config/`，两者需保持一致以免配置“看起来不生效”。
- `hdd_standby()` 与唤醒钩子已**解耦**：主脚本写 `disk/disk.map` 仅作记录，唤醒钩子独立扫描 `/etc/fstab`。
- 唤醒钩子的详细维护说明见 `docs/HDD_RESUME_POST_MAINTENANCE.md`。
- 需要调试时可在 `main()` 前临时 `set -x`，或单独执行：
  ```bash
  sudo /usr/local/sbin/auto-suspend.sh
  ```
