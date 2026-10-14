# auto-suspend 维护说明

> 面向后续维护者与贡献者的项目维护文档。说明系统架构、代码结构、开发环境、
> 配置与安全、测试、发布、日志监控、故障排查、依赖管理与代码规范。

---

## 1. 架构概述

### 1.1 模块划分

```
┌────────────────────────── systemd ──────────────────────────┐
│  auto-suspend.timer ──(每 5min)──▶ auto-suspend.service     │
│                                    │ 执行                    │
│                                    ▼                        │
│                            auto-suspend.sh（Bash 主脚本）    │
│                              · 配置解析（jq / fallback）      │
│                              · FSM 状态机                    │
│                              · 指标采集 + P90 阈值学习        │
│                              · 休眠前钩子（HDD/蓝牙/USB/WOL） │
│                                                             │
│  system-sleep 唤醒钩子：hdd-resume-post.sh（HDD 起转/挂载）    │
│                                                             │
│  auto-suspend-web.service ──▶ app.py（Flask Web UI）          │
│        · REST API：status/charts/config/logs/...            │
│        · 前端：templates/index.html + static/app.js         │
└─────────────────────────────────────────────────────────────┘
                    共享：/run/auto-suspend（状态/采样）
                    共享：config/*.json（配置）
```

### 1.2 数据流

1. **定时触发**：`auto-suspend.timer` 每周期（默认 5min）触发一次
   `auto-suspend.service`（oneshot）执行 `auto-suspend.sh`。
2. **配置解析**：脚本读取 `config/default.json` + `config/config.json`（jq，缺失回退
   内置默认值），加载后按 FSM 状态执行本周期逻辑。
3. **指标采集**：`is_busy()` 先跑高优先级串行组（SSH/Web/CPU），再在真实空闲时跑
   并行组（NET/SSD/HDD），并把采样写入 `.samples`（`<epoch秒> <数值>`）。
4. **状态迁移**：`set_state()` 记录迁移日志并更新 `STATE/STATE_TS` 等，`save_state()`
   原子写回 `/run/auto-suspend/state`。
5. **休眠/唤醒**：满足条件 → 休眠前钩子 + `systemctl suspend`；唤醒后由
   `hdd-resume-post.sh` 恢复磁盘，脚本内完成状态切回与失败保护。
6. **Web 观测**：`app.py` 读取同一批状态/采样文件，通过 REST API 供前端渲染；配置
   修改经 `/api/config` 写回 `config.json`，下一周期自动生效。

### 1.3 关键组件交互

| 组件 | 角色 | 与谁交互 |
|---|---|---|
| `auto-suspend.sh` | 核心决策与执行 | timer、`/run/auto-suspend`、`config/*.json`、`systemctl suspend` |
| `hdd-resume-post.sh` | 唤醒恢复 | systemd system-sleep、`/etc/fstab`、`/run/auto-suspend/disk/` |
| `app.py` | Web 后端 | 状态/采样/配置文件、`journalctl`（日志接口） |
| `static/app.js` | Web 前端 | `app.py` 的 REST API |
| `config/*.json` | 配置源 | 主脚本与 Web 后端共用 |

> 注意：主脚本与唤醒钩子**已解耦**——主脚本写 `disk/disk.map` 仅作记录，唤醒钩子
> 独立重扫 `/etc/fstab`。

---

## 2. 代码目录结构说明

```
auto-suspend/
├── auto-suspend.sh              # 主休眠脚本（Bash FSM + 指标 + 阈值学习 + 休眠钩子）
├── hdd-resume-post.sh           # systemd 唤醒钩子（post 分支：HDD 起转/挂载/NCQ）
├── auto-suspend-install.sh      # 安装/卸载/状态 脚本（渲染 systemd 单元、拷贝文件）
├── auto-suspend.timer           # timer 模板（OnBootSec/OnUnitActiveSec 占位符）
├── auto-suspend.service         # oneshot 服务模板（ExecStart 占位符）
├── auto-suspend-web.service     # Web UI 服务模板（PYTHON/WEB_DIR/HOST/PORT 占位符）
├── app.py                       # Flask 后端：配置合并/状态/图表/日志/REST API
├── templates/index.html         # 单页 Web（4 个选项卡：总览/图表/配置/日志）
├── static/
│   ├── app.js                   # 前端：图表 SVG 渲染、配置表单、轮询、状态横幅
│   ├── style.css                # 深色主题（响应式、隐藏滚动条、状态配色）
│   └── favicon.svg              # 网页图标
├── config/
│   ├── default.json             # 默认配置（含 description/unit/note 元数据）
│   └── config.json              # 用户覆盖配置（仅存差异项，初始为 {}）
├── dev_state/                   # 开发环境模拟数据（.prev/.samples/state）
├── _gen_dev_state.py            # 生成 dev_state 样例（带时间戳 + 忙期缺口）
├── docs/
│   ├── AUTO_SUSPEND_MAINTENANCE.md    # auto-suspend.sh 维护文档
│   └── HDD_RESUME_POST_MAINTENANCE.md # hdd-resume-post.sh 维护文档
├── README.md                    # 项目自述（终端用户向）
└── MAINTENANCE.md               # 本文档（维护者/贡献者向）
```

