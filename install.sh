#!/bin/bash
set -euo pipefail

# ==================== 常量定义 ====================
readonly PROJECT_DIR="/mine/Code/ai-tools/grok2api3"
readonly SERVICE_NAME="grok2api3"
readonly SERVICE_FILE="${SERVICE_NAME}.service"
readonly SERVICE_SOURCE="${PROJECT_DIR}/${SERVICE_FILE}"
readonly SERVICE_TARGET="/etc/systemd/system/${SERVICE_FILE}"
readonly UV_BIN="/root/.local/bin/uv"
readonly HOST="0.0.0.0"
readonly PORT="9006"
readonly WORKERS="1"
readonly JOURNAL_LINES="50"
readonly SERVICE_READY_TIMEOUT="30"
readonly RETRY_INTERVAL="1"
readonly HEALTHCHECK_PATH="/"

readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_BOLD='\033[1m'
readonly COLOR_RESET='\033[0m'

ROLLBACK_NEEDED=0
BACKUP_FILE=""
SERVICE_WAS_ACTIVE=0
ASSUME_YES=0
SKIP_PORT_CHECK=0
SKIP_HTTP_CHECK=0
CUSTOM_HEALTHCHECK_PATH="$HEALTHCHECK_PATH"

# ==================== 输出函数 ====================
info() {
  printf "%b[INFO]%b %s\n" "$COLOR_BLUE" "$COLOR_RESET" "$1"
}

success() {
  printf "%b[SUCCESS]%b %s\n" "$COLOR_GREEN" "$COLOR_RESET" "$1"
}

warning() {
  printf "%b[WARNING]%b %s\n" "$COLOR_YELLOW" "$COLOR_RESET" "$1"
}

error() {
  printf "%b[ERROR]%b %s\n" "$COLOR_RED" "$COLOR_RESET" "$1" >&2
}

section() {
  printf "\n%b==>%b %s\n" "$COLOR_BOLD" "$COLOR_RESET" "$1"
}

usage() {
  cat <<'EOF'
用法:
  ./install.sh [--yes] [--skip-port-check] [--skip-http-check] [--health-path PATH]

选项:
  --yes, -y               跳过交互确认，直接执行安装
  --skip-port-check       跳过端口监听检查
  --skip-http-check       跳过 HTTP 健康检查
  --health-path PATH      指定 HTTP 健康检查路径，默认 /
  --help, -h              显示帮助信息
EOF
}

# ==================== 回滚与错误处理 ====================
rollback() {
  if [[ "$ROLLBACK_NEEDED" -ne 1 ]]; then
    return
  fi

  warning "开始执行回滚操作..."

  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  fi

  if [[ -n "$BACKUP_FILE" && -f "$BACKUP_FILE" ]]; then
    install -m 644 "$BACKUP_FILE" "$SERVICE_TARGET"
    rm -f "$BACKUP_FILE"
    if command -v systemctl >/dev/null 2>&1; then
      systemctl daemon-reload >/dev/null 2>&1 || true
      if [[ "$SERVICE_WAS_ACTIVE" -eq 1 ]]; then
        systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || true
      fi
    fi
    warning "已恢复原有 systemd 服务文件。"
    return
  fi

  if [[ -f "$SERVICE_TARGET" ]]; then
    rm -f "$SERVICE_TARGET"
    if command -v systemctl >/dev/null 2>&1; then
      systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    warning "已移除新安装的 systemd 服务文件。"
  fi
}

on_error() {
  local exit_code=$?
  local line_no=${1:-unknown}
  error "安装失败（行号: ${line_no}，退出码: ${exit_code}）。"
  rollback
  error "请根据上方日志修复问题后重新执行安装脚本。"
  exit "$exit_code"
}

trap 'on_error ${LINENO}' ERR

# ==================== 参数处理 ====================
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y)
        ASSUME_YES=1
        ;;
      --skip-port-check)
        SKIP_PORT_CHECK=1
        ;;
      --skip-http-check)
        SKIP_HTTP_CHECK=1
        ;;
      --health-path)
        shift
        if [[ $# -eq 0 ]]; then
          error "--health-path 需要提供路径参数，例如 /"
          exit 1
        fi
        CUSTOM_HEALTHCHECK_PATH="$1"
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        error "未知参数: $1"
        usage
        exit 1
        ;;
    esac
    shift
  done
}

# ==================== 基础检查 ====================
ensure_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    error "请使用 root 用户执行该脚本。"
    exit 1
  fi
}

ensure_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    error "缺少必要命令: ${cmd}"
    exit 1
  fi
}

