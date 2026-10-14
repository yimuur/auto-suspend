// ============ DOM Elements ============

const configFormContainer = document.getElementById("config-form-container");
const configNotice = document.getElementById("config-notice");
const logsContainer = document.getElementById("logs-container");
const logsCount = document.getElementById("logs-count");
const updateTimeEl = document.getElementById("update-time");
const navTabs = document.querySelectorAll(".nav-tab");
const tabPanes = document.querySelectorAll(".tab-pane");

// 状态显示元素
const statusElems = {
  state: document.getElementById("state-value"),
  stateMeta: document.getElementById("state-meta"),
  idle: document.getElementById("idle-value"),
  idleMeta: document.getElementById("idle-meta"),
  fail: document.getElementById("fail-value"),
  interval: document.getElementById("interval-value"),
  window: document.getElementById("window-value"),
  idleReq: document.getElementById("idle-req-value"),
  hostname: document.getElementById("hostname-value"),
  platform: document.getElementById("platform-value"),
  suspendToggle: document.getElementById("suspend-toggle"),
  lastSuspendMeta: document.getElementById("last-suspend-meta"),
  uptime: document.getElementById("uptime-value"),
  suspendIcon: document.getElementById("suspend-icon"),
};

const buttons = {
  saveConfig: document.getElementById("save-config-btn"),
  resetConfig: document.getElementById("reset-config-btn"),
  loadLogs: document.getElementById("load-logs-btn"),
  clearLogs: document.getElementById("clear-logs-btn"),
  clearDisable: document.getElementById("clear-disable-btn"),
};

// 图表元素
const chartsDrives = document.getElementById("charts-drives");
const chartsContainer = document.getElementById("charts-container");

// ============ Utility Functions ============

function showNotice(message, type = "info") {
  configNotice.textContent = message;
  configNotice.className = `notice ${type}`.trim();
  if (type === "success" || type === "error") {
    setTimeout(() => {
      configNotice.className = "notice";
      configNotice.textContent = "";
    }, 4000);
  }
}

// 状态卡倒计时状态：由 refreshStatus 设置目标时间戳与模式，updateTime 每秒刷新实现实时倒计时
let countdownTargetTs = 0;   // 倒计时目标时间戳（epoch 秒）
let countdownMode = null;    // "cooldown" | "idle" | "suspend" | null

function updateTime() {
  const now = new Date();
  updateTimeEl.textContent = now.toLocaleTimeString("zh-CN");
  // 状态卡倒计时：每秒刷新（实时更新）
  if (countdownMode) {
    const remaining = Math.max(0, countdownTargetTs - Math.floor(now.getTime() / 1000));
    if (countdownMode === "cooldown") {
      statusElems.stateMeta.textContent = `剩余冷却时间: ${formatDurationDHM(remaining)}`;
    } else if (countdownMode === "idle") {
      statusElems.stateMeta.textContent = `保持 ${formatCountdownHHMMSS(remaining)} 后将进入休眠`;
    } else if (countdownMode === "suspend") {
      statusElems.stateMeta.textContent = `即将进入休眠：${formatCountdownMMSS(remaining)}`;
    }
  }
}

// 倒计时格式 "HH:MM:SS"（时:分:秒，补零对齐；小时超 99 时自然增长），与 SUSPENDING 的 MM:SS 同颗粒度
function formatCountdownHHMMSS(totalSeconds) {
  const total = Math.max(0, Math.floor(Number(totalSeconds) || 0));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const seconds = total % 60;
  const p = (n) => String(n).padStart(2, "0");
  return `${p(hours)}:${p(minutes)}:${p(seconds)}`;
}

// 倒计时格式 "MM:SS"（分:秒，补零对齐）
function formatCountdownMMSS(totalSeconds) {
  const total = Math.max(0, Math.floor(Number(totalSeconds) || 0));
  const minutes = Math.floor(total / 60);
  const seconds = total % 60;
  const p = (n) => String(n).padStart(2, "0");
  return `${p(minutes)}:${p(seconds)}`;
}

