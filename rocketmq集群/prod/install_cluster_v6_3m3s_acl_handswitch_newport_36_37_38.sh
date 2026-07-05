#!/bin/bash
# ==================================================
# RocketMQ 5.4.0 集群版部署脚本（ACL 2.0 增强版）
# 修复点：
# 1. 停止服务增加容错 || true，解决重启循环
# 2. ACL 1.0 → ACL 2.0（5.3.3+ 必须使用 ACL 2.0）
# 3. 禁用自动创建Topic
# ==================================================

# -------------- 配置区 --------------
# 集群节点IP（严格按照顺序）
IP_1="192.168.15.36"
IP_2="192.168.15.37"
IP_3="192.168.15.38"

# 获取本机IP
SERVER_IP=$(hostname -I | awk '{print $1}')

# 共存环境关键配置
INSTALL_DIR="/ncpsmw/rocketmq_cluster"
DATA_DIR="/ncpsdata/rocketmq_cluster"
SERVICE_NAME="rocketmq-cluster"
JAVA_HOME="/ncpsmw/jdk21"
PACKAGE_DIR="/home/install/rocketmq"
ZIP_FILE="rocketmq-all-5.4.0-bin-release.zip"
RUN_USER="rocketmq"

# 集群专用端口
NS_PORT=19876
MASTER_PORT=20921
SLAVE_PORT=20931

# 用户认证配置
MQ_USER="rocketmq"
MQ_PASSWORD="ncps@2026"

# ==================================================
# 0. 强制环境准备（解决用户和目录问题）
# ==================================================
echo "=== 0. 环境准备 ==="
mkdir -p ${DATA_DIR}/logs
if ! id ${RUN_USER} >/dev/null 2>&1; then
    echo "创建用户 ${RUN_USER}..."
    useradd -m -s /bin/bash ${RUN_USER}
fi
chown -R ${RUN_USER}:${RUN_USER} ${DATA_DIR}

# ==================================================
# 1. 环境检测
# ==================================================
NAMESRV_ADDR="${IP_1}:${NS_PORT};${IP_2}:${NS_PORT};${IP_3}:${NS_PORT}"

# 判断节点角色
if [ "$SERVER_IP" == "$IP_1" ]; then
    M_NAME="broker-a"; M_ID=0; S_NAME="broker-b"; S_ID=1
elif [ "$SERVER_IP" == "$IP_2" ]; then
    M_NAME="broker-b"; M_ID=0; S_NAME="broker-c"; S_ID=1
elif [ "$SERVER_IP" == "$IP_3" ]; then
    M_NAME="broker-c"; M_ID=0; S_NAME="broker-a"; S_ID=1
else
    echo "错误：本机IP $SERVER_IP 未在列表中配置。"
    exit 1
fi

echo "=== 准备部署集群节点 ==="
echo "本机IP: ${SERVER_IP}"
echo "部署角色: ${M_NAME}(Master) + ${S_NAME}(Slave)"

# ==================================================
# 2. 清理旧的集群环境
# ==================================================
echo "=== 清理旧集群环境 ==="
systemctl stop ${SERVICE_NAME} 2>/dev/null || true

rm -rf ${INSTALL_DIR}
rm -rf ${DATA_DIR}
rm -f /etc/systemd/system/${SERVICE_NAME}.service
systemctl daemon-reload

# ==================================================
# 3. 安装与配置
# ==================================================
echo "=== 解压安装包 ==="
mkdir -p ${INSTALL_DIR}
mkdir -p ${DATA_DIR}/master/store
mkdir -p ${DATA_DIR}/slave/store
mkdir -p ${DATA_DIR}/logs

cd ${PACKAGE_DIR}
[ ! -f ${ZIP_FILE} ] && { echo "安装包不存在"; exit 1; }

