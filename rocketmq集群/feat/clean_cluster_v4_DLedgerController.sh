#!/bin/bash
# ==================================================
# RocketMQ 5.4.0 DLedger Controller 集群移除脚本
# 功能：停止服务、移除安装目录、清理数据、删除用户等
# ==================================================

# -------------- 配置区 --------------
# 务必与部署脚本保持一致
INSTALL_DIR="/ncpsmw/rocketmq_cluster"
DATA_DIR="/ncpsdata/rocketmq_cluster"
RUN_USER="rocketmq"

# 是否保留数据目录（默认不保留）
KEEP_DATA=false

# 是否删除用户（默认保留）
REMOVE_USER=false

# ==================================================
# 参数解析
# ==================================================
show_help() {
    echo "用法: $0 [选项]"
    echo "选项:"
    echo "  --keep-data       保留数据目录（默认删除）"
    echo "  --remove-user     删除 rocketmq 用户（默认保留）"
    echo "  --force           强制删除，不提示确认"
    echo "  --help            显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  $0                  # 完全清理，保留用户"
    echo "  $0 --keep-data      # 清理安装但保留数据"
    echo "  $0 --remove-user    # 清理并删除用户"
    echo "  $0 --force          # 强制删除，不提示"
}

FORCE=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --keep-data)
            KEEP_DATA=true
            shift
            ;;
        --remove-user)
            REMOVE_USER=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            echo "未知选项: $1"
            show_help
            exit 1
            ;;
    esac
done

# ==================================================
# 确认删除
# ==================================================
echo "=================================================="
echo "⚠️  RocketMQ DLedger 集群移除脚本"
echo "=================================================="
echo "将执行以下操作："
echo "  1. 停止 rocketmq-namesrv 服务"
echo "  2. 停止 rocketmq-broker 服务"
echo "  3. 禁用 systemd 服务"
echo "  4. 删除安装目录: ${INSTALL_DIR}"
if [ "$KEEP_DATA" = true ]; then
    echo "  5. 保留数据目录: ${DATA_DIR}（--keep-data 已启用）"
else
    echo "  5. 删除数据目录: ${DATA_DIR}"
fi
echo "  6. 删除 systemd 服务文件"
if [ "$REMOVE_USER" = true ]; then
    echo "  7. 删除用户: ${RUN_USER}（--remove-user 已启用）"
else
    echo "  7. 保留用户: ${RUN_USER}"
fi
echo "=================================================="

if [ "$FORCE" != true ]; then
    read -p "确认继续操作？(y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "操作已取消。"
        exit 0
    fi
fi

# ==================================================
# 1. 停止并禁用服务
# ==================================================
echo ""
echo "=== 1. 停止并禁用服务 ==="

stop_service() {
    local svc=$1
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        echo "停止 $svc..."
        systemctl stop "$svc"
    fi
    if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        echo "禁用 $svc..."
        systemctl disable "$svc"
    fi
}

stop_service rocketmq-namesrv
stop_service rocketmq-broker

# 等待服务完全停止
sleep 2

# 强制杀死残留进程（如果有）
echo "检查残留进程..."
pkill -f "mqnamesrv" 2>/dev/null && echo "已清理残留 NameServer 进程"
pkill -f "mqbroker" 2>/dev/null && echo "已清理残留 Broker 进程"
sleep 1

# ==================================================
# 2. 删除 systemd 服务文件
# ==================================================
echo ""
echo "=== 2. 删除 systemd 服务文件 ==="
rm -f /etc/systemd/system/rocketmq-namesrv.service
rm -f /etc/systemd/system/rocketmq-broker.service
systemctl daemon-reload
systemctl reset-failed 2>/dev/null
echo "✅ systemd 服务文件已删除"

# ==================================================
# 3. 删除安装目录
# ==================================================
echo ""
echo "=== 3. 删除安装目录 ==="
if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
    echo "✅ 已删除: $INSTALL_DIR"
else
    echo "⚠️  安装目录不存在: $INSTALL_DIR"
fi

# ==================================================
# 4. 处理数据目录
# ==================================================
echo ""
echo "=== 4. 处理数据目录 ==="
if [ "$KEEP_DATA" = true ]; then
    echo "✅ 保留数据目录: $DATA_DIR（--keep-data 已启用）"
else
    if [ -d "$DATA_DIR" ]; then
        rm -rf "$DATA_DIR"
        echo "✅ 已删除: $DATA_DIR"
    else
        echo "⚠️  数据目录不存在: $DATA_DIR"
    fi
fi