// 格式化日志时间戳（微秒）为 "YYYY/MM/DD HH:mm:ss"，补零以对齐前缀
function formatTimestamp(microseconds) {
  if (!microseconds || Number(microseconds) === 0) return "n/a";
  const d = new Date(Number(microseconds) / 1000);
  const p = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}/${p(d.getMonth() + 1)}/${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

// 休眠时长：0 显示 "0 分钟"，其余按天/时/分自动换算
function formatDuration(minutes) {
  const total = Math.floor(Number(minutes) || 0);
  if (total <= 0) return "0 分钟";
  return formatDurationDHM(total * 60);
}

// 格式化时长（分钟）为 "X 天 X 小时 X 分钟"（完整单位写法，用于“空闲要求”）
function formatDurationFull(minutes) {
  const totalMinutes = Math.floor(Number(minutes) || 0);
  if (totalMinutes <= 0) return "0 分钟";
  const days = Math.floor(totalMinutes / 1440);
  const hours = Math.floor((totalMinutes % 1440) / 60);
  const mins = totalMinutes % 60;
  const parts = [];
  if (days > 0) parts.push(`${days} 天`);
  if (hours > 0) parts.push(`${hours} 小时`);
  if (mins > 0) parts.push(`${mins} 分钟`);
  return parts.join(" ");
}

// 格式化时间戳（epoch 秒）为 "MM-DD HH:mm"
function formatDateTime(epochSeconds) {
  if (!epochSeconds || Number(epochSeconds) <= 0) return "从未";
  const d = new Date(Number(epochSeconds) * 1000);
  const pad = (n) => String(n).padStart(2, "0");
  return `${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

// 格式化时长（秒）为 "X 天 Y 时 Z 分"（数字与单位之间留 1 个英文空格）
function formatDurationDHM(totalSeconds) {
  const totalMinutes = Math.floor(Number(totalSeconds) / 60);
  if (totalMinutes <= 0) return "0 分";
  const days = Math.floor(totalMinutes / 1440);
  const hours = Math.floor((totalMinutes % 1440) / 60);
  const minutes = totalMinutes % 60;
  const parts = [];
  if (days > 0) parts.push(`${days} 天`);
  if (hours > 0) parts.push(`${hours} 时`);
  parts.push(`${minutes} 分`);
  return parts.join(" ");
}

// 本次连续运行时长 = 当前时间 - 上次唤醒时间
function formatUptime(lastResumeTs) {
  if (!lastResumeTs || Number(lastResumeTs) <= 0) return "—";
  const seconds = Math.floor(Date.now() / 1000) - Number(lastResumeTs);
  if (seconds < 0) return "—";
  return formatDurationDHM(seconds);
}

// 字节数自动换算为 B / KB / MB / GB（保留合适小数位，数字与单位之间留 1 个英文空格）
function formatBytes(bytes, precision) {
  const n = Number(bytes) || 0;
  if (n === 0) return "0 B";
  const units = ["B", "KB", "MB", "GB", "TB"];
  const i = Math.min(units.length - 1, Math.floor(Math.log(n) / Math.log(1024)));
  const val = n / Math.pow(1024, i);
  const digits = typeof precision === "number" ? precision : val >= 100 ? 0 : val >= 10 ? 1 : 2;
  return `${parseFloat(val.toFixed(digits))} ${units[i]}`;
}

// 根据数值自动挑选合适的单位（供整图统一的坐标轴使用）
function pickBytesUnit(bytes) {
  const n = Number(bytes) || 0;
  if (n >= 1024 ** 3) return { label: "GB", div: 1024 ** 3 };
  if (n >= 1024 ** 2) return { label: "MB", div: 1024 ** 2 };
  if (n >= 1024) return { label: "KB", div: 1024 };
  return { label: "B", div: 1 };
}

// 允许休眠窗口显示：0:00-24:00 -> 全天；开始>结束 -> 次日
function formatWindow(start, end) {
  const s = Number(start);
  const e = Number(end);
  if (s === 0 && e === 24) return "全天";
  if (s === e) return `${s}:00 - ${e}:00`;
  if (s > e) return `${s}:00 - ${e}:00 次日`;
  return `${s}:00 - ${e}:00`;
}

// 秒数格式化为 "xx分钟" / "xx小时xx分钟"
function formatSecondsToHM(totalSeconds) {
  const totalMinutes = Math.floor(Number(totalSeconds) / 60);
  if (totalMinutes <= 0) return `${totalSeconds} 秒`;
  if (totalMinutes < 60) return `${totalMinutes} 分钟`;
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  if (minutes === 0) return `${hours} 小时`;
  return `${hours} 小时 ${minutes} 分钟`;
}

// 当前状态对应的字体颜色类（仅文字着色）
const STATE_COLOR_CLASS = {
  ACTIVE: "state-green",
  IDLE: "state-amber",
  SUSPENDING: "state-red",
  COOLDOWN: "state-blue",
  UNKNOWN: "state-gray",
};

// 当前状态对应的卡片底色类（与字体颜色同步渲染）
const STATE_BG_CLASS = {
  ACTIVE: "state-bg-green",
  IDLE: "state-bg-amber",
  SUSPENDING: "state-bg-red",
  COOLDOWN: "state-bg-blue",
  UNKNOWN: "state-bg-gray",
};

async function apiFetch(url, options = {}) {
  const response = await fetch(url, {
    headers: {
      Accept: "application/json",
      ...(options.headers || {}),
    },
    ...options,
  });

  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(payload.error || `请求失败 (${response.status})`);
  }
  return payload;
}

// ============ Tab Navigation ============

function setupTabs() {
  navTabs.forEach((tab) => {
    tab.addEventListener("click", () => {
      const tabName = tab.dataset.tab;

      // 移除所有标签页与面板的激活状态
      navTabs.forEach((t) => t.classList.remove("active"));
      tabPanes.forEach((p) => p.classList.remove("active"));

      // 为选中的标签页与对应面板添加激活状态
      tab.classList.add("active");
      document.getElementById(tabName)?.classList.add("active");

      // 按需加载对应面板内容
      if (tabName === "charts") {
        loadCharts();
      } else if (tabName === "config") {
        // 仅在首次进入时加载；之后切走再切回保持 DOM 不动，避免丢失未保存的修改
        if (!configState.loaded) loadConfig();
      } else if (tabName === "logs") {
        // 日志通过按钮手动加载
      }
    });
  });
}

// ============ Charts (图表) ============

let CHART_INTERVAL_SEC = 300;     // 每点采样间隔（秒），随 config 的 check_interval 同步（用于忙期缺口判断）
let CHART_WINDOW_SEC = 6 * 3600;  // 当前选中的时间窗口总长度（秒），默认最近 6 小时
// 各硬件类型固定主题色（与顶部磁盘卡片一致，图表/曲线/P90 高亮统一不混用）
const CHART_COLORS = {
  hdd: "#f59e0b",
  ssd: "#0ea5e9",
  net: "#10b981",
};

const DRIVE_ICONS = {
  hdd: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
    <line x1="22" y1="12" x2="2" y2="12"></line>
    <path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"></path>
    <line x1="6" y1="16" x2="6.01" y2="16"></line>
    <line x1="10" y1="16" x2="10.01" y2="16"></line>
  </svg>`,
  ssd: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
    <rect x="4" y="4" width="16" height="16" rx="2" ry="2"></rect>
    <rect x="9" y="9" width="6" height="6"></rect>
    <line x1="9" y1="1" x2="9" y2="4"></line>
    <line x1="15" y1="1" x2="15" y2="4"></line>
    <line x1="9" y1="20" x2="9" y2="23"></line>
    <line x1="15" y1="20" x2="15" y2="23"></line>
    <line x1="20" y1="9" x2="23" y2="9"></line>
    <line x1="20" y1="14" x2="23" y2="14"></line>
    <line x1="1" y1="9" x2="4" y2="9"></line>
    <line x1="1" y1="14" x2="4" y2="14"></line>
  </svg>`,
  net: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
    <polyline points="22 12 18 12 15 21 9 3 6 12 2 12"></polyline>
  </svg>`,
};

const chartsState = { data: null, resizeTimer: null };

function isChartsTabActive() {
  return document.getElementById("charts")?.classList.contains("active");
}

function pad2(n) {
  return String(n).padStart(2, "0");
}

// 横轴时间标签：窗口跨度超过 1 天时附加日期（MM-DD HH:mm），否则仅 HH:mm
function formatAxisTime(d, showDate) {
  const hm = `${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
  return showDate ? `${pad2(d.getMonth() + 1)}-${pad2(d.getDate())} ${hm}` : hm;
}

function formatTickValue(v) {
  if (v >= 100) return String(Math.round(v));
  if (v >= 10) return String(parseFloat(v.toFixed(1)));
  return String(parseFloat(v.toFixed(2)));
}

async function loadCharts() {
  if (!isChartsTabActive()) return;
  try {
    const data = await apiFetch("/api/charts");
    chartsState.data = data;
    // 采样间隔随 config 同步（用于忙期缺口判断与说明信息）
    CHART_INTERVAL_SEC = Number(data.interval_sec) || 300;
    updateChartsWindowInfo(CHART_INTERVAL_SEC);
    renderDriveCards(data);
    renderAllCharts(data);
  } catch (error) {
    chartsDrives.innerHTML = `<div class="charts-empty">加载失败: ${escapeHtml(error.message)}</div>`;
    chartsContainer.innerHTML = `<div class="charts-empty">加载失败: ${escapeHtml(error.message)}</div>`;
  }
}

// 更新“历史采样柱状图”说明信息（与 shell 逻辑同口径：仅记录空闲 IDLE 状态下的读写）
function updateChartsWindowInfo(intervalSec) {
  const el = document.getElementById("charts-window-info");
  if (!el) return;
  const sec = Number(intervalSec) || 300;
  const intervalText = sec % 60 === 0 ? `${sec / 60} 分钟` : `${sec} 秒`;
  el.textContent = `采样间隔 ${intervalText} · 仅记录背景状态下的数据（CPU 空闲且无用户活动）`;
}

function driveCardHtml(icon, name, bytes, meta, kind) {
  return `
    <div class="card drive-card drive-${escapeHtml(kind)}">
      <div class="drive-icon">${icon}</div>
      <div class="drive-info">
        <div class="drive-name">${escapeHtml(name)}</div>
        <div class="drive-value">${formatBytes(bytes)}</div>
        <div class="drive-meta">${escapeHtml(meta)}</div>
      </div>
    </div>`;
}

function renderDriveCards(data) {
  const hdds = data.hdd || [];
  const ssds = data.ssd || [];
  const net = data.net || {};
  if (hdds.length === 0 && ssds.length === 0) {
    chartsDrives.innerHTML = '<div class="charts-empty">暂无数据</div>';
    return;
  }
  let html = "";
  hdds.forEach((d) => {
    html += driveCardHtml(DRIVE_ICONS.hdd, `HDD ${d.name}`, d.current_bytes, "机械硬盘 · 累计读写", "hdd");
  });
  ssds.forEach((d) => {
    html += driveCardHtml(DRIVE_ICONS.ssd, `SSD ${d.name}`, d.current_bytes, "固态硬盘 · 累计读写", "ssd");
  });
  if (typeof net.current_bytes === "number") {
    html += driveCardHtml(DRIVE_ICONS.net, "NET", net.current_bytes, "物理网卡 · 累计流量", "net");
  }
  chartsDrives.innerHTML = html;
}

// 按当前选中的时间窗口过滤采样点，返回 [{t, v, p90}]（时间升序）；无时间戳的旧格式采样跳过
// p90 直接取自 sample 文件每行的 P90 列（无该列或为 "-" 时为 null）
function filterSamplesByWindow(points, ts, p90s) {
  const nowSec = Math.floor(Date.now() / 1000);
  const out = [];
  for (let i = 0; i < points.length; i++) {
    const t = Number(ts[i]);
    if (!t) continue;
    if (t < nowSec - CHART_WINDOW_SEC) continue;
    const p90 = p90s ? p90s[i] : null;
    out.push({ t, v: points[i], p90: p90 == null ? null : p90 });
  }
  return out;
}

function renderAllCharts(data) {
  const hdds = data.hdd || [];
  const defs = [];

  hdds.forEach((d) => {
    defs.push({
      id: `hdd-${d.name}`,
      title: `HDD ${d.name}`,
      subtitle: "机械硬盘读写",
      points: d.samples_bytes || [],
      ts: d.samples_ts || [],
      p90s: d.samples_p90 || [],
      color: CHART_COLORS.hdd,
    });
  });

  defs.push({
    id: "ssd-total",
    title: "SSD 总计",
    subtitle: "固态硬盘读写",
    points: data.ssd_samples_bytes || [],
    ts: data.ssd_samples_ts || [],
    p90s: data.ssd_samples_p90 || [],
    color: CHART_COLORS.ssd,
  });

  defs.push({
    id: "net-total",
    title: "NET 总计",
    subtitle: "网络流量",
    points: data.net_samples_bytes || [],
    ts: data.net_samples_ts || [],
    p90s: data.net_samples_p90 || [],
    color: CHART_COLORS.net,
  });

  // 每张图先按当前选中的时间窗口过滤（含时间戳与 P90）
  defs.forEach((c) => {
    c.data = filterSamplesByWindow(c.points, c.ts, c.p90s);
  });

  if (defs.every((c) => c.data.length === 0)) {
    chartsContainer.innerHTML =
      '<div class="charts-empty">暂无数据</div>';
    return;
  }

  chartsContainer.innerHTML = defs
    .map((c) => {
      // 最新 P90 阈值：直接读取 sample 文件每行的 P90 列（当前窗口内最后一个非空值）
      let latestP90 = null;
      for (let i = c.data.length - 1; i >= 0; i--) {
        if (c.data[i].p90 != null) {
          latestP90 = c.data[i].p90;
          break;
        }
      }
      const p90Pill =
        latestP90 !== null
          ? `<span class="chart-p90-pill" style="color:${c.color};border-color:${c.color}66;background:${c.color}1f;">P90 ${formatBytes(latestP90)}</span>`
          : "";
      return `
      <div class="card chart-card">
        <div class="chart-head">
          <div>
            <div class="chart-title">${escapeHtml(c.title)}</div>
            <div class="chart-subtitle">${escapeHtml(c.subtitle)}</div>
          </div>
          ${p90Pill}
        </div>
        <div class="chart-canvas" data-chart="${escapeHtml(c.id)}" style="height: 220px;"></div>
      </div>`;
    })
    .join("");

  // 休眠区间（上次进入休眠 -> 上次唤醒）：所有图表共用同一区间，用竖线 + 色带标记
  const suspendRange =
    data.request_suspend_ts && data.last_resume_ts && data.last_resume_ts > data.request_suspend_ts
      ? { t1: data.request_suspend_ts, t2: data.last_resume_ts }
      : null;

  chartsContainer.querySelectorAll(".chart-canvas").forEach((canvas, i) => {
    renderChart(canvas, defs[i], suspendRange);
  });
}

// 渲染单张 SVG 柱状图（时间戳横坐标、忙期斜纹、休眠区间竖线、P90 高亮）
function renderChart(container, opts, suspendRange) {
  const { id, data, color } = opts;
  container.innerHTML = "";
  const width = container.clientWidth || 640;
  const height = container.clientHeight || 220;
  const pad = { top: 18, right: 22, bottom: 30, left: 54 };
  const plotW = Math.max(50, width - pad.left - pad.right);
  const plotH = Math.max(50, height - pad.top - pad.bottom);
  const svgNS = "http://www.w3.org/2000/svg";

  const svg = document.createElementNS(svgNS, "svg");
  svg.setAttribute("viewBox", `0 0 ${width} ${height}`);
  svg.setAttribute("width", "100%");
  svg.setAttribute("height", "100%");
  svg.setAttribute("preserveAspectRatio", "xMidYMid meet");

  if (data.length === 0) {
    const empty = document.createElementNS(svgNS, "text");
    empty.setAttribute("x", width / 2);
    empty.setAttribute("y", height / 2);
    empty.setAttribute("class", "chart-empty-label");
    empty.setAttribute("text-anchor", "middle");
    empty.textContent = "该时间范围内暂无采样";
    svg.appendChild(empty);
    container.appendChild(svg);
    return;
  }

  // —— 横坐标：采样点实际时间戳（升序）映射到绘图区 ——
  // 时间轴终点固定为当前时间（最后一个采样点通常略早于现在，图表右侧延伸至“现在”）
  const tMin = data[0].t;
  const tMax = Math.max(data[data.length - 1].t, Math.floor(Date.now() / 1000));
  const span = Math.max(1, tMax - tMin);
  const toX = (t) => pad.left + ((t - tMin) / span) * plotW;

  // —— 纵坐标最大刻度：取当前时间区间采样点的最大值（让柱体填满绘图区）——
  const maxVal = Math.max(...data.map((d) => d.v), 1);
  const unit = pickBytesUnit(maxVal);
  const toY = (v) => pad.top + plotH - (v / maxVal) * plotH;
  // 选中窗口跨度超过 1 天时，横坐标显示日期
  const showDate = CHART_WINDOW_SEC > 86400;

  // —— 横向网格线 + Y 轴刻度 ——
  const yTicks = 5;
  for (let i = 0; i <= yTicks; i++) {
    const val = (maxVal / yTicks) * i;
    const y = toY(val);
    const line = document.createElementNS(svgNS, "line");
    line.setAttribute("x1", pad.left);
    line.setAttribute("y1", y);
    line.setAttribute("x2", width - pad.right);
    line.setAttribute("y2", y);
    line.setAttribute("class", "chart-grid");
    svg.appendChild(line);

    const label = document.createElementNS(svgNS, "text");
    label.setAttribute("x", pad.left - 8);
    label.setAttribute("y", y + 4);
    label.setAttribute("class", "chart-axis-label");
    label.setAttribute("text-anchor", "end");
    label.textContent = formatTickValue(val / unit.div);
    svg.appendChild(label);
  }

  // —— Y 轴单位标签（KB / MB / GB，统一弱化色）——
  const unitLabel = document.createElementNS(svgNS, "text");
  unitLabel.setAttribute("x", pad.left);
  unitLabel.setAttribute("y", pad.top - 6);
  unitLabel.setAttribute("class", "chart-unit-label");
  unitLabel.setAttribute("text-anchor", "start");
  unitLabel.textContent = unit.label;
  svg.appendChild(unitLabel);

  // —— X 轴时间刻度（按实际时间范围均分 6 个刻度）——
  const tickCount = 6;
  for (let i = 0; i < tickCount; i++) {
    const t = tMin + (span / (tickCount - 1)) * i;
    const d = new Date(t * 1000);
    const label = document.createElementNS(svgNS, "text");
    label.setAttribute("x", toX(t));
    label.setAttribute("y", height - 8);
    label.setAttribute("class", "chart-axis-label");
    // 首尾刻度分别左/右对齐，避免长标签（含日期与分钟）被绘图区边缘裁切
    label.setAttribute("text-anchor", i === 0 ? "start" : i === tickCount - 1 ? "end" : "middle");
    // 时间轴终点固定为“现在”，用文字“现在”代替真实时间
    label.textContent = i === tickCount - 1 ? "Now" : formatAxisTime(d, showDate);
    svg.appendChild(label);
  }

  // —— 柱宽（按采样点实际时间戳定位；取平均间距与最小间距的较小者，避免样本少/簇集时重叠）——
  // 先算柱宽：忙区收缩与柱体绘制都要用到
  const avgPx = plotW / data.length;
  let minGapPx = Infinity;
  for (let i = 1; i < data.length; i++) {
    const gapPx = toX(data[i].t) - toX(data[i - 1].t);
    if (gapPx > 0) minGapPx = Math.min(minGapPx, gapPx);
  }
  // 限制柱体最大宽度：采样点过少（3-5 个）时平均间距很大，
  // 若不设上限，柱体会过宽并侵入两侧忙区而与其重叠
  const barWidth = Math.max(1, Math.min(avgPx, minGapPx, 40) * 0.7);

  // —— 忙期斜纹阴影（两个采样点时间戳间隔 > 采样间隔时，该段为忙状态）——
  const stripeId = `busy-stripe-${id}`;
  const defs = document.createElementNS(svgNS, "defs");
  const pattern = document.createElementNS(svgNS, "pattern");
  pattern.setAttribute("id", stripeId);
  pattern.setAttribute("width", "8");
  pattern.setAttribute("height", "8");
  pattern.setAttribute("patternUnits", "userSpaceOnUse");
  pattern.setAttribute("patternTransform", "rotate(45)");
  const pLine = document.createElementNS(svgNS, "line");
  pLine.setAttribute("x1", "0");
  pLine.setAttribute("y1", "0");
  pLine.setAttribute("x2", "0");
  pLine.setAttribute("y2", "8");
  pLine.setAttribute("stroke", "rgba(148, 163, 184, 0.4)");
  pLine.setAttribute("stroke-width", "2");
  pattern.appendChild(pLine);
  defs.appendChild(pattern);
  svg.appendChild(defs);

  const busyRegions = [];
  // 与 shell 端 rebase_if_gap 同口径：间隔超过采样间隔的 1.5 倍才判定为忙期缺口。
  // systemd timer 的 AccuracySec=30s 会带来 0~30s 随机延迟，使相邻采样点间隔在
  // [interval, interval+30s] 内抖动，直接用 interval 判忙会把正常连续采样误判为忙期。
  for (let i = 1; i < data.length; i++) {
    if (data[i].t - data[i - 1].t > CHART_INTERVAL_SEC * 1.5) {
      busyRegions.push({ t1: data[i - 1].t, t2: data[i].t });
    }
  }
  // 休眠区间（上次进入休眠 -> 上次唤醒）：裁剪到当前可见采样时间范围
  // 用于：忙区扣除重合时段 + 下方绘制休眠区间段（已休眠后不会再有“忙”）
  let suspendSeg = null;
  if (suspendRange && suspendRange.t1 > 0 && suspendRange.t2 > suspendRange.t1) {
    const ss1 = Math.max(tMin, Math.min(tMax, suspendRange.t1));
    const ss2 = Math.max(tMin, Math.min(tMax, suspendRange.t2));
    if (ss2 > ss1) suspendSeg = { s1: ss1, s2: ss2 };
  }

  busyRegions.forEach((r) => {
    // 忙区只覆盖采样点之间的空隙：两端各收缩半个柱宽，避免与柱体重叠
    // 若与休眠区间重合，扣除重合时间段（休眠期间不会产生“忙”）
    let segs = [{ t1: r.t1, t2: r.t2 }];
    if (suspendSeg) {
      const kept = [];
      for (const seg of segs) {
        if (suspendSeg.s1 <= seg.t1 && suspendSeg.s2 >= seg.t2) continue; // 完全被休眠区间覆盖
        if (suspendSeg.s2 <= seg.t1 || suspendSeg.s1 >= seg.t2) {
          kept.push(seg); // 与休眠区间无重合
        } else {
          if (suspendSeg.s1 > seg.t1) kept.push({ t1: seg.t1, t2: suspendSeg.s1 });
          if (suspendSeg.s2 < seg.t2) kept.push({ t1: suspendSeg.s2, t2: seg.t2 });
        }
      }
      segs = kept;
    }
    segs.forEach((seg) => {
      const x1 = toX(seg.t1) + barWidth / 2;
      const x2 = toX(seg.t2) - barWidth / 2;
      const width = x2 - x1;
      if (width <= 0) return;   // 空隙过窄时跳过，避免负宽
      const rect = document.createElementNS(svgNS, "rect");
      rect.setAttribute("x", x1);
      rect.setAttribute("y", pad.top);
      rect.setAttribute("width", width);
      rect.setAttribute("height", plotH);
      rect.setAttribute("fill", `url(#${stripeId})`);
      rect.setAttribute("class", "chart-busy");
      const tip = document.createElementNS(svgNS, "title");
      tip.textContent = `忙状态 ${formatAxisTime(new Date(seg.t1 * 1000), showDate)} ~ ${formatAxisTime(new Date(seg.t2 * 1000), showDate)}`;
      rect.appendChild(tip);
      svg.appendChild(rect);
    });
  });

  // —— 休眠区间段（上次进入休眠 -> 上次唤醒）：紫色色带 + 虚线边界 + 自适应月亮图标 ——
  if (suspendSeg) {
    const s1 = suspendSeg.s1;
    const s2 = suspendSeg.s2;
    const sx1 = toX(s1);
    const sx2 = toX(s2);
    const cx = (sx1 + sx2) / 2;

    // 半透明紫色色带（区间底色）
    const band = document.createElementNS(svgNS, "rect");
    band.setAttribute("x", sx1);
    band.setAttribute("y", pad.top);
    band.setAttribute("width", Math.max(1, sx2 - sx1));
    band.setAttribute("height", plotH);
    band.setAttribute("fill", "rgba(167, 139, 250, 0.14)");
    band.setAttribute("class", "chart-suspend-band");
    const bandTip = document.createElementNS(svgNS, "title");
    bandTip.textContent = `已休眠 ${formatAxisTime(new Date(s1 * 1000), showDate)} ~ ${formatAxisTime(new Date(s2 * 1000), showDate)}`;
    band.appendChild(bandTip);
    svg.appendChild(band);

    // 区间标记：仅月亮图标（与“休眠时长”卡同款），颜色与区间一致，
    // 大小随休眠区间宽度自适应（10~22px，区间越宽图标越大）
    const iconSize = Math.min(22, Math.max(10, (sx2 - sx1) * 0.18));
    const iconCenterY = pad.top + 12;
    const moon = document.createElementNS(svgNS, "svg");
    moon.setAttribute("x", cx - iconSize / 2);
    moon.setAttribute("y", iconCenterY - iconSize / 2);
    moon.setAttribute("width", iconSize);
    moon.setAttribute("height", iconSize);
    moon.setAttribute("viewBox", "0 0 24 24");
    moon.setAttribute("fill", "none");
    moon.setAttribute("stroke", "#a78bfa");
    moon.setAttribute("stroke-width", "2");
    moon.setAttribute("stroke-linecap", "round");
    moon.setAttribute("stroke-linejoin", "round");
    moon.setAttribute("class", "chart-suspend-moon");
    const moonPath = document.createElementNS(svgNS, "path");
    moonPath.setAttribute("d", "M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z");
    moon.appendChild(moonPath);
    svg.appendChild(moon);
  }

  // —— 柱状图（按采样点实际时间戳定位）——
  data.forEach((d) => {
    const x = toX(d.t);
    const y = toY(d.v);
    // 高度至少 2px：零值/极小值柱体也保持可见（否则全 0 数据图表只剩忙区斜纹）
    let barH = pad.top + plotH - y;
    let barY = y;
    if (barH < 2) {
      barH = 2;
      barY = pad.top + plotH - 2;   // 极矮柱体贴基线向上画，避免超出绘图区
    }
    const bar = document.createElementNS(svgNS, "rect");
    bar.setAttribute("x", x - barWidth / 2);
    bar.setAttribute("y", barY);
    bar.setAttribute("width", barWidth);
    bar.setAttribute("height", barH);
    bar.setAttribute("class", "chart-bar");
    bar.setAttribute("fill", color);
    const tip = document.createElementNS(svgNS, "title");
    tip.textContent = `${formatAxisTime(new Date(d.t * 1000), showDate)} · ${formatBytes(d.v)}`;
    bar.appendChild(tip);
    svg.appendChild(bar);
  });

  // —— P90 阈值（直接读取 sample 文件每行的 P90 列，web 不再计算）——
  // 最新 P90：取当前时间窗口内最后一个非空阈值（用于参考线与标签）
  let latestP90 = null;
  for (let i = data.length - 1; i >= 0; i--) {
    if (data[i].p90 != null) {
      latestP90 = data[i].p90;
      break;
    }
  }

  // P90 阈值变化曲线：逐点读取每行 P90 列，跳过空值（样本不足 24 时 shell 写入 "-"）
  let curvePath = "";
  let p90PointCount = 0;
  data.forEach((d) => {
    if (d.p90 == null) return;
    p90PointCount += 1;
    curvePath += `${p90PointCount === 1 ? "M" : "L"} ${toX(d.t)} ${toY(d.p90)} `;
  });
  const hasCurve = p90PointCount >= 2;

  if (latestP90 !== null) {
    const py = toY(latestP90);
    const dline = document.createElementNS(svgNS, "line");
    dline.setAttribute("x1", pad.left);
    dline.setAttribute("y1", py);
    dline.setAttribute("x2", width - pad.right);
    dline.setAttribute("y2", py);
    dline.setAttribute("class", "chart-p90-line");
    dline.setAttribute("style", `stroke:${color};`);
    svg.appendChild(dline);

    // 未绘制 P90 变化曲线（采样点不足 2 个）时，才在虚线端显示 P90 标签
    if (!hasCurve) {
      const plabel = document.createElementNS(svgNS, "text");
      plabel.setAttribute("x", width - pad.right);
      plabel.setAttribute("y", py - 6);
      plabel.setAttribute("class", "chart-p90-label");
      plabel.setAttribute("text-anchor", "end");
      plabel.setAttribute("style", `fill:${color};`);
      plabel.textContent = `P90 ${formatBytes(latestP90)}`;
      svg.appendChild(plabel);
    }
  }

  // —— P90 阈值变化曲线（白色细实线，叠在柱状图上）——
  if (hasCurve) {
    const curve = document.createElementNS(svgNS, "path");
    curve.setAttribute("d", curvePath.trim());
    curve.setAttribute("class", "chart-p90-curve");
    svg.appendChild(curve);
  }

  container.appendChild(svg);
}