check_project_files() {
  [[ -d "$PROJECT_DIR" ]] || { error "项目目录不存在: ${PROJECT_DIR}"; exit 1; }
  [[ -f "$SERVICE_SOURCE" ]] || { error "服务文件不存在: ${SERVICE_SOURCE}"; exit 1; }
  [[ -f "${PROJECT_DIR}/pyproject.toml" ]] || { error "缺少 pyproject.toml"; exit 1; }
  [[ -f "${PROJECT_DIR}/uv.lock" ]] || { error "缺少 uv.lock，无法执行 uv sync --frozen"; exit 1; }
}

check_uv() {
  if [[ ! -x "$UV_BIN" ]]; then
    error "未找到 uv 可执行文件: ${UV_BIN}"
    error "请先安装 uv，例如执行: curl -LsSf https://astral.sh/uv/install.sh | sh"
    exit 1
  fi

  info "uv 版本: $($UV_BIN --version)"
}

check_port_free() {
  local port_in_use=0

  if command -v ss >/dev/null 2>&1; then
    if ss -ltn | awk '{print $4}' | grep -Eq "(^|:)${PORT}$"; then
      port_in_use=1
    fi
  elif command -v netstat >/dev/null 2>&1; then
    if netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${PORT}$"; then
      port_in_use=1
    fi
  else
    warning "未找到 ss 或 netstat，跳过端口占用检查。"
    return
  fi

  if [[ "$port_in_use" -eq 1 ]]; then
    error "端口 ${PORT} 已被占用，请先释放后再安装。"
    exit 1
  fi
}

port_is_listening() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltn | awk '{print $4}' | grep -Eq "(^|:)${PORT}$"
    return
  fi

  if command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${PORT}$"
    return
  fi

  return 2
}

wait_for_service_active() {
  local elapsed=0
  while (( elapsed < SERVICE_READY_TIMEOUT )); do
    if systemctl is-active --quiet "$SERVICE_NAME"; then
      return 0
    fi
    sleep "$RETRY_INTERVAL"
    elapsed=$((elapsed + RETRY_INTERVAL))
  done

  error "服务在 ${SERVICE_READY_TIMEOUT} 秒内未进入 active 状态。"
  systemctl status "$SERVICE_NAME" --no-pager || true
  journalctl -u "$SERVICE_NAME" -n "$JOURNAL_LINES" --no-pager || true
  exit 1
}

wait_for_port_listening() {
  local elapsed=0
  while (( elapsed < SERVICE_READY_TIMEOUT )); do
    if port_is_listening; then
      return 0
    fi
    sleep "$RETRY_INTERVAL"
    elapsed=$((elapsed + RETRY_INTERVAL))
  done

  error "在 ${SERVICE_READY_TIMEOUT} 秒内未检测到 ${PORT} 端口监听。"
  systemctl status "$SERVICE_NAME" --no-pager || true
  journalctl -u "$SERVICE_NAME" -n "$JOURNAL_LINES" --no-pager || true
  exit 1
}

wait_for_http_ready() {
  if [[ "$SKIP_HTTP_CHECK" -eq 1 ]]; then
    warning "已按参数要求跳过 HTTP 接口检查。"
    return
  fi

  if ! command -v curl >/dev/null 2>&1; then
    warning "未找到 curl，跳过 HTTP 接口检查。"
    return
  fi

  local elapsed=0
  while (( elapsed < SERVICE_READY_TIMEOUT )); do
    if curl --fail --silent --max-time 10 "http://127.0.0.1:${PORT}${CUSTOM_HEALTHCHECK_PATH}" >/dev/null; then
      success "HTTP 接口连通性检查通过。"
      return
    fi
    sleep "$RETRY_INTERVAL"
    elapsed=$((elapsed + RETRY_INTERVAL))
  done

  warning "HTTP 接口在 ${SERVICE_READY_TIMEOUT} 秒内未返回成功状态，请检查路径 ${CUSTOM_HEALTHCHECK_PATH} 是否可用。"
}

show_summary() {
  section "安装配置摘要"
  printf "  服务名称   : %s\n" "$SERVICE_NAME"
  printf "  项目目录   : %s\n" "$PROJECT_DIR"
  printf "  服务文件   : %s\n" "$SERVICE_TARGET"
  printf "  监听地址   : %s\n" "$HOST"
  printf "  监听端口   : %s\n" "$PORT"
  printf "  Worker 数  : %s\n" "$WORKERS"
  printf "  uv 路径    : %s\n" "$UV_BIN"
  printf "  健康检查   : %s\n" "$CUSTOM_HEALTHCHECK_PATH"
  printf "  跳过端口检查: %s\n" "$SKIP_PORT_CHECK"
  printf "  跳过 HTTP 检查: %s\n" "$SKIP_HTTP_CHECK"
}