unzip -o ${ZIP_FILE} -d /tmp/ >/dev/null
mv /tmp/rocketmq-all-5.4.0-bin-release/* ${INSTALL_DIR}/
rm -rf /tmp/rocketmq-all-5.4.0-bin-release

chown -R ${RUN_USER}:${RUN_USER} ${INSTALL_DIR}
chown -R ${RUN_USER}:${RUN_USER} ${DATA_DIR}

# JVM配置
echo "=== 配置JVM ==="
sed -i "1i export JAVA_HOME=${JAVA_HOME}" ${INSTALL_DIR}/bin/runserver.sh
sed -i "1i export JAVA_HOME=${JAVA_HOME}" ${INSTALL_DIR}/bin/runbroker.sh

sed -i '/JAVA_OPT="${JAVA_OPT} -server -Xms.*"/d' ${INSTALL_DIR}/bin/runserver.sh
sed -i '/JAVA_OPT="${JAVA_OPT}"/a JAVA_OPT="${JAVA_OPT} -server -Xms256m -Xmx256m -Xmn128m"' ${INSTALL_DIR}/bin/runserver.sh

sed -i '/JAVA_OPT="${JAVA_OPT} -server -Xms.*"/d' ${INSTALL_DIR}/bin/runbroker.sh
sed -i '/JAVA_OPT="${JAVA_OPT}"/a JAVA_OPT="${JAVA_OPT} -server -Xms512m -Xmx512m"' ${INSTALL_DIR}/bin/runbroker.sh

# ==================================================
# 4. 生成配置文件（含 ACL 2.0 权限配置）
# ==================================================
echo "=== 生成 Broker 配置 ==="

# 4.1 NameServer 配置
cat > ${INSTALL_DIR}/conf/namesrv.conf <<EOF
listenPort=${NS_PORT}
EOF

# 4.2 Master 配置（ACL 2.0）
cat > ${INSTALL_DIR}/conf/master.conf <<EOF
brokerClusterName=RocketMQ-Cluster
namesrvAddr=${NAMESRV_ADDR}
brokerName=${M_NAME}
brokerId=${M_ID}
listenPort=${MASTER_PORT}
brokerIP1=${SERVER_IP}
deleteWhen=04
fileReservedTime=48
brokerRole=ASYNC_MASTER
flushDiskType=ASYNC_FLUSH
storePathRootDir=${DATA_DIR}/master/store
storePathCommitLog=${DATA_DIR}/master/store/commitlog
storePathConsumeQueue=${DATA_DIR}/master/store/consumequeue
storePathIndex=${DATA_DIR}/master/store/index

# 安全配置
autoCreateTopicEnable=false

# --- ACL 2.0 认证配置 (RocketMQ 5.3.0+ 必须使用 ACL 2.0) ---
authenticationEnabled = true
authenticationProvider = org.apache.rocketmq.auth.authentication.provider.DefaultAuthenticationProvider
authenticationStrategy = org.apache.rocketmq.auth.authentication.strategy.StatefulAuthenticationStrategy
authenticationMetadataProvider = org.apache.rocketmq.auth.authentication.provider.LocalAuthenticationMetadataProvider

# 初始化管理员用户（首次启动自动创建，类型为 Super）
initAuthenticationUser = {"username":"${MQ_USER}","password":"${MQ_PASSWORD}"}

# 组件间认证凭证（Broker内部通信、主从同步、Broker与NameServer通信）
innerClientAuthenticationCredentials = {"accessKey":"${MQ_USER}","secretKey":"${MQ_PASSWORD}"}

# --- ACL 2.0 授权配置 ---
authorizationEnabled = true
authorizationProvider = org.apache.rocketmq.auth.authorization.provider.DefaultAuthorizationProvider
authorizationStrategy = org.apache.rocketmq.auth.authorization.strategy.StatefulAuthorizationStrategy
authorizationMetadataProvider = org.apache.rocketmq.auth.authorization.provider.LocalAuthorizationMetadataProvider
EOF

# 4.3 Slave 配置（ACL 2.0）
cat > ${INSTALL_DIR}/conf/slave.conf <<EOF
brokerClusterName=RocketMQ-Cluster
namesrvAddr=${NAMESRV_ADDR}
brokerName=${S_NAME}
brokerId=${S_ID}
listenPort=${SLAVE_PORT}
brokerIP1=${SERVER_IP}
deleteWhen=04
fileReservedTime=48
brokerRole=SLAVE
flushDiskType=ASYNC_FLUSH
storePathRootDir=${DATA_DIR}/slave/store
storePathCommitLog=${DATA_DIR}/slave/store/commitlog
storePathConsumeQueue=${DATA_DIR}/slave/store/consumequeue
storePathIndex=${DATA_DIR}/slave/store/index

# 安全配置
autoCreateTopicEnable=false

# --- ACL 2.0 认证配置 ---
authenticationEnabled = true
authenticationProvider = org.apache.rocketmq.auth.authentication.provider.DefaultAuthenticationProvider
authenticationStrategy = org.apache.rocketmq.auth.authentication.strategy.StatefulAuthenticationStrategy
authenticationMetadataProvider = org.apache.rocketmq.auth.authentication.provider.LocalAuthenticationMetadataProvider

# 初始化管理员用户（首次启动自动创建）
initAuthenticationUser = {"username":"${MQ_USER}","password":"${MQ_PASSWORD}"}

# 组件间认证凭证
innerClientAuthenticationCredentials = {"accessKey":"${MQ_USER}","secretKey":"${MQ_PASSWORD}"}

# --- ACL 2.0 授权配置 ---
authorizationEnabled = true
authorizationProvider = org.apache.rocketmq.auth.authorization.provider.DefaultAuthorizationProvider
authorizationStrategy = org.apache.rocketmq.auth.authorization.strategy.StatefulAuthorizationStrategy
authorizationMetadataProvider = org.apache.rocketmq.auth.authorization.provider.LocalAuthorizationMetadataProvider
EOF

# 4.4 mqadmin 工具认证配置（必须，否则管理命令无法执行）
cat > ${INSTALL_DIR}/conf/tools.yml <<EOF
accessKey: ${MQ_USER}
secretKey: ${MQ_PASSWORD}
EOF

# ==================================================
# 5. Systemd 服务配置（修复版）
# ==================================================
echo "=== 配置 Systemd 服务 ==="

cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=RocketMQ Cluster Service
After=network.target

[Service]
User=${RUN_USER}
Group=${RUN_USER}
Environment="JAVA_HOME=${JAVA_HOME}"
Environment="ROCKETMQ_HOME=${INSTALL_DIR}"
Type=forking

ExecStartPre=/bin/mkdir -p ${DATA_DIR}/logs
ExecStart=/bin/sh -c '\
${INSTALL_DIR}/bin/mqnamesrv -c ${INSTALL_DIR}/conf/namesrv.conf > ${DATA_DIR}/logs/ns.log 2>&1 & \
sleep 3; \
${INSTALL_DIR}/bin/mqbroker -c ${INSTALL_DIR}/conf/master.conf > ${DATA_DIR}/logs/m.log 2>&1 & \
sleep 3; \
${INSTALL_DIR}/bin/mqbroker -c ${INSTALL_DIR}/conf/slave.conf > ${DATA_DIR}/logs/s.log 2>&1 & \
sleep 5'

ExecStop=/bin/sh -c '\
${INSTALL_DIR}/bin/mqshutdown broker; \
sleep 2; \
${INSTALL_DIR}/bin/mqshutdown namesrv || true'

Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# ==================================================
# 6. 防火墙
# ==================================================
echo "=== 开放防火墙端口 ==="
firewall-cmd --add-port=${NS_PORT}/tcp --permanent 2>/dev/null
firewall-cmd --add-port=${MASTER_PORT}/tcp --permanent 2>/dev/null
firewall-cmd --add-port=${SLAVE_PORT}/tcp --permanent 2>/dev/null
firewall-cmd --reload 2>/dev/null

# ==================================================
# 7. 启动
# ==================================================
systemctl daemon-reload
systemctl enable ${SERVICE_NAME}
systemctl start ${SERVICE_NAME}

echo "=================================================="
echo "✅ 集群节点部署完成！"
echo "服务名称: ${SERVICE_NAME}"
echo "NameServer端口: ${NS_PORT}"
echo "Master端口: ${MASTER_PORT} (${M_NAME})"
echo "Slave端口: ${SLAVE_PORT} (${S_NAME})"
echo "=================================================="
echo "日志位置: ${DATA_DIR}/logs/"
echo "验证命令（自动读取 tools.yml）："
echo "sh ${INSTALL_DIR}/bin/mqadmin clusterList -n \"${NAMESRV_ADDR}\""
echo ""
echo "查看用户列表："
echo "sh ${INSTALL_DIR}/bin/mqadmin listUser -n \"${NAMESRV_ADDR}\" -c RocketMQ-Cluster"
echo ""
echo "业务连接账号:"
echo "accessKey: ${MQ_USER}"
echo "secretKey: ${MQ_PASSWORD}"
echo "注意：生产者/消费者需配置 accessKey 和 secretKey 才能连接"
echo "=================================================="