---

## 3. 开发环境搭建

### 3.1 所需工具

- Python 3.9+、`pip`
- 可选：Git、VS Code（含 Pylance/Flask 扩展）
- Linux 主脚本调试需要真实 Linux 环境（`systemd`、`/sys`、`/proc`）

### 3.2 创建虚拟环境（可选）

```bash
python -m venv .venv
source .venv/bin/activate      # Windows: .venv\Scripts\activate
pip install flask
```

### 3.3 准备配置文件

```bash
cp config/default.json config/config.json   # 初始化用户覆盖（或留空 {}）
```

### 3.4 本地运行 Web（无需 Linux）

后端检测到 `dev_state/` 目录即进入**开发模式**（状态目录指向 `dev_state/`、模板热更新）。

```bash
python _gen_dev_state.py   # 生成 7 天样例数据（时间戳 + 忙期缺口）
python app.py              # 默认 0.0.0.0:5000
# 可选：WEB_HOST / WEB_PORT 环境变量覆盖
```

浏览器打开 `http://127.0.0.1:5000`。开发模式下 `/api/logs` 无 journalctl 会返回占位
消息，状态变更横幅自动隐藏。

### 3.5 模拟状态变更（开发调试）

改写 `dev_state/state`（如 `STATE=ACTIVE`）即可触发前端状态变化与横幅展示；也可用
浏览器 DevTools 拦截 `/api/logs` 模拟 journalctl 日志。

---

## 4. 配置与密钥管理

### 4.1 配置文件位置

| 文件 | 用途 | 是否应入库 |
|---|---|---|
| `config/default.json` | 默认配置（含描述/单位/备注） | 是 |
| `config/config.json` | 用户覆盖（仅差异项） | 否（建议 `.gitignore`） |
| `/run/auto-suspend/*` | 运行时状态/采样 | 否（内存文件系统） |

**部署后的实际路径**：安装脚本将两份配置装到 Web 安装目录
`/usr/local/share/auto-suspend/web/config/`（即 app.py 的 `BASE_DIR/config`）。主脚本
通过 systemd 单元注入的环境变量 `AUTO_SUSPEND_CONFIG_DIR` 指向**同一目录**（见
`auto-suspend.service`），从而 **Web 写入的 `config.json` 能被主脚本直接读取**，避免两边
配置不一致。开发/独立运行（未注入该环境变量）时主脚本仍使用自身 `SCRIPT_DIR/config/`。

### 4.2 配置优先级

`default.json` → `config.json`（覆盖）→ 脚本内置 fallback。脚本每次运行重新读取，
**配置热加载，无需重启服务**。`check_interval` 需与 systemd timer 的
`OnUnitActiveSec` 保持一致。

### 4.3 环境变量

| 变量 | 作用 | 默认 |
|---|---|---|
| `WEB_HOST` | Web 监听地址 | `0.0.0.0` |
| `WEB_PORT` | Web 监听端口 | `5000`（开发）/ `5005`（安装脚本） |
| `AUTO_SUSPEND_CONFIG_DIR` | 主脚本配置目录（部署时由 `auto-suspend.service` 注入，指向 Web 配置目录，实现主脚本与 Web 共用同一份配置） | `$SCRIPT_DIR/config` |

### 4.4 敏感信息处理

- 当前配置**不含任何密钥/口令**；`config.json` 属系统本地配置。
- ⚠️ **Web UI 无认证**：监听 0.0.0.0 时局域网内任何设备均可访问并修改配置/切换休眠。
  如需公网暴露，必须前置反向代理 + 认证（Basic Auth / 防火墙白名单），或限制监听地址。
