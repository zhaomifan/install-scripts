#!/bin/bash
# RocketMQ Dashboard 集群版安装脚本 (基于单机版改造)
# 适配环境：NameServer 集群 (80:9876, 84:9876, 98:9876)
# 部署节点：192.168.15.98

# 路径配置 (保持原有习惯)
DASHBOARD_JAR="/home/install/rocketmq/rocketmq-dashboard-2.0.0.jar"
INSTALL_DIR="/ncpsmw/rocketmq_dashboard"
DATA_DIR="/ncpsdata/rocketmq_dashboard"

# ========== 1. 清理旧服务 ==========
echo "=== Step 1: 清理旧环境 ==="
systemctl stop rocketmq-dashboard 2>/dev/null
systemctl disable rocketmq-dashboard 2>/dev/null
rm -rf ${INSTALL_DIR}
rm -rf ${DATA_DIR}
rm -f /etc/systemd/system/rocketmq-dashboard.service
systemctl daemon-reload

