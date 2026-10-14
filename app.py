from __future__ import annotations

import json
import os
import subprocess
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from flask import Flask, jsonify, request

BASE_DIR = Path(__file__).resolve().parent
CONFIG_DIR = BASE_DIR / "config"
DEFAULT_CONFIG_PATH = CONFIG_DIR / "default.json"
USER_CONFIG_PATH = CONFIG_DIR / "config.json"
# 状态目录：开发环境（存在 dev_state 目录）使用本地样例数据，否则使用 /run/auto-suspend
# 查看当前目录是否存在“dev_state”目录判断是否为开发环境（默认发布）
FLASK_ENV = "development" if (BASE_DIR / "dev_state").exists() else "production"
STATE_DIR = BASE_DIR / "dev_state" if FLASK_ENV == "development" else Path("/run/auto-suspend")
STATE_FILE = STATE_DIR / "state"
DISABLE_FILE = STATE_DIR / "disable"   # 连续休眠失败时由 shell 脚本创建的禁用标记文件

app = Flask(__name__, template_folder=str(BASE_DIR / "templates"), static_folder=str(BASE_DIR / "static"))

if FLASK_ENV == "development":
    app.config["TEMPLATES_AUTO_RELOAD"] = True
    app.jinja_env.auto_reload = True
    app.config["JSON_SORT_KEYS"] = False  # 开发环境关闭排序方便调试
    # 生产环境（NAS 正式运行）时建议设置 FLASK_ENV=production：
    # 将 JSON_SORT_KEYS 设为 True 以保持数据顺序稳定
else:
    app.config["JSON_SORT_KEYS"] = True  # 生产环境保持顺序稳定


def _read_json(path: Path, default: Any = None) -> Any:
    if not path.exists():
        return default
    try:
        # utf-8-sig 可同时兼容带 BOM 与不带 BOM 的 UTF-8 文件
        # （Windows 编辑器 / PowerShell 保存时常会写入 BOM，否则 json.load 会直接报错）
        with path.open("r", encoding="utf-8-sig") as handle:
            return json.load(handle)
    except Exception:
        return default


def _write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2)
        handle.write("\n")


def _deep_merge(base: Any, override: Any) -> Any:
    if not isinstance(base, dict) or not isinstance(override, dict):
        return override if override is not None else base

    merged = json.loads(json.dumps(base))
    for key, value in override.items():
        if isinstance(merged.get(key), dict) and isinstance(value, dict):
            merged[key] = _deep_merge(merged[key], value)
        else:
            merged[key] = value
    return merged


def load_config() -> Dict[str, Any]:
    default_cfg = _read_json(DEFAULT_CONFIG_PATH, {})
    if not isinstance(default_cfg, dict):
        default_cfg = {}

    user_cfg = _read_json(USER_CONFIG_PATH, {})
    if not isinstance(user_cfg, dict):
        user_cfg = {}

    return _deep_merge(default_cfg, user_cfg)


def get_default_config() -> Dict[str, Any]:
    """仅读取默认配置（config/default.json）"""
    default_cfg = _read_json(DEFAULT_CONFIG_PATH, {})
    return default_cfg if isinstance(default_cfg, dict) else {}


def get_user_config() -> Dict[str, Any]:
    """仅读取用户自定义配置（config/config.json，仅存与默认值不同的覆盖项）"""
    user_cfg = _read_json(USER_CONFIG_PATH, {})
    return user_cfg if isinstance(user_cfg, dict) else {}


def calculate_config_diff(user_cfg: Dict[str, Any], default_cfg: Dict[str, Any]) -> Dict[str, Any]:
    """计算用户配置与默认配置之间的差异（仅叶子参数节点）"""
    diff = {}

    def extract_values(cfg: Dict[str, Any], path: str = "") -> Dict[str, Any]:
        """递归提取所有叶子参数节点（形如 {key: {"value": ...}}）的标量值"""
        values = {}
        for key, val in cfg.items():
            current_path = f"{path}.{key}" if path else key
            if isinstance(val, dict):
                if "value" in val:  # 这是配置参数节点
                    values[current_path] = val.get("value")
                else:  # 这是分组，继续递归
                    values.update(extract_values(val, current_path))
        return values

    default_values = extract_values(default_cfg)
    user_values = extract_values(user_cfg)

    # 只统计用户实际自定义（写入了 config.json）且与默认值不同的键
    for key, user_val in user_values.items():
        default_val = default_values.get(key)
        if user_val != default_val:
            diff[key] = {"user_value": user_val, "default_value": default_val}

    return diff


