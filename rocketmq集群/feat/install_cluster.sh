#!/bin/bash
# ==================================================
# RocketMQ 5.4.0 DLedger Controller 集群部署脚本（ACL 2.0）
# 架构：3 节点 DLedger Group，自动主从切换
# ==================================================

# -------------- 配置区 --------------
IP_1="192.168.15.80"
IP_2="192.168.15.84"
IP_3="192.168.15.98"

SERVER_IP=$(hostname -I | awk '{print $1}')

INSTALL_DIR="/ncpsmw/rocketmq_cluster"
DATA_DIR="/ncpsdata/rocketmq_cluster"
JAVA_HOME="/ncpsmw/jdk21"
PACKAGE_DIR="/home/install/rocketmq"
ZIP_FILE="rocketmq-all-5.4.0-bin-release.zip"
RUN_USER="rocketmq"

NS_PORT=9876
BROKER_PORT=10911
DL_PORT=40911          # DLedger 内部通信端口

MQ_USER="rocketmq"
MQ_PASSWORD="ncps@2026"

# DLedger 配置
DL_GROUP="broker-group-1"
DL_PEERS="n0-${IP_1}:40911;n1-${IP_2}:40911;n2-${IP_3}:40911"

# 判断节点 ID
if [ "$SERVER_IP" == "$IP_1" ]; then
    NODE_ID=0
elif [ "$SERVER_IP" == "$IP_2" ]; then
    NODE_ID=1
elif [ "$SERVER_IP" == "$IP_3" ]; then
    NODE_ID=2
else
    echo "错误：本机IP $SERVER_IP 未在列表中配置。"
    exit 1
fi

NAMESRV_ADDR="${IP_1}:${NS_PORT};${IP_2}:${NS_PORT};${IP_3}:${NS_PORT}"

echo "=== 准备部署 DLedger 集群节点 ==="
echo "本机IP: ${SERVER_IP}"
echo "节点ID: ${NODE_ID}"
echo "DLedger Group: ${DL_GROUP}"

# ==================================================
# 0. 环境准备
# ==================================================
echo "=== 0. 环境准备 ==="
mkdir -p ${DATA_DIR}/logs ${DATA_DIR}/store
if ! id ${RUN_USER} >/dev/null 2>&1; then
    useradd -m -s /bin/bash ${RUN_USER}
fi
chown -R ${RUN_USER}:${RUN_USER} ${DATA_DIR}

# ==================================================
# 1. 清理旧环境（可选，生产环境慎用）
# ==================================================
echo "=== 1. 清理旧环境 ==="
# 先停止服务
systemctl stop rocketmq-namesrv 2>/dev/null || true
systemctl stop rocketmq-broker 2>/dev/null || true

