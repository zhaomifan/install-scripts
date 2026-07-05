#!/bin/bash
# ==================================================
# RocketMQ 3主3从 单机清理脚本
# 功能：只清理本机上的 RocketMQ 组件
# ==================================================

INSTALL_DIR="/ncpsmw/rocketmq_cluster"
DATA_DIR="/ncpsdata/rocketmq_cluster"
LOG_DIR="/ncpsdata/rocketmq_logs"
RUN_USER="rocketmq"

# 端口定义
NS_PORT=9876
CONTROLLER_PORT=9091
MASTER_PORT=10911
SLAVE_PORT=10921

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
    echo "  $0                  # 完全清理本机，保留用户"
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
echo "⚠️  RocketMQ 单机清理脚本"
echo "=================================================="
echo "本机IP: $(hostname -I | awk '{print $1}')"
echo "将执行以下操作："
echo "  1. 停止本机所有 rocketmq-* 服务"
echo "  2. 禁用所有 rocketmq-* 服务"
echo "  3. 删除安装目录: ${INSTALL_DIR}"
if [ "$KEEP_DATA" = true ]; then
    echo "  4. 保留数据目录: ${DATA_DIR}（--keep-data 已启用）"
else
    echo "  4. 删除数据目录: ${DATA_DIR}"
    echo "  5. 删除日志目录: ${LOG_DIR}"
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
# 1. 停止并禁用所有服务
# ==================================================
echo ""
echo "=== 1. 停止并禁用所有服务 ==="

# 停止所有 rocketmq 相关服务
for svc in $(systemctl list-unit-files | grep -E '^rocketmq-.*\.service' | awk '{print $1}'); do
    echo "处理 ${svc}..."
    systemctl is-active --quiet "$svc" 2>/dev/null && systemctl stop "$svc"
    systemctl is-enabled --quiet "$svc" 2>/dev/null && systemctl disable "$svc"
done

# 等待服务完全停止
sleep 2

# 强制杀死残留进程
echo "清理残留进程..."
pkill -f "mqnamesrv" 2>/dev/null && echo "  ✅ 已清理 NameServer 进程"
pkill -f "mqcontroller" 2>/dev/null && echo "  ✅ 已清理 Controller 进程"
pkill -f "mqbroker" 2>/dev/null && echo "  ✅ 已清理 Broker 进程"
sleep 1

# ==================================================
# 2. 删除 systemd 服务文件
# ==================================================
echo ""
echo "=== 2. 删除 systemd 服务文件 ==="
rm -f /etc/systemd/system/rocketmq-*.service
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
    # 删除日志目录
    if [ -d "$LOG_DIR" ]; then
        rm -rf "$LOG_DIR"
        echo "✅ 已删除: $LOG_DIR"
    fi
fi

# ==================================================
# 5. 删除用户（可选）
# ==================================================
echo ""
echo "=== 5. 处理用户 ==="
if [ "$REMOVE_USER" = true ]; then
    if id "$RUN_USER" >/dev/null 2>&1; then
        # 杀掉该用户的所有进程
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
# 6. 清理临时文件
# ==================================================
echo ""
echo "=== 6. 清理临时文件 ==="
rm -rf /tmp/rocketmq* 2>/dev/null
rm -rf ~/.rocketmq 2>/dev/null
echo "✅ 临时文件已清理"

# ==================================================
# 7. 防火墙端口清理
# ==================================================
echo ""
echo "=== 7. 防火墙端口处理 ==="
if systemctl is-active --quiet firewalld 2>/dev/null; then
    echo "检测到 firewalld 正在运行"
    
    # 获取当前已开放的端口列表
    OPEN_PORTS=$(firewall-cmd --list-ports 2>/dev/null)
    
    if echo "$OPEN_PORTS" | grep -qE "9876|9091|10911|10921|10912|10922"; then
        if [ "$FORCE" = true ]; then
            REMOVE_FW=true
        else
            echo "当前开放的端口: $OPEN_PORTS"
            read -p "移除 RocketMQ 相关防火墙端口 (9876, 9091, 10911, 10912, 10921, 10922)？(y/n): " -n 1 -r
            echo
            [[ $REPLY =~ ^[Yy]$ ]] && REMOVE_FW=true || REMOVE_FW=false
        fi
        
        if [ "$REMOVE_FW" = true ]; then
            for port in 9876 9091 10911 10912 10921 10922; do
                firewall-cmd --remove-port=${port}/tcp --permanent 2>/dev/null
            done
            firewall-cmd --reload 2>/dev/null
            echo "✅ 防火墙端口已移除"
        else
            echo "⚠️  跳过防火墙端口清理"
        fi
    else
        echo "✅ 未发现 RocketMQ 相关防火墙端口"
    fi
else
    echo "⚠️  firewalld 未运行，跳过防火墙清理"
fi

# ==================================================
# 8. 清理环境变量
# ==================================================
echo ""
echo "=== 8. 清理环境变量 ==="
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
else
    echo "✅ /etc/profile 中无 RocketMQ 相关配置"
fi

# ==================================================
# 9. 清理完成
# ==================================================
echo ""
echo "=================================================="
echo "✅ 本机 RocketMQ 清理完成！"
echo "=================================================="
echo "清理摘要："
echo "  - 服务状态: 已停止并禁用"
echo "  - 安装目录: ${INSTALL_DIR} $([ -d "$INSTALL_DIR" ] && echo "❌ 仍存在" || echo "✅ 已删除")"
echo "  - 数据目录: $([ "$KEEP_DATA" = true ] && echo "✅ 保留: ${DATA_DIR}" || echo "✅ 已删除")"
echo "  - 用户状态: $([ "$REMOVE_USER" = true ] && echo "✅ 已删除" || echo "✅ 保留: ${RUN_USER}")"
echo "  - Systemd: ✅ 已清理"
echo "  - 防火墙: ✅ 已处理"
echo "=================================================="

# 残留检查
echo ""
echo "=== 残留检查 ==="

# 检查 systemd 文件
if systemctl list-unit-files 2>/dev/null | grep -q "^rocketmq-"; then
    echo "⚠️  仍有 rocketmq 相关 systemd 文件残留："
    systemctl list-unit-files 2>/dev/null | grep "^rocketmq-"
else
    echo "✅ 无 systemd 文件残留"
fi

# 检查进程
if ps aux 2>/dev/null | grep -v grep | grep -qE "mqnamesrv|mqcontroller|mqbroker"; then
    echo "⚠️  仍有 RocketMQ 相关进程运行："
    ps aux 2>/dev/null | grep -v grep | grep -E "mqnamesrv|mqcontroller|mqbroker"
else
    echo "✅ 无 RocketMQ 进程残留"
fi

# 检查端口
if ss -tlnp 2>/dev/null | grep -qE "9876|9091|10911|10921"; then
    echo "⚠️  仍有 RocketMQ 相关端口监听："
    ss -tlnp 2>/dev/null | grep -E "9876|9091|10911|10921"
else
    echo "✅ 无 RocketMQ 端口监听"
fi

echo ""
echo "=================================================="