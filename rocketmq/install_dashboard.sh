#!/bin/bash
# RocketMQ Dashboard 2.0.0 免密安装脚本
SERVER_IP="192.168.15.84"
DASHBOARD_JAR="/home/install/rocketmq/rocketmq-dashboard-2.0.0.jar"
INSTALL_DIR="/ncpsmw/rocketmq_dashboard"
DATA_DIR="/ncpsdata/rocketmq_dashboard"
LOG_DIR="${DATA_DIR}/logs"
RUN_USER="rocketmq"
JAVA_HOME="/ncpsmw/jdk21"

# 清理旧服务
systemctl stop rocketmq-dashboard 2>/dev/null
systemctl disable rocketmq-dashboard 2>/dev/null
rm -rf ${INSTALL_DIR}
rm -rf ${DATA_DIR}
rm -f /etc/systemd/system/rocketmq-dashboard.service
systemctl daemon-reload

# 创建目录
mkdir -p ${INSTALL_DIR}
mkdir -p ${LOG_DIR}

# 拷贝包并授权
cp ${DASHBOARD_JAR} ${INSTALL_DIR}/
chown -R ${RUN_USER}:${RUN_USER} ${INSTALL_DIR}
chown -R ${RUN_USER}:${RUN_USER} ${DATA_DIR}
chmod -R 755 ${INSTALL_DIR}
chmod -R 755 ${DATA_DIR}

# 免密配置
cat > ${INSTALL_DIR}/application.properties <<EOF
server.port=8089
rocketmq.config.namesrvAddr=${SERVER_IP}:9876
rocketmq.config.isVIPChannel=false
EOF

# 系统服务（JDK21 原生兼容）
cat > /etc/systemd/system/rocketmq-dashboard.service <<EOF
[Unit]
Description=RocketMQ Dashboard 2.0.0
After=network.target rocketmq.service

[Service]
User=${RUN_USER}
Group=${RUN_USER}
Environment="JAVA_HOME=${JAVA_HOME}"
WorkingDirectory=${INSTALL_DIR}
ExecStart=${JAVA_HOME}/bin/java -jar rocketmq-dashboard-2.0.0.jar
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 放行端口
firewall-cmd --add-port=8089/tcp --permanent
firewall-cmd --reload

# 启动服务
systemctl daemon-reload
systemctl enable rocketmq-dashboard
systemctl start rocketmq-dashboard

echo "============================================="
echo "✅ RocketMQ Dashboard 2.0.0 安装完成"
echo "访问地址：http://${SERVER_IP}:8089"
echo "============================================="