def save_user_config(config: Dict[str, Any]) -> None:
    _write_json(USER_CONFIG_PATH, config)


def _flatten_config_diff(cfg: Dict[str, Any], defaults: Dict[str, Any], path: str = "") -> Dict[str, Any]:
    """将配置展平，仅保留与默认值不同的叶子节点。

    ``defaults`` 是当前层级的对应默认节点，导航按层级相对进行（每层递归一次）。
    返回扁平字典，如 {"general.suspend_enabled": {"value": false}}。
    """
    result = {}
    for key, value in cfg.items():
        current_path = f"{path}.{key}" if path else key
        default_node = defaults.get(key) if isinstance(defaults, dict) else None

        if isinstance(value, dict):
            if "value" in value:
                # 配置参数节点：仅保留与默认值不同的 value
                default_value = default_node.get("value") if isinstance(default_node, dict) else None
                if value.get("value") != default_value:
                    result[current_path] = {"value": value.get("value")}
            else:
                # 分组：继续递归
                result.update(_flatten_config_diff(value, default_node or {}, current_path))
        else:
            # 直接值：仅当它覆盖了实际的参数叶子节点时才保留
            if isinstance(default_node, dict) and "value" in default_node:
                if value != default_node.get("value"):
                    result[current_path] = value

    return result


def _nest_flat_config(flat: Dict[str, Any]) -> Dict[str, Any]:
    """将扁平差异字典还原为嵌套配置结构"""
    nested: Dict[str, Any] = {}
    for flat_key, value in flat.items():
        parts = flat_key.split(".")
        current = nested
        for part in parts[:-1]:
            current.setdefault(part, {})
            current = current[part]
        current[parts[-1]] = value
    return nested


