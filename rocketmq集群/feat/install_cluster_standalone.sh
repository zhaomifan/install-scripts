#!/bin/bash
# ==================================================
# RocketMQ 5.4.0 集群版部署脚本（修复版）
# 修复点：
# 1. 停止服务增加容错 || true，解决重启循环
# 2. 强制创建 rocketmq 用户，解决 No such process
# 3. 强制创建日志目录，解决日志丢失问题
# ==================================================

# -------------- 配置区 --------------
# 集群节点IP（严格按照顺序）
IP_1="192.168.15.80"
IP_2="192.168.15.84"
IP_3="192.168.15.98"

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
NS_PORT=9876
MASTER_PORT=10921
SLAVE_PORT=10931

# ==================================================
# 0. 强制环境准备（解决用户和目录问题）
# ==================================================
echo "=== 0. 环境准备 ==="
# 强制创建日志目录，防止启动失败
mkdir -p ${DATA_DIR}/logs
# 强制创建用户，防止 Systemd 报错 No such process
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
# 先尝试停止（可能不存在，所以忽略错误）
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

# 授权
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
# 4. 生成配置文件
# ==================================================
echo "=== 生成 Broker 配置 ==="

# 4.1 Master 配置
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
EOF

# 4.2 Slave 配置
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

# 启动命令：确保日志目录存在
ExecStartPre=/bin/mkdir -p ${DATA_DIR}/logs
ExecStart=/bin/sh -c '\
${INSTALL_DIR}/bin/mqnamesrv -p ${NS_PORT} > ${DATA_DIR}/logs/ns.log 2>&1 & \
sleep 3; \
${INSTALL_DIR}/bin/mqbroker -c ${INSTALL_DIR}/conf/master.conf > ${DATA_DIR}/logs/m.log 2>&1 & \
sleep 3; \
${INSTALL_DIR}/bin/mqbroker -c ${INSTALL_DIR}/conf/slave.conf > ${DATA_DIR}/logs/s.log 2>&1 & \
sleep 5'

# 停止命令：增加容错 || true
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
echo "? 集群节点部署完成！"
echo "服务名称: ${SERVICE_NAME}"
echo "NameServer端口: ${NS_PORT}"
echo "Master端口: ${MASTER_PORT} (${M_NAME})"
echo "Slave端口: ${SLAVE_PORT} (${S_NAME})"
echo "=================================================="
echo "日志位置: ${DATA_DIR}/logs/"
echo "验证命令:"
echo "sh ${INSTALL_DIR}/bin/mqadmin clusterList -n \"${NAMESRV_ADDR}\""