confirm_install() {
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    info "已启用 --yes，跳过交互确认。"
    return
  fi

  printf "\n%b确认安装%b：这将安装依赖并配置 systemd 服务 %s。\n" "$COLOR_BOLD" "$COLOR_RESET" "$SERVICE_NAME"
  read -r -p "是否继续？[y/N]: " reply
  case "$reply" in
    y|Y|yes|YES)
      ;;
    *)
      warning "用户取消安装。"
      exit 0
      ;;
  esac
}

# ==================== 安装流程 ====================
install_dependencies() {
  section "安装项目依赖"
  info "执行 uv sync --frozen"
  "$UV_BIN" sync --frozen --directory "$PROJECT_DIR"

  if ! "$UV_BIN" run --directory "$PROJECT_DIR" granian --version >/dev/null 2>&1; then
    error "当前环境中未检测到 granian。"
    error "请确认 pyproject.toml / uv.lock 已包含 granian 依赖后重试。"
    exit 1
  fi

  success "依赖安装完成。"
}

backup_existing_service() {
  if [[ -f "$SERVICE_TARGET" ]]; then
    BACKUP_FILE="$(mktemp "/tmp/${SERVICE_FILE}.backup.XXXXXX")"
    cp "$SERVICE_TARGET" "$BACKUP_FILE"
    if systemctl is-active --quiet "$SERVICE_NAME"; then
      SERVICE_WAS_ACTIVE=1
    fi
    info "检测到现有服务文件，已创建备份: ${BACKUP_FILE}"
  fi
}

configure_service() {
  section "配置 systemd 服务"
  backup_existing_service
  ROLLBACK_NEEDED=1

  install -m 644 "$SERVICE_SOURCE" "$SERVICE_TARGET"
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
  systemctl restart "$SERVICE_NAME"

  success "systemd 服务已安装并启动。"
}

verify_service() {
  section "验证服务状态"
  systemctl is-enabled "$SERVICE_NAME" >/dev/null

  info "等待服务进入 active 状态..."
  wait_for_service_active
  success "systemd 服务状态正常。"

  if [[ "$SKIP_PORT_CHECK" -eq 1 ]]; then
    warning "已按参数要求跳过端口监听检查。"
  elif command -v ss >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1; then
    info "等待 ${PORT} 端口开始监听..."
    wait_for_port_listening
    success "端口 ${PORT} 已开始监听。"
  else
    warning "未找到 ss 或 netstat，跳过端口监听检查。"
  fi

  info "等待 HTTP 接口就绪..."
  wait_for_http_ready

  success "服务验证通过。"
}

show_next_steps() {
  section "安装完成"
  printf "服务状态查看:\n"
  printf "  systemctl status %s\n" "$SERVICE_NAME"
  printf "\n服务管理命令:\n"
  printf "  systemctl start %s\n" "$SERVICE_NAME"
  printf "  systemctl stop %s\n" "$SERVICE_NAME"
  printf "  systemctl restart %s\n" "$SERVICE_NAME"
  printf "  systemctl enable %s\n" "$SERVICE_NAME"
  printf "  systemctl disable %s\n" "$SERVICE_NAME"
  printf "\n日志查看命令:\n"
  printf "  journalctl -u %s -n %s -f\n" "$SERVICE_NAME" "$JOURNAL_LINES"
  printf "\n端口检查命令:\n"
  printf "  ss -tlnp | grep %s\n" "$PORT"
  printf "\n可选安装示例:\n"
  printf "  ./%s --yes --health-path /\n" "install.sh"
  printf "  ./%s --yes --skip-http-check\n" "install.sh"
  printf "  ./%s --yes --skip-port-check\n" "install.sh"
}

cleanup_success() {
  ROLLBACK_NEEDED=0
  if [[ -n "$BACKUP_FILE" && -f "$BACKUP_FILE" ]]; then
    rm -f "$BACKUP_FILE"
  fi
}

main() {
  parse_args "$@"
  ensure_root
  ensure_command systemctl
  ensure_command install
  ensure_command awk
  ensure_command grep
  check_project_files
  check_uv
  check_port_free
  show_summary
  confirm_install
  install_dependencies
  configure_service
  verify_service
  cleanup_success
  show_next_steps
}

main "$@"