def _to_int(value: Any, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def read_state() -> Dict[str, Any]:
    state: Dict[str, Any] = {
        "STATE": "UNKNOWN",
        "STATE_TS": 0,
        "IDLE_DURATION": 0,
        "REQUEST_SUSPEND_TS": 0,
        "LAST_RESUME_TS": 0,
        "SUSPEND_FAIL_CNT": 0,
    }

    if not STATE_FILE.exists():
        return state

    for line in STATE_FILE.read_text(encoding="utf-8", errors="ignore").splitlines():
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if key == "STATE":
            state[key] = value
        elif key in {"STATE_TS", "IDLE_DURATION", "REQUEST_SUSPEND_TS", "LAST_RESUME_TS", "SUSPEND_FAIL_CNT"}:
            state[key] = _to_int(value, 0)

    return state


def status_payload() -> Dict[str, Any]:
    config = load_config()
    general = config.get("general", {}) if isinstance(config.get("general", {}), dict) else {}
    suspend_window = config.get("suspend_window", {}) if isinstance(config.get("suspend_window", {}), dict) else {}
    check_interval = config.get("check_interval", {}) if isinstance(config.get("check_interval", {}), dict) else {}

    state = read_state()
    machine = getattr(os, "uname", lambda: None)()

    idle_detection = config.get("idle_detection", {}) if isinstance(config.get("idle_detection", {}), dict) else {}

    return {
        "state": state.get("STATE", "UNKNOWN"),
        "state_ts": state.get("STATE_TS", 0),
        "idle_duration": state.get("IDLE_DURATION", 0),
        "request_suspend_ts": state.get("REQUEST_SUSPEND_TS", 0),
        "last_resume_ts": state.get("LAST_RESUME_TS", 0),
        "suspend_fail_cnt": state.get("SUSPEND_FAIL_CNT", 0),
        # 脚本是否被禁用标记文件（连续休眠失败自动创建）禁用
        "suspend_disabled_by_file": DISABLE_FILE.exists(),
        "disable_file": str(DISABLE_FILE),
        "suspend_enabled": bool(general.get("suspend_enabled", {}).get("value", True)),
        "idle_minutes_required": _to_int(idle_detection.get("idle_minutes_required", {}).get("value", 60), 60),
        "resume_cooldown_minutes": _to_int(idle_detection.get("resume_cooldown_minutes", {}).get("value", 300), 300),
        "check_interval_min": _to_int(check_interval.get("minutes", {}).get("value", 5), 5),
        "check_interval_sec": _to_int(check_interval.get("seconds", {}).get("value", 300), 300),
        "window": {
            "start": _to_int(suspend_window.get("hour_start", {}).get("value", 0), 0),
            "end": _to_int(suspend_window.get("hour_end", {}).get("value", 24), 24),
        },
        "system": {
            "hostname": machine.nodename if machine else "unknown",
            "platform": machine.sysname if machine else "linux",
            "config_file": str(USER_CONFIG_PATH),
            "default_file": str(DEFAULT_CONFIG_PATH),
            "state_file": str(STATE_FILE),
        },
        "updated_at": int(time.time()),
    }


def get_logs(lines: int = 100) -> List[Dict[str, Any]]:
    logs = []
    try:
        # 尝试从 journalctl 读取日志
        cmd = ["journalctl", "-t", "auto-suspend", "-n", str(lines), "--output=json"]
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=5)

        if result.returncode == 0 and result.stdout:
            for line in result.stdout.strip().split('\n'):
                if line:
                    try:
                        entry = json.loads(line)
                        logs.append({
                            "timestamp": entry.get("__REALTIME_TIMESTAMP", ""),
                            "message": entry.get("MESSAGE", ""),
                            "priority": entry.get("PRIORITY", ""),
                        })
                    except (json.JSONDecodeError, KeyError):
                        pass
    except Exception:
        # journalctl 不可用或无权限时，返回空日志占位
        logs.append({
            "timestamp": str(int(time.time() * 1000000)),
            "message": "日志暂不可用 (journalctl 未找到或无权限)",
            "priority": "6",  # INFO 级别
        })

    return sorted(logs, key=lambda x: x.get("timestamp", ""), reverse=True)


# =========================================================
# 图表数据读取（STATE_DIR 下的 hdd.*.prev / ssd.*.prev / net.prev
# 以及 hdd.*.samples / ssd.samples / net.samples）
# 单位约定：磁盘扇区一律换算为字节（512B/扇区），网络本身为字节
# =========================================================
SECTOR_SIZE = 512


def _read_first_int(path: Path, default: int = 0) -> int:
    """读取单值文本文件中的第一个整数（.prev 文件格式）"""
    if not path.exists():
        return default
    try:
        with path.open("r", encoding="utf-8", errors="ignore") as handle:
            return _to_int(handle.read().strip().splitlines()[0], default)
    except Exception:
        return default


def _read_sample_lines(path: Path) -> List[Tuple[Optional[int], int, Optional[int]]]:
    """读取采样文件（.samples，每行 "时间戳 数值 [P90]"，兼容旧格式），
    按时间顺序返回 [(ts, value, p90)]；无 P90 列或为 "-" 时 p90 为 None。"""
    if not path.exists():
        return []
    samples: List[Tuple[Optional[int], int, Optional[int]]] = []
    try:
        with path.open("r", encoding="utf-8", errors="ignore") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                parts = line.split()
                # 新格式："时间戳 数值" / "时间戳 数值 P90"
                if len(parts) >= 2 and parts[0].isdigit() and parts[1].isdigit():
                    ts = int(parts[0])
                    value = int(parts[1])
                    p90 = int(parts[2]) if len(parts) >= 3 and parts[2].isdigit() else None
                    samples.append((ts, value, p90))
                # 旧格式：纯数值（无时间戳，ts 置 None）
                elif parts[0].isdigit():
                    samples.append((None, int(parts[0]), None))
    except Exception:
        return []
    return samples