- 日志若包含路径/设备名等环境信息，分享时注意脱敏。

---

## 5. 测试

### 5.1 现状

项目目前**无自动化测试套件**（无 `tests/` 目录、无 pytest 配置）。质量保障依赖
人工验证。欢迎补充。

### 5.2 手动验证流程

- **后端/API**：开发模式下启动 `app.py`，检查 `/api/status`、`/api/charts`、
  `/api/config`、`/api/logs` 返回与状态字段。
- **前端**：浏览器验证 4 个选项卡渲染、图表（含忙期斜纹/P90/时间窗口）、配置编辑与
  保存、日志加载、状态变更横幅（10s 自动隐藏）。
- **主脚本逻辑**：在 Linux 环境人工执行 `sudo /usr/local/sbin/auto-suspend.sh`，
  观察 `journalctl -t auto-suspend` 的状态迁移与忙碌原因。

### 5.3 建议的测试策略（待落地）

- `pytest` 覆盖 `app.py` 的配置合并（`_deep_merge`）、差异计算（`_flatten_config_diff`）、
  采样解析（`_read_sample_lines`）等纯函数；
- `shellcheck` 检查两个 `.sh` 脚本；
- 可选：对 `learn_threshold`/`rebase_if_gap` 用 `bats` 写集成测试。

```bash
pip install pytest
pytest tests/          # 待补充用例
```

---

## 6. 构建与发布

### 6.1 打包方式

当前为**源码 + 安装脚本**方式发布，无打包产物：

```bash
sudo ./auto-suspend-install.sh install     # 部署
sudo ./auto-suspend-install.sh uninstall   # 卸载
sudo ./auto-suspend-install.sh status      # 完整性检查
```

### 6.2 版本号规则

- 主脚本版本常量：`auto-suspend.sh` 中 `VERSION="Ver: 2.0"`。
- 建议采用语义化版本 `MAJOR.MINOR.PATCH`：
  - MAJOR：休眠/唤醒核心流程不兼容变更；
  - MINOR：新增功能/指标/配置项（向后兼容）；
  - PATCH：Bug 修复、文档。
- 每次发布前同步更新 `VERSION` 与文档中的版本说明。

### 6.3 发布流程

1. 从 `main` 切 `release` 分支，更新 `VERSION` 与 `README/MAINTENANCE` 变更记录；
2. 在真实 Linux 环境执行 `install`/`status`/`uninstall` 全流程自测；
3. 打 tag（如 `v2.0.0`）并发布源码包；附上 `config/default.json` 变更说明，
   提示升级用户检查 `config.json` 覆盖项。

---

## 7. 日志与监控

### 7.1 日志位置与级别

- 全部通过 journald（`systemd-cat`），标签 `auto-suspend`：
  `journalctl -t auto-suspend`。
- 日志级别映射：`color_log` 支持 `emerg|alert|crit|err|warning|notice|info|debug`；
  状态迁移用 `log()`（默认 info），忙碌/异常用 `color_log` 分级。

### 7.2 关键监控指标

- **状态迁移**：`FSM: A -> B 【间隔 X 分钟 | 原因 | 快照】`——排查「为什么不休眠」。
- **忙碌原因**：SSH/WEB/CPU/NET/SSD/HDD 与动态阈值快照。
- **休眠/唤醒**：本次休眠时长、运行时长、`SUSPEND_FAIL_CNT` 失败计数。
- **禁用事件**：连续快速唤醒自动创建 `disable` 文件（应触发告警）。
- **Web 侧**：`/api/status` 的 `state`、`updated_at`；前端每 3s 轮询状态、15s 轮询图表。

### 7.3 告警建议

- 出现 `disable` 文件 → 告警「auto-suspend 已被禁用」；
- 连续多次「休眠 < 60s」→ 告警异常唤醒；
- `journalctl` 中 `err` 级别（如休眠失败、HDD 卸载/挂载失败）→ 告警；
- Web 服务不可达（`auto-suspend-web.service` 重启）→ 告警。

```bash
# 监控示例：最近 10 分钟错误
journalctl -t auto-suspend -p err --since "10 minutes ago"
```

---

## 8. 故障排查

### 8.1 常见现象与排查步骤

