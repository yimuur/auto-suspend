"""开发用：本地调试数据生成器（常驻运行，每 5 秒刷新一次）。

模拟 auto-suspend 的 FSM 状态机与采样，便于在 Web UI 上本地调试：

1. 状态覆盖：按时间表循环 UNKNOWN → ACTIVE → IDLE → SUSPENDING → COOLDOWN →（循环），
   一轮约 100 秒即可覆盖全部 5 种状态；每 5 秒更新 dev_state/state，联动维护
   STATE_TS / IDLE_DURATION / REQUEST_SUSPEND_TS / LAST_RESUME_TS / SUSPEND_FAIL_CNT。
   - IDLE：IDLE_DURATION 逐步累计，前端倒计时「保持 HH:MM:SS 后将进入休眠」可验证；
   - SUSPENDING：REQUEST_SUSPEND_TS 随机取 10min~3h 前，形成一段“休眠时长”；
   - COOLDOWN：LAST_RESUME_TS=now，休眠区间 = 上次唤醒 - 上次休眠，随轮次不断变化；
   - 偶尔设置 SUSPEND_FAIL_CNT=1/2，测试「休眠失败」红色高亮。
   说明：STATE_TS 按 **epoch 秒** 写入（与 REQUEST/LAST 同基准），
   与 auto-suspend.sh（已改为 epoch 基准）保持一致，前端倒计时可直接演示。

2. 采样数据：**一次性生成固定采样点**（不随运行动态追加）——最近 7 天、约 MAX_LINES 个点
   （均匀铺开），忙期窗口每天 2~4 段随机漂移（忙期内跳过 → 忙区缺口），含尖峰，
   覆盖 6h / 1天 / 1周 三个时间窗口，行数不超过 MAX_LINES；
   .prev 累计值随时间单调增长，模拟真实计数器。

用法：python _gen_dev_state.py   （Ctrl+C 停止）
"""
import random
import time
from pathlib import Path

random.seed()
out = Path(__file__).resolve().parent / "dev_state"
out.mkdir(parents=True, exist_ok=True)

TICK = 5                  # 状态刷新间隔（秒）
DAYS = 7                  # 历史数据天数
MAX_LINES = 1600          # 采样点最大数量（固定生成，控制柱状图点数）
                          # 100 点铺满 7 天时，6h/1天/1周 三个窗口柱体均清晰可见；
                          # 调大（如 500/3200）柱体更密，但 1天/1周 窗口柱体会变细
SPACING = DAYS * 86400 // MAX_LINES   # 采样点间隔（≈6048s，铺满 7 天）

STATE_FILE = out / "state"

# 状态轮换时间表：(状态, 持续 TICK 数) —— 一轮约 100s，覆盖全部 5 种状态
STATE_SCHEDULE = [
    ("UNKNOWN", 3),
    ("ACTIVE", 4),
    ("IDLE", 6),
    ("SUSPENDING", 2),
    ("COOLDOWN", 5),
]
CYCLE_TICKS = sum(t for _, t in STATE_SCHEDULE)

# 各指标生成参数（与真实数据量级相近）
METRICS = {
    "hdd.sda": {"low": 0, "high": 300, "spikes": 5, "spike_val": 2800},
    "hdd.sdb": {"low": 0, "high": 200, "spikes": 3, "spike_val": 1800},
    "ssd": {"low": 200, "high": 4000, "spikes": 6, "spike_val": 18000},
    "net": {"low": 1024 * 200, "high": 1024 * 1500, "spikes": 6, "spike_val": 1024 * 15000},
}

# .prev 基准值（累计计数器），每次刷新单调小幅增长
PREV_BASE = {
    "hdd.sda": 35_000_000,
    "hdd.sdb": 15_000_000,
    "ssd.nvme0n1": 88_000_000,
    "net": 360 * 1024 ** 2,
}


def write_state(state, state_ts, idle_dur, request_ts, resume_ts, fail_cnt):
    """以与 auto-suspend.sh 相同的 key=value 格式写入状态文件。"""
    STATE_FILE.write_text(
        f"STATE={state}\n"
        f"STATE_TS={state_ts}\n"
        f"IDLE_DURATION={idle_dur}\n"
        f"REQUEST_SUSPEND_TS={request_ts}\n"
        f"LAST_RESUME_TS={resume_ts}\n"
        f"SUSPEND_FAIL_CNT={fail_cnt}\n",
        encoding="utf-8",
    )


def build_busy_windows(now):
    """生成最近 7 天的忙期窗口：每天 2~4 段，起始时段随机漂移；
    并保证最近 6 小时内至少有 1 段忙期（便于 6h 窗口观察）。"""
    windows = []
    day_start = now - DAYS * 86400
    for day in range(DAYS):
        base = day_start + day * 86400
        for _ in range(random.randint(2, 4)):
            start_h = random.choice([0, 2, 5, 8, 11, 14, 17, 20, 22])
            ws = base + start_h * 3600 + random.randint(0, 90) * 60
            we = ws + random.choice([30, 45, 60, 90]) * 60
            if ws < now:
                windows.append((ws, we))
    recent = now - 6 * 3600
    if not any(ws >= recent for ws, _ in windows):
        ws = now - random.choice([2, 3, 4]) * 3600
        windows.append((ws, ws + random.choice([30, 45]) * 60))
    return [(ws, we) for ws, we in windows if ws < now]