def _dev_name_from_file(file: Path, prefix: str, suffix: str) -> str:
    """从文件名提取设备名，如 hdd.sda.prev -> sda"""
    name = file.name
    if name.startswith(prefix):
        name = name[len(prefix):]
    if name.endswith(suffix):
        name = name[: -len(suffix)]
    return name


def read_charts_data() -> Dict[str, Any]:
    """汇总 STATE_DIR 中的磁盘/网络当前累计值及历史采样序列（统一转为字节）"""
    config = load_config()
    learning_params = config.get("learning_parameters", {}) if isinstance(config.get("learning_parameters", {}), dict) else {}
    check_interval = config.get("check_interval", {}) if isinstance(config.get("check_interval", {}), dict) else {}
    payload: Dict[str, Any] = {
        "hdd": [],            # [{name, current_bytes, samples_bytes: [...]}]
        "ssd": [],            # [{name, current_bytes}]
        "ssd_samples_bytes": [],
        "net": {"current_bytes": 0},
        "net_samples_bytes": [],
        "interval_sec": _to_int(check_interval.get("seconds", {}).get("value", 300), 300),  # 每点采样间隔（与 config 同步）
        "learn_window": _to_int(learning_params.get("learn_window", {}).get("value", 60), 60),  # 采样窗口点数（与 config 同步）
        "request_suspend_ts": 0,   # 上次进入休眠的时间点（与 last_resume_ts 构成休眠区间，供前端竖线标记）
        "last_resume_ts": 0,       # 上次唤醒的时间点
        "updated_at": int(time.time()),
    }

    # 休眠区间：读取状态文件中的“上次休眠/唤醒”时间点
    state = read_state()
    payload["request_suspend_ts"] = state.get("REQUEST_SUSPEND_TS", 0)
    payload["last_resume_ts"] = state.get("LAST_RESUME_TS", 0)

    if not STATE_DIR.is_dir():
        return payload

    # HDD：每块盘独立的 .prev 与 .samples（每行 "时间戳 数值 P90"）
    for prev_file in sorted(STATE_DIR.glob("hdd.*.prev")):
        name = _dev_name_from_file(prev_file, "hdd.", ".prev")
        sectors = _read_first_int(prev_file)
        samples = _read_sample_lines(STATE_DIR / f"hdd.{name}.samples")
        payload["hdd"].append({
            "name": name,
            "current_bytes": sectors * SECTOR_SIZE,
            "samples_bytes": [s[1] * SECTOR_SIZE for s in samples],
            "samples_ts": [s[0] for s in samples],
            "samples_p90": [s[2] * SECTOR_SIZE if s[2] is not None else None for s in samples],
        })

    # SSD：每块盘独立的 .prev，总采样 ssd.samples
    for prev_file in sorted(STATE_DIR.glob("ssd.*.prev")):
        name = _dev_name_from_file(prev_file, "ssd.", ".prev")
        sectors = _read_first_int(prev_file)
        payload["ssd"].append({"name": name, "current_bytes": sectors * SECTOR_SIZE})
    ssd_samples = _read_sample_lines(STATE_DIR / "ssd.samples")
    payload["ssd_samples_bytes"] = [s[1] * SECTOR_SIZE for s in ssd_samples]
    payload["ssd_samples_ts"] = [s[0] for s in ssd_samples]
    payload["ssd_samples_p90"] = [s[2] * SECTOR_SIZE if s[2] is not None else None for s in ssd_samples]

    # 网络：net.prev + net.samples（本身为字节）
    payload["net"]["current_bytes"] = _read_first_int(STATE_DIR / "net.prev")
    net_samples = _read_sample_lines(STATE_DIR / "net.samples")
    payload["net_samples_bytes"] = [s[1] for s in net_samples]
    payload["net_samples_ts"] = [s[0] for s in net_samples]
    payload["net_samples_p90"] = [s[2] if s[2] is not None else None for s in net_samples]

    return payload


@app.route("/api/charts")
def api_charts():
    return jsonify(read_charts_data())


@app.route("/")
def index():
    # 每次直接读取 HTML 文件，便于模板热更新
    html_path = BASE_DIR / "templates" / "index.html"
    try:
        with open(html_path, "r", encoding="utf-8") as f:
            return f.read()
    except Exception as e:
        return f"<html><body>Error loading page: {e}</body></html>", 500