| 现象 | 排查步骤 |
|---|---|
| 系统从不休眠 | ① `journalctl -t auto-suspend -n 50` 看忙碌原因；② 检查 `suspend_enabled` 与 `disable` 文件；③ 确认当前是否在允许窗口内 |
| 休眠后立即唤醒 | ① 看唤醒来源（USB/WOL）；② 确认 `disable_usb_wakeup`、`try_enable_wol` 行为；③ 检查 `systemctl suspend` 返回码 |
| 脚本被禁用 | ① 确认异常唤醒源；② Web 总览页「手动移除禁用限制」或 `rm /run/auto-suspend/disable` |
| HDD 唤醒后未挂载 | ① 确认 `disk/SAFE_TO_RESUME` 存在；② 确认 `/etc/fstab` 源为 `UUID=`/`LABEL=`；③ 看 `hdd-resume-post` 日志与 `lsblk` |
| 阈值异常 | ① 检查 `safety_factor`；② 清空 `.samples` 重新学习；③ 核对扇区→字节换算口径 |

### 8.2 日志分析示例

```
notice FSM: ACTIVE -> IDLE 【间隔 5 分钟 | 系统已处于空闲状态】
notice FSM: IDLE -> SUSPENDING 【间隔 55 分钟 | 系统空闲时长已达休眠条件...】
notice 即将执行休眠，本次运行时长：3 小时 12 分钟
warning 执行休眠...
notice 系统已正常唤醒，本次休眠时长：6 小时 5 分钟
```

- 长时间停留在 `ACTIVE` 且伴随 `BUSY` 迁移 → 某指标持续忙碌。
- `SUSPENDING` 后立即回到 `ACTIVE` 且 `RESUMED` → 快速唤醒，关注 `SUSPEND_FAIL_CNT`。
- 若出现 `err ！错误：... 已自动创建 /run/auto-suspend/disable` → 已触发禁用保护。

---

## 9. 依赖管理

### 9.1 当前依赖

- **Python**：仅 `flask`（`app.py`）。无 `requirements.txt`，建议补充并固定版本。
- **系统工具**：`jq`、`hdparm`、`ethtool`、`udevadm`、`findmnt`、`lsblk`、
  `blockdev`、`loginctl`、`systemd-cat`。
- **Bash**：4+（依赖 `declare -g`、nameref `local -n`、进程替换、关联数组）。

### 9.2 添加 / 更新依赖

- Python：`pip install <pkg>` 后写入 `requirements.txt`，说明用途与兼容版本。
- 系统工具：在安装脚本 `check_python`/文档「系统要求」中同步说明。

### 9.3 安全审计建议

- `pip-audit` / `pip check` 检查 Python 依赖漏洞；
- shell 依赖保持在发行版仓库版本即可；若以 root 运行，注意 Web 进程暴露面
  （无认证 → 限制监听/加代理认证）；
- 配置/日志分享前脱敏（路径、UUID、IP）。

---

## 10. 贡献与代码规范

### 10.1 代码风格

- **Bash**：`set -u` + `set -o pipefail`；函数内变量用 `local`；字符串统一双引号；
  关键逻辑加中文注释；避免顶层 `return`（脚本执行时非法，用 `exit`）。
- **Python**：PEP 8；蛇形命名；类型注解（项目已用 `from __future__ import annotations`）；
  函数加简短 docstring。
- **前端**：原生 JS，2 空格缩进，中文注释，DOM 事件集中在文件末尾绑定。

### 10.2 提交信息规范（约定式提交）

```
<type>(<scope>): <subject>

fix(hdd): 修正卸载失败时日志引用未定义变量
feat(web): 总览新增状态变更横幅
docs: 更新 README 与维护文档
```

`type`：`fix | feat | docs | refactor | chore | test`。

### 10.3 分支策略

- `main`：稳定分支，仅接受已自测的合并。
- 功能/修复分支：`feat/<描述>`、`fix/<描述>`，经 review 后 squash 合并回 `main`。
- 发布：打 `v<语义化版本>` tag。

### 10.4 提交流程

1. 新分支 → 修改 → 本地自测（见第 5 节）→ 提交；
2. 提交 PR 时说明改动内容、自测结果、对配置/休眠行为的影响；
3. 由维护者 review 后合并；涉及 `auto-suspend.sh`/`hdd-resume-post.sh` 的改动需在
   真实 Linux 环境验证。
