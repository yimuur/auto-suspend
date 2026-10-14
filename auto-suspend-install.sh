#!/bin/bash

set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

NAME="auto-suspend"        # 脚本名称
HOOK="hdd-resume-post"     # 休眠钩子脚本名称
WEB_NAME="${NAME}-web"     # Web UI 服务名称
RUN_PATH="/run/$NAME"      # 运行时状态文件路径

MAIN_SCRIPT="/usr/local/sbin/${NAME}.sh"    # 主脚本安装路径
WEB_DIR="/usr/local/share/${NAME}/web"      # Web UI 安装目录
WEB_HOST="0.0.0.0"                          # Web UI 监听地址（0.0.0.0=所有网卡，可通过局域网访问）
WEB_PORT="5005"                             # Web UI 监听端口
TIMER_ONBOOT="10min"                        # 开机后首次检查延时
TIMER_INTERVAL="5min"                       # 定时检查周期（与配置中“监测周期”保持一致）

# 直接拷贝的文件合集："源文件(相对安装包目录):目标路径"
INSTALL_FILES=(
    "${NAME}.sh:${MAIN_SCRIPT}"
    "${HOOK}.sh:/lib/systemd/system-sleep/${HOOK}.sh"
    "app.py:${WEB_DIR}/app.py"
    "templates/index.html:${WEB_DIR}/templates/index.html"
    "static/app.js:${WEB_DIR}/static/app.js"
    "static/style.css:${WEB_DIR}/static/style.css"
    "static/favicon.svg:${WEB_DIR}/static/favicon.svg"
    "config/default.json:${WEB_DIR}/config/default.json"
    "config/config.json:${WEB_DIR}/config/config.json"
)

# systemd 单元模板："源模板(相对安装包目录):目标路径"（安装时替换占位符生成）
UNIT_TEMPLATES=(
    "${NAME}.service:/etc/systemd/system/${NAME}.service"
    "${NAME}.timer:/etc/systemd/system/${NAME}.timer"
    "${WEB_NAME}.service:/etc/systemd/system/${WEB_NAME}.service"
)

# 需要添加执行权限的目标文件
EXEC_FILES=(
    "${MAIN_SCRIPT}"
    "/lib/systemd/system-sleep/${HOOK}.sh"
    "${WEB_DIR}/app.py"
)

# 无论从哪里运行，SCRIPT_DIR 永远指向安装包所在的文件夹
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# 检查是否以 root 运行
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误：请使用 sudo 运行此脚本${NC}"
    exit 1
fi

# 检查必要文件是否存在
check_files() {
    local missing_files=()
    local entry src

    for entry in "${INSTALL_FILES[@]}" "${UNIT_TEMPLATES[@]}"; do
        src="${entry%%:*}"
        if [ ! -f "${SCRIPT_DIR}/${src}" ]; then
            missing_files+=("$src")
        fi
    done

    if [ ${#missing_files[@]} -gt 0 ]; then
        echo -e "${RED}错误：找不到以下文件：${NC}"
        printf '%s\n' "${missing_files[@]}"
        echo -e "${YELLOW}请确保源文件和安装脚本在同一目录下${NC}"
        return 1
    fi
    return 0
}

# 渲染 systemd 单元模板（替换占位符后写入目标路径）
render_template() {
    local src="$1"
    local dst="$2"
    sed -e "s|__PYTHON__|${PYTHON_BIN}|g" \
        -e "s|__WEB_DIR__|${WEB_DIR}|g" \
        -e "s|__WEB_HOST__|${WEB_HOST}|g" \
        -e "s|__WEB_PORT__|${WEB_PORT}|g" \
        -e "s|__SCRIPT__|${MAIN_SCRIPT}|g" \
        -e "s|__ONBOOT__|${TIMER_ONBOOT}|g" \
        -e "s|__INTERVAL__|${TIMER_INTERVAL}|g" \
        "$src" > "$dst"
}

# 检测 python3 与 Flask
check_python() {
    if command -v python3 >/dev/null 2>&1; then
        PYTHON_BIN=$(command -v python3)
    else
        echo -e "${RED}错误：未找到 python3，Web UI 将无法运行${NC}"
        echo -e "${YELLOW}请先安装：sudo apt-get install python3 python3-pip 然后 sudo pip3 install flask${NC}"
        return 1
    fi

    if ! "$PYTHON_BIN" -c "import flask" >/dev/null 2>&1; then
        echo -e "${YELLOW}警告：未检测到 Flask 库，Web UI 将无法启动${NC}"
        echo -e "${YELLOW}请执行：sudo pip3 install flask${NC}"
    fi
    return 0
}

# 获取用于局域网访问提示的本机 IPv4 地址
get_lan_addr() {
    local addr

    if command -v ip >/dev/null 2>&1; then
        addr=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}')
        if [ -n "$addr" ]; then
            printf '%s' "$addr"
            return 0
        fi
    fi

    if command -v hostname >/dev/null 2>&1; then
        hostname -I 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i !~ /^127\./) {print $i; exit}}'
    fi
}