@app.route("/api/config", methods=["GET", "POST"])
def api_config():
    if request.method == "GET":
        # 返回合并后的配置及差异元数据
        default_cfg = get_default_config()
        merged = load_config()
        return jsonify({
            "config": merged,
            "defaults": default_cfg,
            "diff": calculate_config_diff(get_user_config(), default_cfg)
        })

    # POST：仅保存与默认值不同的项
    payload = request.get_json(silent=True)
    if payload is None:
        return jsonify({"ok": False, "error": "Request body must be JSON"}), 400

    if not isinstance(payload, dict):
        return jsonify({"ok": False, "error": "Request body must be a JSON object."}), 400

    default_cfg = get_default_config()

    # 只保留与默认值实际不同的叶子节点（config.json 仅存用户覆盖项）
    diff_flat = _flatten_config_diff(payload, default_cfg)
    filtered_config = _nest_flat_config(diff_flat)
    save_user_config(filtered_config)

    # 返回合并后的配置
    merged = load_config()
    return jsonify({
        "ok": True,
        "config": merged,
        "defaults": default_cfg,
        "saved_diff": filtered_config,
        "diff": calculate_config_diff(filtered_config, default_cfg)
    })


@app.route("/api/config/diff")
def api_config_diff():
    """获取配置与默认值的差异"""
    default_cfg = get_default_config()
    user_cfg = get_user_config()
    diff = calculate_config_diff(user_cfg, default_cfg)

    return jsonify({
        "ok": True,
        "diff": diff,
        "changed_count": len(diff),
        "user_config": user_cfg,
        "default_config": default_cfg
    })


@app.route("/api/status")
def api_status():
    return jsonify(status_payload())


@app.route("/api/clear-disable", methods=["POST"])
def api_clear_disable():
    """手动移除 DISABLE_FILE，解除因连续休眠失败导致的脚本禁用"""
    removed = False
    if DISABLE_FILE.exists():
        try:
            DISABLE_FILE.unlink()
            removed = True
        except OSError as exc:
            return jsonify({"ok": False, "error": f"移除禁用文件失败: {exc}"}), 500
    return jsonify({
        "ok": True,
        "removed": removed,
        "suspend_disabled_by_file": DISABLE_FILE.exists(),
        "disable_file": str(DISABLE_FILE),
    })


@app.route("/api/toggle-suspend", methods=["POST"])
def api_toggle_suspend():
    default_cfg = get_default_config()
    user_cfg = get_user_config()
    merged = _deep_merge(default_cfg, user_cfg)

    general = merged.setdefault("general", {})
    suspend_cfg = general.setdefault("suspend_enabled", {})
    suspend_cfg["value"] = not bool(suspend_cfg.get("value", True))

    # 仅保存差异（保留用户已有的其他自定义项）
    diff = _nest_flat_config(_flatten_config_diff(merged, default_cfg))
    save_user_config(diff)

    return jsonify({
        "ok": True,
        "config": _deep_merge(default_cfg, diff),
        "defaults": default_cfg,
    })


@app.route("/api/reset-config", methods=["POST"])
def api_reset_config():
    default_cfg = get_default_config()
    # config.json 默认为空，恢复默认即清空所有用户自定义项
    save_user_config({})
    return jsonify({"ok": True, "config": default_cfg, "defaults": default_cfg})


@app.route("/api/logs")
def api_logs():
    lines = request.args.get("lines", 100, type=int)
    lines = max(10, min(500, lines))  # 限制在 10 ~ 500 之间
    logs = get_logs(lines)
    return jsonify({"ok": True, "logs": logs, "count": len(logs)})


if __name__ == "__main__":
    # 监听地址/端口可由环境变量覆盖；默认监听所有网卡（0.0.0.0），便于通过局域网 IP 访问
    web_host = os.environ.get("WEB_HOST", "0.0.0.0")
    web_port = int(os.environ.get("WEB_PORT", "5005"))
    app.run(host=web_host, port=web_port, debug=False)
