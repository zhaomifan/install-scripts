#!/bin/bash
# ============================================================
# RocketMQ 集群卸载脚本（对应部署脚本，单节点执行）
# 功能：停止服务、删除 systemd 单元、清理安装目录及数据
# 用法：sudo ./uninstall_rocketmq.sh [--delete-data] [--delete-user]
# ============================================================

set -euo pipefail

# ============================================================
# 配置区（与部署脚本保持一致）
# ============================================================

# 三台物理节点 IP
IP_1="192.168.15.80"
IP_2="192.168.15.84"
IP_3="192.168.15.98"

# 安装路径
INSTALL_DIR="/ncpsmw/rocketmq_cluster"
DATA_DIR="/ncpsdata/rocketmq_cluster"
RUN_USER="rocketmq"

# 当前节点 IP（自动检测）
SERVER_IP=$(hostname -I | awk '{print $1}')

# 判断当前节点
if [ "$SERVER_IP" == "$IP_1" ]; then
  CURRENT_NODE="node1"
elif [ "$SERVER_IP" == "$IP_2" ]; then
  CURRENT_NODE="node2"
elif [ "$SERVER_IP" == "$IP_3" ]; then
  CURRENT_NODE="node3"
else
  echo "警告：本机 IP $SERVER_IP 不在配置列表中，将清理所有可能存在的 RocketMQ 服务"
  CURRENT_NODE="unknown"
fi

# ============================================================
# 工具函数
# ============================================================

log_info()  { echo -e "\033[32m[INFO]\033[0m  $*"; }
log_warn()  { echo -e "\033[33m[WARN]\033[0m  $*"; }
log_error() { echo -e "\033[31m[ERROR]\033[0m $*"; }

confirm() {
    read -r -p "$1 [y/N] " response
    case "$response" in
        [yY][eE][sS]|[yY]) 
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# ============================================================
# 卸载功能
# ============================================================

stop_and_disable_services() {
    log_info "停止并禁用所有 RocketMQ 相关服务..."

    # 获取所有 rocketmq 服务（精确匹配）
    local services=$(systemctl list-unit-files --no-legend --type=service | grep -E '^rocketmq-' | awk '{print $1}' || true)
    if [ -z "$services" ]; then
        log_warn "未找到任何 rocketmq-*.service 文件"
    else
        for svc in $services; do
            log_info "处理服务: $svc"
            systemctl stop "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
        done
    fi
}

remove_service_files() {
    log_info "删除 systemd 服务文件..."
    local files=$(ls /etc/systemd/system/rocketmq-*.service 2>/dev/null || true)
    if [ -n "$files" ]; then
        rm -f $files
        log_info "已删除服务文件"
        systemctl daemon-reload
    else
        log_warn "没有找到 /etc/systemd/system/rocketmq-*.service 文件"
    fi
}

remove_installation() {
    log_info "删除安装目录: $INSTALL_DIR"
    if [ -d "$INSTALL_DIR" ]; then
        rm -rf "$INSTALL_DIR"
        log_info "安装目录已删除"
    else
        log_warn "安装目录不存在: $INSTALL_DIR"
    fi
}

remove_data() {
    log_info "删除数据目录: $DATA_DIR"
    if [ -d "$DATA_DIR" ]; then
        rm -rf "$DATA_DIR"
        log_info "数据目录已删除"
    else
        log_warn "数据目录不存在: $DATA_DIR"
    fi
}

remove_user() {
    log_info "删除运行用户: $RUN_USER"
    if id "$RUN_USER" >/dev/null 2>&1; then
        userdel -r "$RUN_USER" 2>/dev/null || log_warn "无法删除用户 $RUN_USER，可能仍有进程占用"
        log_info "用户 $RUN_USER 已删除"
    else
        log_warn "用户 $RUN_USER 不存在"
    fi
}

# ============================================================
# 主流程
# ============================================================

main() {
    echo "============================================================"
    echo "  RocketMQ 集群卸载脚本"
    echo "  当前节点: ${CURRENT_NODE:-unknown} (${SERVER_IP})"
    echo "============================================================"

    # 检查 root 权限
    if [ "$EUID" -ne 0 ]; then
        log_error "请使用 root 权限运行此脚本 (sudo)"
        exit 1
    fi

    # 解析参数
    DELETE_DATA=false
    DELETE_USER=false
    for arg in "$@"; do
        case $arg in
            --delete-data) DELETE_DATA=true ;;
            --delete-user) DELETE_USER=true ;;
            *) log_warn "未知参数: $arg";;
        esac
    done

    # 显示将要执行的操作
    echo ""
    log_info "即将执行以下操作："
    echo "  - 停止并禁用所有 rocketmq 服务"
    echo "  - 删除所有 rocketmq systemd 服务文件"
    echo "  - 删除安装目录: $INSTALL_DIR"
    if [ "$DELETE_DATA" = true ]; then
        echo "  - 删除数据目录: $DATA_DIR"
    else
        echo "  - 保留数据目录: $DATA_DIR (如需删除请添加 --delete-data)"
    fi
    if [ "$DELETE_USER" = true ]; then
        echo "  - 删除用户: $RUN_USER"
    else
        echo "  - 保留用户: $RUN_USER (如需删除请添加 --delete-user)"
    fi

    if ! confirm "确认继续卸载？"; then
        log_info "操作已取消"
        exit 0
    fi

    # 执行卸载
    stop_and_disable_services
    remove_service_files
    remove_installation
    if [ "$DELETE_DATA" = true ]; then
        remove_data
    fi
    if [ "$DELETE_USER" = true ]; then
        remove_user
    fi

    log_info "卸载完成。"
    echo "提示：防火墙端口如需关闭请手动操作（如 9876, 10911-10912, 10921-10922）"
}

main "$@"