# ==================================================
# 5. 删除用户（可选）
# ==================================================
echo ""
echo "=== 5. 处理用户 ==="
if [ "$REMOVE_USER" = true ]; then
    if id "$RUN_USER" >/dev/null 2>&1; then
        # 先杀掉该用户的所有进程
        pkill -u "$RUN_USER" 2>/dev/null
        sleep 1
        userdel -r "$RUN_USER" 2>/dev/null || userdel "$RUN_USER" 2>/dev/null
        echo "✅ 已删除用户: $RUN_USER"
    else
        echo "⚠️  用户不存在: $RUN_USER"
    fi
else
    echo "✅ 保留用户: $RUN_USER（如需删除，请使用 --remove-user）"
fi

# ==================================================
# 6. 防火墙端口清理（可选）
# ==================================================
echo ""
echo "=== 6. 防火墙端口处理 ==="
if systemctl is-active --quiet firewalld 2>/dev/null; then
    echo "检测到 firewalld 正在运行，是否移除已开放的端口？"
    if [ "$FORCE" = true ]; then
        REMOVE_FW=true
    else
        read -p "移除防火墙端口 9876, 10911, 40911？(y/n): " -n 1 -r
        echo
        [[ $REPLY =~ ^[Yy]$ ]] && REMOVE_FW=true || REMOVE_FW=false
    fi
    
    if [ "$REMOVE_FW" = true ]; then
        firewall-cmd --remove-port=9876/tcp --permanent 2>/dev/null
        firewall-cmd --remove-port=10911/tcp --permanent 2>/dev/null
        firewall-cmd --remove-port=40911/tcp --permanent 2>/dev/null
        firewall-cmd --reload 2>/dev/null
        echo "✅ 防火墙端口已移除"
    else
        echo "⚠️  如需手动移除端口，请执行："
        echo "  firewall-cmd --remove-port=9876/tcp --permanent"
        echo "  firewall-cmd --remove-port=10911/tcp --permanent"
        echo "  firewall-cmd --remove-port=40911/tcp --permanent"
        echo "  firewall-cmd --reload"
    fi
else
    echo "⚠️  firewalld 未运行，请根据实际情况手动关闭端口"
fi

# ==================================================
# 7. 清理环境变量（可选）
# ==================================================
echo ""
echo "=== 7. 清理环境变量 ==="
# 从 /etc/profile 或 ~/.bashrc 中移除 RocketMQ 相关配置（如果存在）
if grep -q "ROCKETMQ_HOME" /etc/profile 2>/dev/null; then
    echo "检测到 /etc/profile 中有 ROCKETMQ_HOME 配置"
    if [ "$FORCE" = true ]; then
        sed -i '/ROCKETMQ_HOME/d' /etc/profile
        sed -i '/rocketmq/d' /etc/profile
        echo "✅ 已清理 /etc/profile 中的 RocketMQ 环境变量"
    else
        read -p "是否清理 /etc/profile 中的 RocketMQ 环境变量？(y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            sed -i '/ROCKETMQ_HOME/d' /etc/profile
            sed -i '/rocketmq/d' /etc/profile
            echo "✅ 已清理 /etc/profile 中的 RocketMQ 环境变量"
        fi
    fi
fi

# ==================================================
# 8. 清理完成
# ==================================================
echo ""
echo "=================================================="
echo "✅ RocketMQ DLedger 集群移除完成！"
echo "=================================================="
echo "清理摘要："
echo "  - 服务状态: 已停止并禁用"
echo "  - 安装目录: ${INSTALL_DIR} $([ -d "$INSTALL_DIR" ] && echo "(异常-仍存在)" || echo "已删除")"
echo "  - 数据目录: $([ "$KEEP_DATA" = true ] && echo "保留: ${DATA_DIR}" || echo "已删除")"
echo "  - 用户状态: $([ "$REMOVE_USER" = true ] && echo "已删除" || echo "保留: ${RUN_USER}")"
echo "  - Systemd: 已清理"
echo "=================================================="

# 检查残留
echo ""
echo "残留检查："
if systemctl list-unit-files | grep -q "rocketmq-" 2>/dev/null; then
    echo "⚠️  仍有 rocketmq 相关 systemd 文件残留"
    systemctl list-unit-files | grep "rocketmq-"
else
    echo "✅ 无 systemd 文件残留"
fi

if ps aux | grep -v grep | grep -q "rocketmq"; then
    echo "⚠️  仍有 RocketMQ 相关进程运行："
    ps aux | grep -v grep | grep rocketmq
else
    echo "✅ 无 RocketMQ 进程残留"
fi

echo ""
echo "如需彻底清理，可手动执行："
echo "  rm -rf /tmp/rocketmq*"
echo "  rm -rf ~/.rocketmq"
echo "=================================================="