// 窗口尺寸变化时按需重绘当前激活的图表
window.addEventListener("resize", () => {
  clearTimeout(chartsState.resizeTimer);
  chartsState.resizeTimer = setTimeout(() => {
    if (isChartsTabActive() && chartsState.data) {
      renderAllCharts(chartsState.data);
    }
  }, 200);
});

// 共用时间范围下拉：切换后重绘当前所有图表
const chartsWindowSelect = document.getElementById("charts-window-select");
if (chartsWindowSelect) {
  chartsWindowSelect.addEventListener("change", () => {
    CHART_WINDOW_SEC = Number(chartsWindowSelect.value) || 6 * 3600;
    if (isChartsTabActive() && chartsState.data) {
      renderAllCharts(chartsState.data);
    }
  });
}

// ============ Status & Refresh ============

// 上一次的“当前状态”（用于检测状态变更并读取最新日志）
let prevStateText = null;
// 横幅自动隐藏定时器（持续显示 10s 后隐藏）
let statusChangeHideTimer = null;
// 请求序号：避免并发的 /api/logs 响应乱序覆盖较新的横幅内容
let statusChangeReqSeq = 0;

// 当前状态变更时：从 journalctl 读取一条最新“状态变更”日志并显示在总览横幅中
async function loadLatestStatusChange() {
  const seq = ++statusChangeReqSeq;
  try {
    const response = await apiFetch("/api/logs?lines=30");
    // 期间已有更新的请求：丢弃本次旧响应，避免其提前隐藏/覆盖横幅
    if (seq !== statusChangeReqSeq) return;
    const logs = response.logs || [];
    // 取最新的一条状态变更日志：
    // - 以 [ 开头：状态迁移日志，如 "[IDLE] 系统已处于空闲状态"
    // - 以 == 开头：脚本首次启动日志，如 "======【自动休眠程序已启动 [Ver: 2.0]，系统开始监测...】======"
    const log = logs.find((l) => l.message && /^[\[=]/.test(l.message.trim()));
    const banner = document.getElementById("status-change");
    if (!banner) return;
    if (log) {
      document.getElementById("status-change-message").textContent = log.message;
      document.getElementById("status-change-time").textContent = formatTimestamp(log.timestamp);
      banner.hidden = false;
      // 触发一次高亮闪烁动画
      banner.classList.remove("flash");
      void banner.offsetWidth;
      banner.classList.add("flash");
      // 每次显示都从当前时刻重新计时，保证持续可见 10s
      if (statusChangeHideTimer) clearTimeout(statusChangeHideTimer);
      statusChangeHideTimer = setTimeout(() => {
        banner.hidden = true;
        statusChangeHideTimer = null;
      }, 10000);
    } else if (banner.hidden) {
      // 无可用日志：仅当横幅当前未在显示时才隐藏，
      // 避免把正处于 10s 显示期内的横幅提前关掉
      banner.hidden = true;
    }
  } catch (error) {
    // 日志加载失败时静默忽略（如开发环境无 journalctl）
  }
}

async function refreshStatus() {
  try {
    const data = await apiFetch("/api/status");

    // 当前状态：字体颜色与卡片底色同步变化（ACTIVE/IDLE/SUSPENDING/COOLDOWN/UNKNOWN）
    const stateText = (data.state || "UNKNOWN").toUpperCase();
    statusElems.state.textContent = stateText;
    statusElems.state.className = `card-value ${STATE_COLOR_CLASS[stateText] || "state-gray"}`;
    const stateCard = document.getElementById("state-card");
    if (stateCard) {
      stateCard.className = `card status-card primary ${STATE_BG_CLASS[stateText] || "state-bg-gray"}`;
    }

    // 当前状态发生变更时，读取并显示最新 journalctl 状态变更日志
    if (prevStateText !== stateText) {
      loadLatestStatusChange();
      prevStateText = stateText;
    }

    // 当前状态提示（由 updateTime 每秒刷新倒计时，实现实时更新）：
    // - COOLDOWN：剩余冷却时间
    // - IDLE：利用 STATE_TS 计算进入休眠剩余时间 "HH:MM:SS"
    // - SUSPENDING：进入休眠前倒计时 "MM:SS"（下次监测触发前）
    if (stateText === "COOLDOWN") {
      const cooldownSec = (Number(data.resume_cooldown_minutes) || 300) * 60;
      const lastResume = Number(data.last_resume_ts) || 0;
      if (lastResume > 0) {
        countdownTargetTs = lastResume + cooldownSec;
        countdownMode = "cooldown";
        statusElems.stateMeta.textContent = `剩余冷却时间: ${formatDurationDHM(Math.max(0, countdownTargetTs - Math.floor(Date.now() / 1000)))}`;
      } else {
        countdownMode = null;
        statusElems.stateMeta.textContent = "剩余冷却时间: --";
      }
    } else if (stateText === "IDLE") {
      const stateTs = Number(data.state_ts) || 0;
      const requiredSec = (Number(data.idle_minutes_required) || 60) * 60;
      if (stateTs > 0) {
        countdownTargetTs = stateTs + requiredSec;
        countdownMode = "idle";
        statusElems.stateMeta.textContent = `保持 ${formatCountdownHHMMSS(countdownTargetTs - Math.floor(Date.now() / 1000))} 后将进入休眠`;
      } else {
        countdownMode = null;
        statusElems.stateMeta.textContent = "";
      }
    } else if (stateText === "SUSPENDING") {
      const stateTs = Number(data.state_ts) || 0;
      const intervalSec = (Number(data.check_interval_min) || 5) * 60;
      if (stateTs > 0) {
        countdownTargetTs = stateTs + intervalSec;
        countdownMode = "suspend";
        statusElems.stateMeta.textContent = `即将进入休眠：${formatCountdownMMSS(countdownTargetTs - Math.floor(Date.now() / 1000))}`;
      } else {
        countdownMode = null;
        statusElems.stateMeta.textContent = "";
      }
    } else {
      countdownMode = null;
      statusElems.stateMeta.textContent = "";
    }

    // 休眠时长 = 上次唤醒 - 上次休眠（本次休眠的实际时长）；提示上次唤醒时间
    const sleepTs = Number(data.request_suspend_ts) || 0;
    const wakeTs = Number(data.last_resume_ts) || 0;
    statusElems.idle.textContent =
      sleepTs > 0 && wakeTs > sleepTs ? formatDuration((wakeTs - sleepTs) / 60) : "—";
    statusElems.idleMeta.textContent = `上次唤醒: ${formatDateTime(wakeTs)}`;

    // 休眠失败次数：0 时显示 "-"，非 0 时带单位显示并红色高亮，整卡底色同步红色渲染
    const failCnt = Number(data.suspend_fail_cnt) || 0;
    statusElems.fail.textContent = failCnt > 0 ? `${failCnt} 次` : "-";
    statusElems.fail.className = failCnt > 0 ? "info-value fail-highlight" : "info-value";
    const sysInfoCard = document.getElementById("system-info-card");
    if (sysInfoCard) sysInfoCard.classList.toggle("fail-card-bg", failCnt > 0);

    statusElems.interval.textContent = "5 分钟"; // 监测周期固定（与 systemd timer 一致）
    // 允许窗口：统一使用强调色（不再区分普通窗口 / 全天 / 次日）
    statusElems.window.textContent = formatWindow(data.window?.start ?? 0, data.window?.end ?? 24);
    // 空闲要求：自动换算为 "X 天 X 小时 X 分钟"
    statusElems.idleReq.textContent = formatDurationFull(data.idle_minutes_required || 60);
    statusElems.hostname.textContent = data.system?.hostname || "unknown";
    statusElems.platform.textContent = data.system?.platform || "linux";

    statusElems.lastSuspendMeta.textContent = `上次休眠: ${formatDateTime(data.request_suspend_ts)}`;
    statusElems.uptime.textContent = formatUptime(data.last_resume_ts);

    // 休眠开关：ON 绿色 / OFF 红色，文字颜色与卡片底色同步变化
    const suspendOn = Boolean(data.suspend_enabled);
    statusElems.suspendToggle.className = suspendOn ? "suspend-on" : "suspend-off";
    statusElems.suspendToggle.textContent = suspendOn ? "ON" : "OFF";
    const suspendCard = document.getElementById("suspend-card");
    if (suspendCard) {
      suspendCard.className = `card status-card ${suspendOn ? "suspend-card-on" : "suspend-card-off"}`;
    }

    // 电源图标颜色高亮：启用=绿色，禁用=红色
    if (statusElems.suspendIcon) {
      statusElems.suspendIcon.className = `card-icon ${
        suspendOn ? "icon-success" : "icon-danger"
      }`;
    }

    // 脚本禁用提示：存在 disable 标记文件时显示“手动移除限制”按钮
    const disableBanner = document.getElementById("disable-banner");
    if (disableBanner) disableBanner.hidden = !data.suspend_disabled_by_file;

    updateTime();
  } catch (error) {
    console.error("刷新状态失败:", error);
  }
}

// ============ Configuration Management ============

const configState = {
  defaults: {},
  current: {},
  diff: {},
  modified: new Set(),
  validationErrors: {},
  loaded: false, // 是否已成功加载并渲染过一次配置表单
};

async function loadConfig() {
  try {
    configFormContainer.innerHTML = '<div class="loading-spinner">加载配置中...</div>';

    const data = await apiFetch("/api/config");
    configState.defaults = data.defaults || {};
    configState.current = data.config || {};
    configState.diff = data.diff || {};
    configState.loaded = true;

    renderConfigForm();
    updateEditorInfo();
  } catch (error) {
    showNotice(`加载配置失败: ${error.message}`, "error");
    configFormContainer.innerHTML = `<div class="notice error">${escapeHtml(error.message)}</div>`;
  }
}

// 固定参数分组（由 systemd timer 等外部机制管理，网页端不显示、不可修改）
const HIDDEN_GROUPS = new Set(["check_interval"]);

// 数字参数的滑块范围预设（若 default.json 中带有 min/max/step 元数据则优先使用）
const NUMERIC_RANGES = {
  "suspend_window.hour_start": { min: 0, max: 24, step: 1 },
  "suspend_window.hour_end": { min: 0, max: 24, step: 1 },
  "idle_detection.idle_minutes_required": { min: 10, max: 1440, step: 10 },
  "idle_detection.resume_cooldown_minutes": { min: 10, max: 7200, step: 10 },
  "learning_parameters.learn_window": { min: 24, max: 1440, step: 12 },
  "learning_parameters.safety_factor": { min: 100, max: 200, step: 5 },
  "network_thresholds.min_net": { min: 0, max: 4194304, step: 65536 },
  "network_thresholds.max_net": { min: 4096, max: 104857600, step: 262144 },
  "network_thresholds.net_activity_floor": { min: 0, max: 104857600, step: 262144 },
  "hdd_thresholds.min_hdd": { min: 0, max: 65536, step: 64 },
  "hdd_thresholds.max_hdd": { min: 0, max: 1048576, step: 256 },
  "ssd_thresholds.min_ssd": { min: 0, max: 1048576, step: 256 },
  "ssd_thresholds.max_ssd": { min: 0, max: 10485760, step: 1024 },
  "cpu_thresholds.cpu_load_max": { min: 0, max: 4, step: 0.05 },
  "web_access.web_active_window": { min: 60, max: 86400, step: 60 },
};

// 吞吐量参数的“最小值/最大值”配对：限制最小值不能超过最大值（反之亦然）
const THROUGHPUT_PAIRS = [
  ["network_thresholds.min_net", "network_thresholds.max_net"],
  ["hdd_thresholds.min_hdd", "hdd_thresholds.max_hdd"],
  ["ssd_thresholds.min_ssd", "ssd_thresholds.max_ssd"],
];

function resolveNumberBounds(param, value) {
  // 1. 配置文件自带 min/max/step 元数据优先
  if (typeof param.min === "number" && typeof param.max === "number") {
    return {
      min: param.min,
      max: param.max,
      step: typeof param.step === "number" ? param.step : 1,
    };
  }
  // 2. 使用预设范围
  const preset = NUMERIC_RANGES[param.fullKey];
  if (preset) return preset;
  // 3. 兜底启发式：按数值量级推导
  const abs = Math.abs(value) || 1;
  const magnitude = Math.max(1, Math.pow(10, Math.floor(Math.log10(abs))));
  const isFloat = value % 1 !== 0;
  const step = isFloat ? Math.max(0.01, magnitude / 100) : Math.max(1, magnitude / 10);
  return { min: 0, max: Math.max(abs * 10, magnitude), step };
}

function renderControl(param, currentValue, defaultValue) {
  const type = typeof defaultValue;

  // 开关类 -> 按钮式拨动开关
  if (type === "boolean") {
    const on = Boolean(currentValue);
    return `
      <div class="switch-row">
        <label class="switch" title="点击切换">
          <input type="checkbox" class="config-switch" data-key="${escapeHtml(param.fullKey)}" ${on ? "checked" : ""} />
          <span class="switch-slider"></span>
        </label>
        <span class="switch-state ${on ? "on" : "off"}">${on ? "ON" : "OFF"}</span>
      </div>`;
  }

  // 数字类 -> 滑动条 + 直接输入框（联动）
  if (type === "number") {
    const num = Number(currentValue) || 0;
    const bounds = resolveNumberBounds(param, num);
    return `
      <div class="number-control">
        <input type="range" class="config-slider" data-key="${escapeHtml(param.fullKey)}"
          min="${bounds.min}" max="${bounds.max}" step="${bounds.step}" value="${num}" />
        <input type="number" class="config-input config-number" data-key="${escapeHtml(param.fullKey)}"
          min="${bounds.min}" max="${bounds.max}" step="${bounds.step}" value="${num}" />
      </div>`;
  }

  // 字符串类 -> 直接输入
  return `<input type="text" class="config-input" data-key="${escapeHtml(param.fullKey)}" value="${escapeHtml(String(currentValue))}" />`;
}

function renderConfigForm() {
  const switchParams = [];
  const groups = [];

  function traverseConfig(obj, path = "", groupDescription = "") {
    for (const [key, value] of Object.entries(obj)) {
      if (value === null || typeof value !== "object") continue;

      const currentPath = path ? `${path}.${key}` : key;

      // 跳过隐藏分组（如 check_interval 固定参数）
      if (HIDDEN_GROUPS.has(currentPath)) continue;

      if ("value" in value && "description" in value) {
        // 这是一个配置参数
        const param = { key, fullKey: currentPath, ...value };
        if (typeof param.value === "boolean") {
          // 开关类参数统一放入左列
          switchParams.push(param);
        } else {
          let group = groups.find((g) => g.name === path);
          if (!group) {
            group = { name: path, description: groupDescription, params: [] };
            groups.push(group);
          }
          group.params.push(param);
        }
      } else {
        // 这是一个分组；若带 description 字符串则作为分组说明
        const desc =
          typeof value === "object" && "description" in value && typeof value.description === "string"
            ? value.description
            : "";
        traverseConfig(value, currentPath, desc);
      }
    }
  }

  traverseConfig(configState.defaults);

  // suspend_enabled 固定在开关列表第一位
  switchParams.sort((a, b) => {
    if (a.fullKey === "general.suspend_enabled") return -1;
    if (b.fullKey === "general.suspend_enabled") return 1;
    return 0;
  });

  let html = '<div class="config-form">';
  html += '<div class="config-columns">';

  // —— 左列：开关类参数（固定显示）——
  html += '<div class="config-column config-column-switches">';
  html += '<div class="config-group">';
  html += '<h3 class="config-group-title">开关设置</h3>';
  html += '<p class="config-group-description">常用功能总开关</p>';
  if (switchParams.length === 0) {
    html += '<div class="config-group-description">暂无开关类参数</div>';
  }
  for (const param of switchParams) {
    html += renderConfigItem(param, "switch");
  }
  html += '</div>';
  html += '</div>';

  // —— 右列：数值 / 字符串等参数（按分组显示）——
  html += '<div class="config-column config-column-params">';
  if (groups.length === 0) {
    html += '<div class="config-group-description">暂无其他参数</div>';
  }
  for (const group of groups) {
    const groupTitle = group.name || "基础配置";
    html += `<div class="config-group">`;
    html += `<h3 class="config-group-title">${escapeHtml(groupTitle)}</h3>`;
    if (group.description) {
      html += `<p class="config-group-description">${escapeHtml(group.description)}</p>`;
    }
    for (const param of group.params) {
      html += renderConfigItem(param, "param");
    }
    html += `</div>`;
  }
  html += '</div>';

  html += '</div>'; // config-columns
  html += '</div>'; // config-form

  configFormContainer.innerHTML = html;

  // 绑定事件：输入框 / 滑块 / 开关
  document.querySelectorAll(".config-input, .config-slider, .config-switch").forEach((input) => {
    input.addEventListener("change", handleConfigChange);
    input.addEventListener("input", handleConfigChange);
  });
}

// 根据配置参数类型生成联动提示：
// 流量相关（network/hdd/ssd 阈值）-> "当前：xxKB/MB/GB / 5min"
// 时间相关（时长/时刻）-> "当前：xx小时xx分钟"
function formatParamHint(fullKey, value) {
  const num = Number(value);
  if (Number.isNaN(num)) return null;

  // 流量相关：字节直接展示；扇区(512B)换算为字节后展示，周期为 5 分钟
  if (fullKey.startsWith("network_thresholds.")) {
    return `当前：${formatBytes(num)} / 5min`;
  }
  if (fullKey.startsWith("hdd_thresholds.") || fullKey.startsWith("ssd_thresholds.")) {
    return `当前：${formatBytes(num * 512)} / 5min`;
  }

  // 时间相关：统一换算为秒再格式化
  if (fullKey === "learning_parameters.learn_window") {
    // 学习窗口总时长 = learn_window（采样点数）× 采样间隔（秒），换算为 "DD 天 HH 小时"
    const intervalSec = Number(getCurrentScalar("check_interval.seconds")) || 300;
    const totalSec = Math.max(0, Math.floor(num * intervalSec));
    const days = Math.floor(totalSec / 86400);
    const hours = Math.floor((totalSec % 86400) / 3600);
    return `当前等效：${days > 0 ? days + ' 天 ' : ''}${hours} 小时`;
    // return `当前：${days} 天 ${hours} 小时`;
  }
  if (fullKey === "web_access.web_active_window") {
    return `当前：${formatSecondsToHM(num)}`;
  }
  if (fullKey === "idle_detection.idle_minutes_required" || fullKey === "idle_detection.resume_cooldown_minutes") {
    return `当前：${formatSecondsToHM(num * 60)}`;
  }
  if (fullKey === "suspend_window.hour_start") {
    return `当前：${num}:00`;
  }
  if (fullKey === "suspend_window.hour_end") {
    return num === 24 ? "当前：24:00（全天）" : `当前：${num}:00`;
  }

  return null;
}

// 默认值显示文本：布尔值显示为 开/关，其余类型直接显示
function formatDefaultValue(value) {
  if (typeof value === "boolean") return value ? "开" : "关";
  return String(value);
}

function renderConfigItem(param, variant) {
  const mergedNode = getValueByPath(configState.current, param.fullKey);
  const currentValue =
    mergedNode && typeof mergedNode === "object" && "value" in mergedNode ? mergedNode.value : param.value;
  const defaultValue = param.value;
  // “已修改 ✓”：表示存在“已保存”的覆盖项（已保存值 ≠ 默认值）；未保存的改动用 ⚠ 提示
  const hasSavedOverride = currentValue !== defaultValue;

  const itemClass = variant === "switch" ? "config-item config-item-switch" : "config-item";

  let html = `<div class="${itemClass}">`;
  html += `<div class="config-label">`;
  html += `<div class="config-label-name">${escapeHtml(param.key)}</div>`;
  html += `<div class="config-label-description">${escapeHtml(param.description)}</div>`;

  if (param.unit) {
    html += `<div class="config-label-meta">单位: ${escapeHtml(param.unit)}</div>`;
  }
  // 联动提示：能按当前值动态换算的参数显示实时提示，其余保留固定 note
  const hintText = formatParamHint(param.fullKey, currentValue);
  if (hintText) {
    html += `<div class="config-label-meta config-hint config-hint-dynamic" data-key="${escapeHtml(param.fullKey)}">${hintText}</div>`;
  } else if (param.note) {
    html += `<div class="config-label-meta config-hint">注: ${escapeHtml(param.note)}</div>`;
  }

  html += `</div>`;
  html += `<div class="config-input-wrapper">`;

  html += renderControl(param, currentValue, defaultValue);

  html += `<div class="config-input-value">`;
  html += `<span class="config-input-value-default">默认: ${escapeHtml(formatDefaultValue(defaultValue))}</span>`;
  html += `<span class="config-input-value-current" style="display:${hasSavedOverride ? "" : "none"}">已修改 ✓</span>`;
  html += `</div>`;

  const error = configState.validationErrors[param.fullKey] || "";
  html += `<div class="config-error" data-key="${escapeHtml(param.fullKey)}">${error ? escapeHtml(error) : ""}</div>`;

  html += `</div>`;
  html += `</div>`;

  return html;
}

function handleConfigChange(event) {
  const target = event.target;
  const key = target.dataset.key;
  if (!key) return;

  const defaultValue = getDefaultScalar(key);
  const expectedType = typeof defaultValue;

  let validValue;
  let error = "";

  try {
    if (expectedType === "number") {
      validValue = parseFloat(target.value);
      if (isNaN(validValue)) throw new Error("必须为数字");
    } else if (expectedType === "boolean") {
      validValue = target.checked;
    } else {
      validValue = String(target.value);
    }
    configState.validationErrors[key] = "";
  } catch (e) {
    error = e.message;
    validValue = undefined;
    configState.validationErrors[key] = error;
  }

  const configItem = target.closest(".config-item");
  if (!configItem) return;

  // 吞吐量参数：限制最小值不能超过最大值（反之最大值不能低于最小值）
  if (typeof validValue === "number" && !Number.isNaN(validValue)) {
    const pair = THROUGHPUT_PAIRS.find(([minKey, maxKey]) => key === minKey || key === maxKey);
    if (pair) {
      const [minKey, maxKey] = pair;
      const counterpartKey = key === minKey ? maxKey : minKey;
      const counterpart = document.querySelector(`.config-input[data-key="${CSS.escape(counterpartKey)}"]`);
      if (counterpart) {
        const cVal = parseFloat(counterpart.value);
        if (!Number.isNaN(cVal)) {
          const clamped = key === minKey ? Math.min(validValue, cVal) : Math.max(validValue, cVal);
          if (clamped !== validValue) {
            validValue = clamped;
            target.value = clamped;
          }
        }
      }
    }
  }

  // 滑块 <-> 数字输入框 联动
  if (target.classList.contains("config-slider") || target.classList.contains("config-number")) {
    const slider = configItem.querySelector(".config-slider");
    const number = configItem.querySelector(".config-number");
    if (slider && number) {
      if (target.classList.contains("config-slider")) {
        number.value = target.value;
      } else {
        slider.value = target.value;
      }
    }
  }

  // 开关状态文字
  if (expectedType === "boolean") {
    const stateEl = configItem.querySelector(".switch-state");
    if (stateEl) {
      const on = target.checked;
      stateEl.textContent = on ? "ON" : "OFF";
      stateEl.className = `switch-state ${on ? "on" : "off"}`;
    }
  }

  // 未保存修改跟踪：对比“已保存”的值；并就地刷新 “修改 ✓ / ⚠” 显示
  const savedValue = getCurrentScalar(key);
  const hasUnsavedChange = validValue !== undefined && validValue !== savedValue;
  if (hasUnsavedChange) {
    configState.modified.add(key);
  } else {
    configState.modified.delete(key);
  }
  updateItemIndicator(key);
  updateEditorInfo();

  // 错误显示
  const errorEl = configItem.querySelector(`.config-error[data-key="${CSS.escape(key)}"]`);
  if (errorEl) {
    errorEl.textContent = error;
  }

  // 联动提示：滑动/输入时实时换算（流量 -> KB/MB/GB / 5min；时间 -> 小时/分钟）
  if (validValue !== undefined) {
    const hintEl = configItem.querySelector(`.config-hint-dynamic[data-key="${CSS.escape(key)}"]`);
    if (hintEl) {
      const hint = formatParamHint(key, validValue);
      if (hint) hintEl.textContent = hint;
    }
  }

  // 开关类参数：无需点击保存，直接自动保存（防抖，避免连点重复请求）
  if (expectedType === "boolean" && validValue !== undefined) {
    scheduleSwitchAutoSave(key, validValue);
  }
}

function getValueByPath(obj, path) {
  return path.split(".").reduce((current, prop) => current?.[prop], obj);
}

// 取配置参数节点的标量默认值（defaults 中参数节点形如 {value, description, ...}）
function getDefaultScalar(path) {
  const node = getValueByPath(configState.defaults, path);
  return node && typeof node === "object" && "value" in node ? node.value : node;
}

// 取配置参数节点“当前已保存”的标量值
function getCurrentScalar(path) {
  const node = getValueByPath(configState.current, path);
  return node && typeof node === "object" && "value" in node ? node.value : getDefaultScalar(path);
}

// 更新顶部状态栏提示（有未保存修改时给出提示）
function updateEditorInfo() {
  const el = document.getElementById("editor-info");
  if (!el) return;
  if (configState.modified.size > 0) {
    el.textContent = `有 ${configState.modified.size} 项未保存的修改`;
    el.classList.add("editor-info-dirty");
  } else {
    el.textContent = "配置已加载";
    el.classList.remove("editor-info-dirty");
  }
}

// 轻量提示（右上角自动消失）
function showToast(message, type = "info") {
  const toast = document.createElement("div");
  toast.className = `toast toast-${type}`;
  toast.textContent = message;
  document.body.appendChild(toast);
  requestAnimationFrame(() => toast.classList.add("show"));
  setTimeout(() => {
    toast.classList.remove("show");
    setTimeout(() => toast.remove(), 300);
  }, 2200);
}

// 统计差异里的叶子参数个数（排除分组节点）
function countDiffItems(diff) {
  let count = 0;
  (function walk(node) {
    if (!node || typeof node !== "object") return;
    for (const v of Object.values(node)) {
      if (v && typeof v === "object") {
        if ("value" in v) count += 1;
        else walk(v);
      }
    }
  })(diff);
  return count;
}

// 成功确认对话框
function showConfirmDialog(title, message, onConfirm) {
  const overlay = document.createElement("div");
  overlay.className = "modal-overlay";
  overlay.innerHTML = `
    <div class="modal">
      <div class="modal-icon">✓</div>
      <h3>${escapeHtml(title)}</h3>
      <p>${escapeHtml(message)}</p>
      <div class="modal-actions">
        <button class="btn btn-primary" data-modal-ok>确定</button>
      </div>
    </div>`;
  document.body.appendChild(overlay);
  requestAnimationFrame(() => overlay.classList.add("show"));
  const close = () => {
    overlay.classList.remove("show");
    setTimeout(() => overlay.remove(), 200);
  };
  overlay.querySelector("[data-modal-ok]").addEventListener("click", () => {
    close();
    if (onConfirm) onConfirm();
  });
  overlay.addEventListener("click", (e) => {
    if (e.target === overlay) close();
  });
}

// 开关类参数自动保存（防抖，避免快速连点重复请求）
const switchAutoSaveTimers = {};

function scheduleSwitchAutoSave(key, value) {
  if (switchAutoSaveTimers[key]) clearTimeout(switchAutoSaveTimers[key].timer);
  switchAutoSaveTimers[key] = { timer: null, value };
  switchAutoSaveTimers[key].timer = setTimeout(() => {
    const latest = switchAutoSaveTimers[key].value;
    delete switchAutoSaveTimers[key];
    performSwitchAutoSave(key, latest);
  }, 300);
}

// 根据“已保存的合并配置”计算与默认值的差异（嵌套结构），保留所有已保存的自定义项
function diffFromMerged(obj, defaults, path = "") {
  const result = {};
  for (const [key, value] of Object.entries(obj)) {
    if (value === null || typeof value !== "object") continue;
    const currentPath = path ? `${path}.${key}` : key;
    const defaultNode = defaults && typeof defaults === "object" ? defaults[key] : undefined;
    if ("value" in value) {
      const defaultVal =
        defaultNode && typeof defaultNode === "object" && "value" in defaultNode ? defaultNode.value : undefined;
      if (value.value !== defaultVal) {
        result[currentPath] = { value: value.value };
      }
    } else {
      Object.assign(result, diffFromMerged(value, defaultNode || {}, currentPath));
    }
  }
  return result;
}

async function performSwitchAutoSave(key, value) {
  // 基于“已保存状态”做深拷贝，只应用本次开关变更，再计算完整差异提交。
  // 这样既能保留其他已保存的自定义项，又不会把尚未保存的数值编辑一并提交。
  const merged = JSON.parse(JSON.stringify(configState.current || {}));
  const parts = key.split(".");
  let cur = merged;
  for (let i = 0; i < parts.length - 1; i++) {
    cur[parts[i]] = cur[parts[i]] || {};
    cur = cur[parts[i]];
  }
  if (cur[parts[parts.length - 1]] && typeof cur[parts[parts.length - 1]] === "object") {
    cur[parts[parts.length - 1]].value = value;
  } else {
    cur[parts[parts.length - 1]] = { value };
  }
  const payload = diffFromMerged(merged, configState.defaults);

  try {
    const result = await apiFetch("/api/config", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    configState.current = result.config || configState.current;
    configState.diff = result.diff || configState.diff;
    configState.modified.delete(key);
    updateItemIndicator(key);
    updateEditorInfo();
    showToast("开关设置已自动保存", "success");
  } catch (error) {
    showToast(`自动保存失败: ${error.message}`, "error");
    configState.modified.add(key);
    updateEditorInfo();
  }
}

function buildConfigFromForm() {
  const config = {};

  // 只收集“权威”控件：开关(checkbox) / 数字输入框 / 文本输入框（滑块由数字框联动，不重复收集）
  document.querySelectorAll(".config-switch, .config-input").forEach((input) => {
    const key = input.dataset.key;
    if (!key) return;

    const defaultValue = getDefaultScalar(key);
    const expectedType = typeof defaultValue;
    let value = input.classList.contains("config-switch") ? input.checked : input.value;

    // 类型归一化（输入框值多为字符串，需与默认值同类型比较）
    if (expectedType === "number") {
      value = parseFloat(value);
    } else if (expectedType === "boolean") {
      value = Boolean(value);
    } else {
      value = String(value);
    }

    // 只保存与默认值不同的项
    if (value !== defaultValue) {
      const parts = key.split(".");
      let current = config;
      for (let i = 0; i < parts.length - 1; i++) {
        current[parts[i]] = current[parts[i]] || {};
        current = current[parts[i]];
      }
      current[parts[parts.length - 1]] = { value };
    }
  });

  return config;
}

async function saveConfig() {
  try {
    // 始终提交“完整差异”：既保存新增修改，也清除已恢复为默认的项
    const hadDiff = Object.keys(configState.diff).length > 0;
    const config = buildConfigFromForm();
    const result = await apiFetch("/api/config", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(config),
    });

    // 更新状态（defaults 始终是真正的默认配置，用于“修改标记”对比）
    configState.defaults = result.defaults || result.config || {};
    configState.current = result.config || {};
    configState.diff = result.diff || {};
    configState.modified.clear();
    updateEditorInfo();

    const count = result.saved_diff ? countDiffItems(result.saved_diff) : 0;
    let message;
    if (count > 0) {
      message = `已保存 ${count} 项配置修改`;
    } else if (hadDiff) {
      message = "所有参数已恢复为默认值";
    } else {
      message = "没有需要保存的修改";
    }

    renderConfigForm();
    await refreshStatus();

    // 保存成功弹出确认对话框（替代常驻的“保存成功”提示）
    if (count > 0 || hadDiff) {
      showConfirmDialog("保存成功", message);
    } else {
      showToast(message, "info");
    }
  } catch (error) {
    showNotice(`保存失败: ${error.message}`, "error");
    updateEditorInfo();
  }
}

async function resetConfig() {
  if (!confirm("确定要恢复默认配置吗? 所有自定义配置将被清除。")) return;

  try {
    const response = await apiFetch("/api/reset-config", {
      method: "POST",
    });

    configState.defaults = response.defaults || response.config || {};
    configState.current = response.config || {};
    configState.diff = {};
    configState.modified.clear();
    configState.validationErrors = {};

    updateEditorInfo();
    renderConfigForm();
    await refreshStatus();
    showConfirmDialog("恢复默认", "所有配置已恢复为默认值");
  } catch (error) {
    showNotice(`恢复失败: ${error.message}`, "error");
  }
}

// 就地刷新单个参数项的“已修改 ✓ / ⚠”显示：
// - ⚠：当前输入值 ≠ 已保存值（存在未保存修改）
// - “已修改 ✓”：已保存值 ≠ 默认值 且 当前无未保存修改（存在已保存覆盖项）
function updateItemIndicator(key) {
  // 优先读取“权威”控件（数字输入框 > 滑块 > 开关 > 文本）：
  // 滑块会按 step 取整产生微小偏差，直接读取可能把“已恢复为保存值”误判为未保存
  const input =
    document.querySelector(`.config-number[data-key="${CSS.escape(key)}"]`) ||
    document.querySelector(`.config-slider[data-key="${CSS.escape(key)}"]`) ||
    document.querySelector(`.config-switch[data-key="${CSS.escape(key)}"]`) ||
    document.querySelector(`[data-key="${CSS.escape(key)}"]`);
  if (!input) return;
  const item = input.closest(".config-item");
  if (!item) return;

  const savedValue = getCurrentScalar(key);
  const defaultValue = getDefaultScalar(key);
  let liveValue;
  if (input.classList.contains("config-switch")) {
    liveValue = input.checked;
  } else if (input.classList.contains("config-number") || input.classList.contains("config-slider")) {
    liveValue = parseFloat(input.value);
    if (Number.isNaN(liveValue)) liveValue = input.value;
  } else {
    liveValue = input.value;
  }

  // 未保存修改（⚠）
  const isUnsaved = liveValue !== savedValue;
  item.classList.toggle("modified", isUnsaved);
  // “已修改 ✓”：仅在无未保存修改且存在已保存覆盖项时显示
  const savedEl = item.querySelector(".config-input-value-current");
  if (savedEl) savedEl.style.display = savedValue !== defaultValue && !isUnsaved ? "" : "none";
}

// 就地更新配置表单中的 suspend_enabled 开关显示（不重建表单，保留其他未保存的修改）
function updateSuspendSwitchDisplay(enabled) {
  const checkbox = document.querySelector('.config-switch[data-key="general.suspend_enabled"]');
  if (!checkbox) return;
  const item = checkbox.closest(".config-item");
  const on = Boolean(enabled);
  checkbox.checked = on;

  if (item) {
    const stateEl = item.querySelector(".switch-state");
    if (stateEl) {
      stateEl.textContent = on ? "ON" : "OFF";
      stateEl.className = `switch-state ${on ? "on" : "off"}`;
    }
  }
  // 刷新 “修改 ✓ / ⚠” 显示
  updateItemIndicator("general.suspend_enabled");
}

async function toggleSuspend() {
  try {
    const response = await apiFetch("/api/toggle-suspend", {
      method: "POST",
    });
    const enabled = response.config?.general?.suspend_enabled?.value;
    showToast(`休眠开关已切换为: ${enabled ? "开启" : "关闭"}`, "success");

    // 更新内存配置状态与差异（不重建表单，避免丢失配置页未保存的修改）
    configState.current = response.config || configState.current;
    configState.defaults = response.defaults || configState.defaults;
    configState.diff = diffFromMerged(configState.current, configState.defaults);
    configState.modified.delete("general.suspend_enabled");
    updateSuspendSwitchDisplay(enabled);
    updateEditorInfo();
    await refreshStatus();
  } catch (error) {
    showToast(`切换失败: ${error.message}`, "error");
  }
}

// 手动移除禁用标记（连续休眠失败导致的脚本禁用）
async function clearDisableRestriction() {
  if (!confirm("确定要移除禁用标记并恢复自动休眠脚本吗？")) return;
  try {
    const result = await apiFetch("/api/clear-disable", { method: "POST" });
    showToast(
      result.removed ? "已移除禁用标记，自动休眠已恢复" : "当前不存在禁用标记",
      result.removed ? "success" : "info"
    );
    await refreshStatus();
  } catch (error) {
    showToast(`移除失败: ${error.message}`, "error");
  }
}

// ============ Logs Management ============

function getPriorityClass(priority) {
  const p = String(priority || "6");
  return `priority-${p}`;
}

function getPriorityName(priority) {
  const names = {
    "0": "EMERGENCY",
    "1": "ALERT",
    "2": "CRITICAL",
    "3": "ERROR",
    "4": "WARNING",
    "5": "NOTICE",
    "6": "INFO",
    "7": "DEBUG",
  };
  return names[String(priority)] || "UNKNOWN";
}

async function loadLogs() {
  try {
    logsCount.textContent = "加载中...";
    const response = await apiFetch("/api/logs?lines=100");

    if (!response.ok || !Array.isArray(response.logs)) {
      throw new Error("日志格式错误");
    }

    logsContainer.innerHTML = "";

    if (response.logs.length === 0) {
      logsContainer.innerHTML =
        '<div class="logs-empty">暂无日志记录</div>';
      logsCount.textContent = "0 条日志";
      return;
    }

    response.logs.forEach((log) => {
      const entry = document.createElement("div");
      const priorityClass = getPriorityClass(log.priority);
      const timestamp = formatTimestamp(log.timestamp);

      entry.className = `log-entry ${priorityClass}`;
      entry.innerHTML = `
        <span class="log-time">${timestamp}</span>
        <span class="log-message">${escapeHtml(log.message)}</span>
      `;
      entry.title = `${getPriorityName(log.priority)} (${log.priority})`;

      logsContainer.appendChild(entry);
    });

    logsCount.textContent = `${response.logs.length} 条日志`;
  } catch (error) {
    logsContainer.innerHTML = `
      <div class="logs-empty" style="color: #fca5a5;">
        加载日志失败: ${escapeHtml(error.message)}
      </div>
    `;
    logsCount.textContent = "加载失败";
  }
}

function clearLogs() {
  logsContainer.innerHTML =
    '<div class="logs-empty">日志已清空</div>';
  logsCount.textContent = "已清空";
}

function escapeHtml(text) {
  const div = document.createElement("div");
  div.textContent = text;
  return div.innerHTML;
}

// ============ Event Listeners ============

buttons.saveConfig.addEventListener("click", saveConfig);
buttons.resetConfig.addEventListener("click", resetConfig);
buttons.loadLogs.addEventListener("click", loadLogs);
buttons.clearLogs.addEventListener("click", clearLogs);
if (buttons.clearDisable) buttons.clearDisable.addEventListener("click", clearDisableRestriction);

// 点击电源图标切换休眠开关（含键盘无障碍支持）
if (statusElems.suspendIcon) {
  statusElems.suspendIcon.addEventListener("click", toggleSuspend);
  statusElems.suspendIcon.addEventListener("keydown", (e) => {
    if (e.key === "Enter" || e.key === " ") {
      e.preventDefault();
      toggleSuspend();
    }
  });
}

// ============ Initialization ============

function init() {
  setupTabs();
  refreshStatus();
  loadConfig();
  updateTime();
  setInterval(refreshStatus, 3000);
  setInterval(updateTime, 1000);
  // 图表仅在选项卡激活时自动刷新（每 15 秒）
  setInterval(() => {
    if (isChartsTabActive()) loadCharts();
  }, 15000);
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", init);
} else {
  init();
}