# 只清理安装目录，保留数据（除非强制重装）
if [ "$1" == "--force-clean" ]; then
    echo "强制清理数据目录..."
    rm -rf ${DATA_DIR}/store/*
fi

rm -rf ${INSTALL_DIR}
rm -f /etc/systemd/system/rocketmq-*.service
systemctl daemon-reload

# ==================================================
# 2. 安装
# ==================================================
echo "=== 2. 解压安装包 ==="
mkdir -p ${INSTALL_DIR}

cd ${PACKAGE_DIR}
[ ! -f ${ZIP_FILE} ] && { echo "安装包不存在"; exit 1; }

unzip -o ${ZIP_FILE} -d /tmp/ >/dev/null
mv /tmp/rocketmq-all-5.4.0-bin-release/* ${INSTALL_DIR}/
rm -rf /tmp/rocketmq-all-5.4.0-bin-release

chown -R ${RUN_USER}:${RUN_USER} ${INSTALL_DIR}
chown -R ${RUN_USER}:${RUN_USER} ${DATA_DIR}

# ==================================================
# 3. JVM 配置（根据实际内存调整）
# ==================================================
echo "=== 3. 配置 JVM ==="
sed -i "1i export JAVA_HOME=${JAVA_HOME}" ${INSTALL_DIR}/bin/runserver.sh
sed -i "1i export JAVA_HOME=${JAVA_HOME}" ${INSTALL_DIR}/bin/runbroker.sh

# NameServer: 1G（轻量）
sed -i '/JAVA_OPT="${JAVA_OPT} -server -Xms.*"/d' ${INSTALL_DIR}/bin/runserver.sh
sed -i '/JAVA_OPT="${JAVA_OPT}"/a JAVA_OPT="${JAVA_OPT} -server -Xms1g -Xmx1g -Xmn512m"' ${INSTALL_DIR}/bin/runserver.sh

# Broker: 4G（DLedger 需要更多内存）
sed -i '/JAVA_OPT="${JAVA_OPT} -server -Xms.*"/d' ${INSTALL_DIR}/bin/runbroker.sh
sed -i '/JAVA_OPT="${JAVA_OPT}"/a JAVA_OPT="${JAVA_OPT} -server -Xms4g -Xmx4g -Xmn2g"' ${INSTALL_DIR}/bin/runbroker.sh

# ==================================================
# 4. 生成配置文件
# ==================================================
echo "=== 4. 生成配置文件 ==="

# 4.1 NameServer 配置
cat > ${INSTALL_DIR}/conf/namesrv.conf <<EOF
listenPort=${NS_PORT}
EOF

# 4.2 DLedger Broker 配置（核心）
cat > ${INSTALL_DIR}/conf/dledger.conf <<EOF
brokerClusterName=RocketMQ-Cluster
namesrvAddr=${NAMESRV_ADDR}
listenPort=${BROKER_PORT}
brokerIP1=${SERVER_IP}
deleteWhen=04
fileReservedTime=48
flushDiskType=ASYNC_FLUSH
storePathRootDir=${DATA_DIR}/store
storePathCommitLog=${DATA_DIR}/store/commitlog
storePathConsumeQueue=${DATA_DIR}/store/consumequeue
storePathIndex=${DATA_DIR}/store/index

# 禁用自动创建 Topic
autoCreateTopicEnable=false

# ========== DLedger 配置（自动主从切换） ==========
enableDLegerCommitLog=true
dLegerGroup=${DL_GROUP}
dLegerPeers=${DL_PEERS}
dLegerSelfId=n${NODE_ID}

# DLedger 内部端口（与 listenPort 不同）
sendMessageThreadPoolNums=16

# ========== ACL 2.0 认证配置 ==========
authenticationEnabled=true
authenticationProvider=org.apache.rocketmq.auth.authentication.provider.DefaultAuthenticationProvider
authenticationStrategy=org.apache.rocketmq.auth.authentication.strategy.StatefulAuthenticationStrategy
authenticationMetadataProvider=org.apache.rocketmq.auth.authentication.provider.LocalAuthenticationMetadataProvider

initAuthenticationUser={"username":"${MQ_USER}","password":"${MQ_PASSWORD}"}
innerClientAuthenticationCredentials={"accessKey":"${MQ_USER}","secretKey":"${MQ_PASSWORD}"}

# ========== ACL 2.0 授权配置 ==========
authorizationEnabled=true
authorizationProvider=org.apache.rocketmq.auth.authorization.provider.DefaultAuthorizationProvider
authorizationStrategy=org.apache.rocketmq.auth.authorization.strategy.StatefulAuthorizationStrategy
authorizationMetadataProvider=org.apache.rocketmq.auth.authorization.provider.LocalAuthorizationMetadataProvider
EOF

# 4.3 mqadmin 工具认证
cat > ${INSTALL_DIR}/conf/tools.yml <<EOF
accessKey: ${MQ_USER}
secretKey: ${MQ_PASSWORD}
EOF

# ==================================================
# 5. Systemd 独立服务配置（NameServer + Broker 分离）
# ==================================================
echo "=== 5. 配置 Systemd 服务 ==="

# 5.1 NameServer 服务
cat > /etc/systemd/system/rocketmq-namesrv.service <<EOF
[Unit]
Description=RocketMQ NameServer
After=network.target

[Service]
User=${RUN_USER}
Group=${RUN_USER}
Environment="JAVA_HOME=${JAVA_HOME}"
Environment="ROCKETMQ_HOME=${INSTALL_DIR}"
Type=simple
ExecStart=${INSTALL_DIR}/bin/mqnamesrv -c ${INSTALL_DIR}/conf/namesrv.conf
ExecStop=/bin/kill -s TERM \$MAINPID
Restart=on-failure
RestartSec=5
StandardOutput=append:${DATA_DIR}/logs/namesrv.log
StandardError=append:${DATA_DIR}/logs/namesrv-error.log

[Install]
WantedBy=multi-user.target
EOF

# 5.2 Broker 服务（DLedger 模式）
cat > /etc/systemd/system/rocketmq-broker.service <<EOF
[Unit]
Description=RocketMQ DLedger Broker
After=network.target rocketmq-namesrv.service
Wants=rocketmq-namesrv.service

[Service]
User=${RUN_USER}
Group=${RUN_USER}
Environment="JAVA_HOME=${JAVA_HOME}"
Environment="ROCKETMQ_HOME=${INSTALL_DIR}"
Type=simple
ExecStart=${INSTALL_DIR}/bin/mqbroker -c ${INSTALL_DIR}/conf/dledger.conf
ExecStop=/bin/kill -s TERM \$MAINPID
Restart=on-failure
RestartSec=10
StandardOutput=append:${DATA_DIR}/logs/broker.log
StandardError=append:${DATA_DIR}/logs/broker-error.log

[Install]
WantedBy=multi-user.target
EOF

# ==================================================
# 6. 防火墙
# ==================================================
echo "=== 6. 开放防火墙端口 ==="
if systemctl is-active --quiet firewalld; then
    firewall-cmd --add-port=${NS_PORT}/tcp --permanent
    firewall-cmd --add-port=${BROKER_PORT}/tcp --permanent
    firewall-cmd --add-port=${DL_PORT}/tcp --permanent
    firewall-cmd --reload
    echo "防火墙端口已开放"
else
    echo "警告：firewalld 未运行，请手动开放端口：${NS_PORT}, ${BROKER_PORT}, ${DL_PORT}"
fi

# ==================================================
# 7. 启动与验证
# ==================================================
echo "=== 7. 启动服务 ==="
systemctl daemon-reload
systemctl enable rocketmq-namesrv
systemctl enable rocketmq-broker

systemctl start rocketmq-namesrv
sleep 3
systemctl start rocketmq-broker

# 等待服务启动
echo "等待服务初始化..."
sleep 10

# 健康检查
echo "=== 8. 健康检查 ==="
if systemctl is-active --quiet rocketmq-namesrv; then
    echo "✅ NameServer 运行正常"
else
    echo "❌ NameServer 启动失败，查看日志：${DATA_DIR}/logs/namesrv-error.log"
fi

if systemctl is-active --quiet rocketmq-broker; then
    echo "✅ Broker 运行正常"
else
    echo "❌ Broker 启动失败，查看日志：${DATA_DIR}/logs/broker-error.log"
fi

# 检查端口监听
echo "=== 端口监听状态 ==="
ss -tlnp | grep -E "${NS_PORT}|${BROKER_PORT}|${DL_PORT}" || netstat -tlnp 2>/dev/null | grep -E "${NS_PORT}|${BROKER_PORT}|${DL_PORT}"

echo ""
echo "=================================================="
echo "✅ DLedger 集群节点部署完成！"
echo "=================================================="
echo "节点ID: ${NODE_ID}"
echo "本机IP: ${SERVER_IP}"
echo "DLedger Group: ${DL_GROUP}"
echo "NameServer端口: ${NS_PORT}"
echo "Broker端口: ${BROKER_PORT}"
echo "DLedger端口: ${DL_PORT}"
echo "=================================================="
echo "日志位置:"
echo "  NameServer: ${DATA_DIR}/logs/namesrv.log"
echo "  Broker: ${DATA_DIR}/logs/broker.log"
echo "=================================================="
echo "验证命令:"
echo "  # 查看集群状态"
echo "  sh ${INSTALL_DIR}/bin/mqadmin clusterList -n \"${NAMESRV_ADDR}\""
echo ""
echo "  # 查看 DLedger 选举状态"
echo "  sh ${INSTALL_DIR}/bin/mqadmin getBrokerConfig -n \"${NAMESRV_ADDR}\" -b ${SERVER_IP}:${BROKER_PORT}"
echo ""
echo "  # 查看用户列表"
echo "  sh ${INSTALL_DIR}/bin/mqadmin listUser -n \"${NAMESRV_ADDR}\" -c RocketMQ-Cluster"
echo "=================================================="
echo "业务连接账号:"
echo "  accessKey: ${MQ_USER}"
echo "  secretKey: ${MQ_PASSWORD}"
echo "=================================================="