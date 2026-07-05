#!/bin/bash
# ==================================================
# RocketMQ 5.4.0 DLedger Controller 集群卸载脚本
# 功能：停止服务、删除Systemd配置、清空程序与数据目录
# ⚠️ 警告：此脚本会永久删除所有 RocketMQ 消息数据，请谨慎执行！
# ==================================================

INSTALL_DIR="/ncpsmw/rocketmq_cluster"
DATA_DIR="/ncpsdata/rocketmq_cluster"

echo "=================================================="
echo "⚠️  警告：即将卸载 RocketMQ 并清除所有数据！"
echo "  程序目录: ${INSTALL_DIR}"
echo "  数据目录: ${DATA_DIR}"
echo "=================================================="

# 3秒倒计时，给用户取消的机会
echo "将在 3 秒后开始执行卸载... (按 Ctrl+C 取消)"
sleep 3

# ==================================================
# 1. 停止并禁用 Systemd 服务
# ==================================================
echo "=== 1. 停止并禁用 RocketMQ 服务 ==="
# 停止所有匹配的服务
systemctl stop rocketmq-namesrv.service 2>/dev/null
systemctl stop rocketmq-controller.service 2>/dev/null
systemctl stop rocketmq-broker-*.service 2>/dev/null

# 禁用服务自启动
systemctl disable rocketmq-namesrv.service 2>/dev/null
systemctl disable rocketmq-controller.service 2>/dev/null
systemctl disable rocketmq-broker-*.service 2>/dev/null

# 强杀可能残留的 RocketMQ Java 进程
echo "=== 强制清理残留 Java 进程 ==="
pkill -f "org.apache.rocketmq.broker.BrokerStartup" 2>/dev/null
pkill -f "org.apache.rocketmq.namesrv.NamesrvStartup" 2>/dev/null
pkill -f "org.apache.rocketmq.controller.ControllerStartup" 2>/dev/null

# ==================================================
# 2. 删除 Systemd 服务文件
# ==================================================
echo "=== 2. 删除 Systemd 服务文件 ==="
rm -f /etc/systemd/system/rocketmq-namesrv.service
rm -f /etc/systemd/system/rocketmq-controller.service
rm -f /etc/systemd/system/rocketmq-broker-*.service
systemctl daemon-reload

# ==================================================
# 3. 清理防火墙规则 (如果使用 firewalld)
# ==================================================
# if systemctl is-active --quiet firewalld; then
#     echo "=== 3. 移除防火墙端口规则 ==="
#     firewall-cmd --remove-port=9876/tcp --permanent >/dev/null 2>&1
#     firewall-cmd --remove-port=9091/tcp --permanent >/dev/null 2>&1
#     firewall-cmd --remove-port=10911/tcp --permanent >/dev/null 2>&1
#     firewall-cmd --remove-port=10912/tcp --permanent >/dev/null 2>&1
#     firewall-cmd --remove-port=10921/tcp --permanent >/dev/null 2>&1
#     firewall-cmd --remove-port=10922/tcp --permanent >/dev/null 2>&1
#     firewall-cmd --reload
# fi

# ==================================================
# 4. 清理程序和数据目录
# ==================================================
echo "=== 4. 清理程序与数据目录 ==="
rm -rf ${INSTALL_DIR}
rm -rf ${DATA_DIR}

# ==================================================
# 5. 清理临时解压目录 (如果有残留)
# ==================================================
rm -rf /tmp/rocketmq-all-5.4.0-bin-release

echo "=================================================="
echo "✅ RocketMQ 节点卸载完成！"
echo "=================================================="