case "${1:-}" in
    install)
        if systemctl is-active --quiet "$NAME.timer"; then
            echo -e "${YELLOW}检测到 [${NAME}] 服务已在运行，将进行覆盖升级...${NC}"
            echo "停止服务..."
            systemctl stop "$NAME.timer" 2>/dev/null || true
            systemctl stop "$WEB_NAME.service" 2>/dev/null || true
        fi

        echo -e "${GREEN}开始安装...${NC}"

        # 检查文件是否存在
        if ! check_files; then
            exit 1
        fi

        # 检查 python 环境（Web UI 依赖）
        if ! check_python; then
            exit 1
        fi

        # 检查 jq（主脚本解析 JSON 配置必需；缺失时主脚本会回退内置默认值，Web 改配置不生效）
        if ! command -v jq >/dev/null 2>&1; then
            echo -e "${YELLOW}警告：未检测到 jq，主脚本将无法读取 config.json，从 Web 修改的配置不会生效${NC}"
            echo -e "${YELLOW}请安装：sudo apt-get install jq${NC}"
        fi

        # 拷贝文件
        for entry in "${INSTALL_FILES[@]}"; do
            src="${entry%%:*}"
            dst="${entry#*:}"
            # 升级时保留用户已有配置
            if [ "$src" = "config/config.json" ] && [ -f "$dst" ]; then
                echo "保留已有用户配置: ${dst}"
                continue
            fi
            mkdir -p "$(dirname "$dst")"
            if ! cp "${SCRIPT_DIR}/${src}" "$dst"; then
                echo -e "${RED}错误：拷贝 [${src}] 失败${NC}"
                exit 1
            else
                echo "已拷贝: ${dst}"
            fi
        done

        # 生成 systemd 单元（替换占位符）
        echo "生成 systemd 单元..."
        for unit in "${UNIT_TEMPLATES[@]}"; do
            usrc="${unit%%:*}"
            udst="${unit#*:}"
            render_template "${SCRIPT_DIR}/${usrc}" "$udst"
            echo "已生成: ${udst}"
        done

        # 设置权限
        echo "设置权限..."
        for path in "${EXEC_FILES[@]}"; do
            chmod 755 "$path"
            echo "已添加执行权限: ${path}"
        done

        # 重新加载 systemd 配置
        echo "重新加载 systemd 配置..."
        if ! systemctl daemon-reload; then
            echo -e "${YELLOW}警告：daemon-reload 出现问题${NC}"
        fi

        # 启用并启动定时器
        echo "启用并使能定时器..."
        if ! systemctl enable --now "$NAME.timer"; then
            echo -e "${RED}错误：启用 ${NAME}.timer 失败${NC}"
            exit 1
        fi

        # 启用并启动 Web UI 服务（开机自启）
        echo "启用并使能 Web UI 服务..."
        if ! systemctl enable --now "$WEB_NAME.service"; then
            echo -e "${RED}错误：启用 ${WEB_NAME}.service 失败${NC}"
            exit 1
        fi

        # 检查服务状态
        echo -e "${GREEN}检查服务状态...${NC}"
        systemctl status "$NAME.timer" --no-pager
        systemctl status "$WEB_NAME.service" --no-pager

        echo -e "${GREEN}安装完成！${NC}"
        echo -e "${GREEN}Web UI 访问地址：${NC}"
        WEB_LAN_ADDR=$(get_lan_addr)
        if [ -n "$WEB_LAN_ADDR" ]; then
            echo -e "  局域网：http://${WEB_LAN_ADDR}:${WEB_PORT}"
        else
            echo -e "${YELLOW}  未检测到可用的局域网 IPv4 地址${NC}"
        fi
        echo -e "  本机：  http://127.0.0.1:${WEB_PORT}"
        # echo -e "${YELLOW}（若防火墙拦截，请放行 TCP ${WEB_PORT}）${NC}"
        ;;

    uninstall)
        echo -e "${YELLOW}开始卸载...${NC}"

        # 停止并禁用服务
        echo "停止服务..."
        systemctl stop "$NAME.timer" 2>/dev/null || true
        systemctl disable "$NAME.timer" 2>/dev/null || true
        systemctl stop "$WEB_NAME.service" 2>/dev/null || true
        systemctl disable "$WEB_NAME.service" 2>/dev/null || true

        # 删除文件（含生成的 systemd 单元）
        echo "删除文件..."
        for entry in "${INSTALL_FILES[@]}" "${UNIT_TEMPLATES[@]}"; do
            dst="${entry#*:}"
            if [ -f "$dst" ]; then
                rm -f "$dst"
                echo "已删除: ${dst}"
            else
                echo -e "${YELLOW}跳过：${dst}（文件不存在）${NC}"
            fi
        done

        # 删除 Web UI 安装目录
        if [ -d "$WEB_DIR" ]; then
            rm -rf "$WEB_DIR"
            echo "已删除: ${WEB_DIR}"
        fi

        # 清理运行时目录
        echo "清理运行时目录：${RUN_PATH}"
        rm -rf "$RUN_PATH" 2>/dev/null || true

        # 重新加载 systemd 配置
        echo "重新加载 systemd 配置..."
        systemctl daemon-reload 2>/dev/null || true

        echo -e "${GREEN}卸载完成${NC}"
        ;;

    status)
        echo -e "${GREEN}检查服务状态...${NC}"
        systemctl status "$NAME.timer" --no-pager 2>/dev/null || \
            echo -e "${YELLOW} [${NAME}] 服务未运行${NC}"
        systemctl status "$WEB_NAME.service" --no-pager 2>/dev/null || \
            echo -e "${YELLOW} [${WEB_NAME}] 服务未运行${NC}"

        echo -e "\n${GREEN}检查文件完整性：${NC}"
        for entry in "${INSTALL_FILES[@]}" "${UNIT_TEMPLATES[@]}"; do
            dst="${entry#*:}"
            if [ -f "$dst" ]; then
                echo -e "${GREEN}✓ ${dst}${NC}"
            else
                echo -e "${RED}✗ ${dst}${NC}"
            fi
        done
        ;;

    *)
        echo "使用方法: $0 {install|uninstall|status}"
        echo "  install    - 安装服务（含 Web UI 与开机自启）"
        echo "  uninstall  - 卸载服务"
        echo "  status     - 查看状态"
        exit 1
        ;;
esac