def compute_rolling_p90_threshold(values, min_v, max_v, safety=120):
    """按 shell learn_threshold 口径：逐点累积 P90 * 安全因子%，夹取到 [min_v, max_v]。
    样本不足 24 时返回 None（写入 "min_v"）。"""
    sorted_v = []
    out = []
    for v in values:
        lo, hi = 0, len(sorted_v)
        while lo < hi:
            mid = (lo + hi) >> 1
            if sorted_v[mid] < v:
                lo = mid + 1
            else:
                hi = mid
        sorted_v.insert(lo, v)
        n = len(sorted_v)
        if n < 24:
            out.append(min_v)
            continue
        idx = max(0, n * 90 // 100 - 1)
        learned = sorted_v[idx] * safety // 100
        learned = max(min_v, min(learned, max_v))
        out.append(learned)
    return out


# 各指标的阈值上下界（与 config 一致：磁盘为扇区，网络为字节）
THRESHOLD_RANGES = {
    "hdd.sda": (128, 4096),
    "hdd.sdb": (128, 4096),
    "ssd": (2048, 20480),
    "net": (409600, 20971520),
}


def gen_samples(now, busy_windows):
    """一次性生成最近 7 天、约 MAX_LINES 个固定采样点（均匀铺开）；
    落在忙期内则跳过（形成忙区缺口），行数不超过 MAX_LINES。
    每行末列追加该采样点计算完的 P90 阈值（与 shell learn_threshold 同口径）。"""
    start = now - (MAX_LINES - 1) * SPACING
    series = {}
    for name, cfg in METRICS.items():
        pairs = []
        for i in range(MAX_LINES):
            ts = start + i * SPACING
            if any(ws <= ts < we for ws, we in busy_windows):
                continue
            v = random.randint(cfg["low"], cfg["high"])
            if cfg["spikes"] and i % max(1, MAX_LINES // cfg["spikes"]) == 0:
                v = random.randint(cfg["spike_val"] // 2, cfg["spike_val"])
            pairs.append((ts, v))
        # 追加逐点 P90 阈值（每行最后一列）
        lo, hi = THRESHOLD_RANGES.get(name, (0, 2 ** 31))
        p90s = compute_rolling_p90_threshold([p[1] for p in pairs], lo, hi)
        series[name] = [(ts, v, p90) for (ts, v), p90 in zip(pairs, p90s)]
    return series


def write_samples(name, pairs):
    (out / f"{name}.samples").write_text(
        "\n".join(f"{ts} {v} {p90 if p90 is not None else '-'}" for ts, v, p90 in pairs) + "\n",
        encoding="utf-8")


def state_at(tick):
    """根据当前 tick 返回应处的状态（按时间表轮换）。"""
    pos = (tick - 1) % CYCLE_TICKS
    for name, dur in STATE_SCHEDULE:
        if pos < dur:
            return name
        pos -= dur
    return "UNKNOWN"


def main():
    now = int(time.time())
    print(f"auto-suspend dev 数据生成器启动：采样固定生成（最近 {DAYS} 天、约 {MAX_LINES} 点，"
          f"忙期缺口 + 尖峰）；状态每 {TICK}s 轮换 "
          f"{[s for s, _ in STATE_SCHEDULE]}（一轮约 {CYCLE_TICKS * TICK}s）。")

    # 一次性生成固定采样点（不随运行动态追加）+ 预置 .prev 累计值
    busy_windows = build_busy_windows(now)
    for name, pairs in gen_samples(now, busy_windows).items():
        write_samples(name, pairs)
    prev_values = dict(PREV_BASE)
    for name, v in prev_values.items():
        (out / f"{name}.prev").write_text(str(v) + "\n", encoding="utf-8")

    # FSM 持久变量
    prev_state = None
    state_ts = 0
    idle_duration = 0
    request_ts = 0
    resume_ts = 0
    fail_cnt = 0

    tick = 0
    try:
        while True:
            tick += 1
            now = int(time.time())

            # FSM 状态轮换（采样为固定数据，不在此处追加）
            state = state_at(tick)
            if state != prev_state:
                state_ts = now            # 状态切换时更新锚点（epoch 基准）
                if state == "SUSPENDING":
                    # 随机生成一段“休眠时长”（10min~3h），供休眠时长卡片 / 图表休眠区间
                    request_ts = now - random.randint(10, 180) * 60
                    fail_cnt = 0
                elif state == "COOLDOWN":
                    resume_ts = now
                elif state == "IDLE":
                    idle_duration = 5     # 进入 IDLE 起累计 5 分钟
                elif state == "ACTIVE":
                    idle_duration = 0
                if random.random() < 0.08:
                    fail_cnt = random.randint(1, 2)   # 偶尔模拟休眠失败计数（红色高亮）
                prev_state = state
                print(f"[{time.strftime('%H:%M:%S')}] STATE -> {state} "
                      f"(idle={idle_duration}min, fail={fail_cnt})")
            elif state == "IDLE":
                idle_duration += 5        # 保持 IDLE 时继续累计空闲时长（模拟每 5s 过 5 分钟）

            write_state(state, state_ts, idle_duration, request_ts, resume_ts, fail_cnt)

            # .prev 累计值单调增长（累计计数器，非采样点）
            for name in PREV_BASE:
                prev_values[name] += random.randint(5000, 20000)
                (out / f"{name}.prev").write_text(str(prev_values[name]) + "\n", encoding="utf-8")

            time.sleep(TICK)
    except KeyboardInterrupt:
        print("\n已停止。")


if __name__ == "__main__":
    main()
