#!/bin/bash
# RocketMQ Dashboard 集群版安装脚本 (基于单机版改造)
# 适配环境：NameServer 集群 (80:19876, 84:19876, 98:19876)
# 部署节点：192.168.15.84

# ========== 配置区 ==========
# 集群 NameServer 地址 (分号分隔)
NAMESRV_ADDRS="192.168.15.80:19876;192.168.15.84:19876;192.168.15.99:19876"


# Dashboard 访问信息
DASH_IP="192.168.15.84"
DASH_PORT="8089"

# 路径配置 (保持原有习惯)
DASHBOARD_JAR="/home/install/rocketmq/rocketmq-dashboard-2.0.0.jar"
INSTALL_DIR="/ncpsmw/rocketmq_dashboard"
DATA_DIR="/ncpsdata/rocketmq_dashboard"
LOG_DIR="${DATA_DIR}/logs"
RUN_USER="rocketmq"
JAVA_HOME="/ncpsmw/jdk21"

# ========== 1. 清理旧服务 ==========
echo "=== Step 1: 清理旧环境 ==="
systemctl stop rocketmq-dashboard 2>/dev/null
systemctl disable rocketmq-dashboard 2>/dev/null
rm -rf ${INSTALL_DIR}
rm -rf ${DATA_DIR}
rm -f /etc/systemd/system/rocketmq-dashboard.service
systemctl daemon-reload

# ========== 2. 创建目录 ==========
echo "=== Step 2: 创建目录结构 ==="
mkdir -p ${INSTALL_DIR}
mkdir -p ${LOG_DIR}

# ========== 3. 拷贝 Jar 包 ==========
echo "=== Step 3: 部署程序包 ==="
if [ -f "${DASHBOARD_JAR}" ]; then
    cp ${DASHBOARD_JAR} ${INSTALL_DIR}/
    echo "✅ Jar 包拷贝成功"
else
    echo "❌ 错误: 源 Jar 包 ${DASHBOARD_JAR} 不存在，请检查路径！"
    exit 1
fi

# ========== 4. 配置文件 (增强版) ==========
echo "=== Step 4: 生成配置文件 ==="
cat > ${INSTALL_DIR}/application.properties <<EOF
server.port=${DASH_PORT}

rocketmq.config.namesrvAddr=${NAMESRV_ADDRS}
rocketmq.namesrv.addr=${NAMESRV_ADDRS}
rocketmq.config.isVIPChannel=false

rocketmq.config.accessKey=rocketmq
rocketmq.config.secretKey=ncps@2026
rocketmq.config.useTLS=false

spring.servlet.multipart.max-file-size=100MB
spring.servlet.multipart.max-request-size=100MB
EOF

# ========== 5. Systemd 服务 (修复启动参数) ==========
echo "=== Step 5: 注册 Systemd 服务 ==="
cat > /etc/systemd/system/rocketmq-dashboard.service <<EOF
[Unit]
Description=RocketMQ Dashboard Cluster
After=network.target

[Service]
User=${RUN_USER}
Group=${RUN_USER}
Environment="JAVA_HOME=${JAVA_HOME}"
WorkingDirectory=${INSTALL_DIR}

# 关键修复：使用外部配置文件，并加上内存参数
set -x
ExecStart=${JAVA_HOME}/bin/java -Xms256m -Xmx256m \
-Dserver.port=${DASH_PORT} \
-Dspring.config.location=${INSTALL_DIR}/application.properties \
-jar ${INSTALL_DIR}/rocketmq-dashboard-2.0.0.jar

Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# ========== 6. 防火墙配置 (增强版) ==========
echo "=== Step 6: 配置防火墙 ==="
if command -v firewall-cmd &> /dev/null; then
    echo "正在开放集群所需端口..."
    
    # NameServer 端口
    firewall-cmd --zone=public --add-port=19876/tcp --permanent
    # Dashboard 端口
    firewall-cmd --zone=public --add-port=${DASH_PORT}/tcp --permanent
    
    firewall-cmd --reload
    echo "✅ 防火墙规则已更新"
else
    echo "⚠️ 未检测到 firewall-cmd，跳过防火墙配置"
fi

# ========== 7. 授权与启动 ==========
echo "=== Step 7: 授权并启动服务 ==="
chown -R ${RUN_USER}:${RUN_USER} ${INSTALL_DIR}
chown -R ${RUN_USER}:${RUN_USER} ${DATA_DIR}
chmod -R 755 ${INSTALL_DIR}
chmod -R 755 ${DATA_DIR}

systemctl daemon-reload
systemctl enable rocketmq-dashboard
systemctl start rocketmq-dashboard

# ========== 8. 验证与反馈 ==========
sleep 3
echo "============================================="
if systemctl is-active --quiet rocketmq-dashboard; then
    echo "✅ Dashboard 集群版安装成功！"
    echo "🌐 访问地址: http://${DASH_IP}:${DASH_PORT}"
    echo "📊 监控集群: ${NAMESRV_ADDRS}"
    echo "🔥 已开放端口: 19876, ${DASH_PORT}"
else
    echo "❌ 启动失败，请查看日志:"
    echo "tail -100 ${LOG_DIR}/dashboard.log"
fi
echo "============================================="
