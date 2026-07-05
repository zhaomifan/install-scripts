#!/bin/bash
# ==================================================
# RocketMQ 5.4.0 生产级一键安装脚本（隔离用户+JDK21）
# 环境：麒麟/CentOS 7/8/9，JDK路径固定为 /ncpsmw/jdk21
# ==================================================

# -------------- 配置区（仅需修改SERVER_IP）--------------
SERVER_IP="192.168.15.84"      # 改为你的服务器IP
JAVA_HOME="/ncpsmw/jdk21"
PACKAGE_DIR="/home/install/rocketmq"
INSTALL_DIR="/ncpsmw/rocketmq"
DATA_DIR="/ncpsdata/rocketmq"
ZIP_FILE="rocketmq-all-5.4.0-bin-release.zip"
RUN_USER="rocketmq"
RUN_GROUP="rocketmq"

# ==================================================
# 1. 清理旧环境（避免冲突）
# ==================================================
echo "=== 清理旧环境 ==="
systemctl stop rocketmq 2>/dev/null
systemctl disable rocketmq 2>/dev/null
pkill -9 -f mqnamesrv 2>/dev/null
pkill -9 -f mqbroker 2>/dev/null
rm -rf ${INSTALL_DIR}
rm -rf ${DATA_DIR}
rm -f /etc/systemd/system/rocketmq.service
userdel -r ${RUN_USER} 2>/dev/null
systemctl daemon-reload

# ==================================================
# 2. 创建隔离用户（可登录shell，避免权限问题）
# ==================================================
echo "=== 创建隔离用户 ${RUN_USER} ==="
id ${RUN_USER} >/dev/null 2>&1 || useradd -m -s /bin/bash ${RUN_USER}

# ==================================================
# 3. 创建目录并授权
# ==================================================
echo "=== 创建目录并授权 ==="
mkdir -p ${INSTALL_DIR}
mkdir -p ${DATA_DIR}/logs/rocketmqlogs
mkdir -p ${DATA_DIR}/store/{commitlog,consumequeue,index}

# 核心授权（避免日志/数据写入失败）
chown -R ${RUN_USER}:${RUN_GROUP} ${INSTALL_DIR}
chown -R ${RUN_USER}:${RUN_GROUP} ${DATA_DIR}
chmod -R 755 ${INSTALL_DIR}
chmod -R 775 ${DATA_DIR}

# ==================================================
# 4. 解压安装包
# ==================================================
echo "=== 解压安装包 ==="
cd ${PACKAGE_DIR}
if [ ! -f ${ZIP_FILE} ]; then
    echo "错误：安装包 ${ZIP_FILE} 不存在，请检查路径"
    exit 1
fi
unzip -o ${ZIP_FILE} -d /tmp/
mv /tmp/rocketmq-all-5.4.0-bin-release/* ${INSTALL_DIR}/
rm -rf /tmp/rocketmq-all-5.4.0-bin-release
chown -R ${RUN_USER}:${RUN_GROUP} ${INSTALL_DIR}

# ==================================================
# 5. 强制配置JDK与内存（关键修复！）
# ==================================================
echo "=== 配置JDK与内存 ==="
# 强制写入JAVA_HOME到所有启动脚本
sed -i "1i export JAVA_HOME=${JAVA_HOME}" ${INSTALL_DIR}/bin/runserver.sh
sed -i "1i export JAVA_HOME=${JAVA_HOME}" ${INSTALL_DIR}/bin/runbroker.sh
sed -i "1i export JAVA_HOME=${JAVA_HOME}" ${INSTALL_DIR}/bin/tools.sh

# 强制修改内存配置（删除旧配置，写入新配置，确保生效）
sed -i '/JAVA_OPT="${JAVA_OPT} -server -Xms.*"/d' ${INSTALL_DIR}/bin/runserver.sh
sed -i '/JAVA_OPT="${JAVA_OPT} -server -Xms.*"/d' ${INSTALL_DIR}/bin/runbroker.sh
sed -i '/JAVA_OPT="${JAVA_OPT}"/a JAVA_OPT="${JAVA_OPT} -server -Xms256m -Xmx256m -Xmn128m"' ${INSTALL_DIR}/bin/runserver.sh
sed -i '/JAVA_OPT="${JAVA_OPT}"/a JAVA_OPT="${JAVA_OPT} -server -Xms512m -Xmx512m"' ${INSTALL_DIR}/bin/runbroker.sh

# ==================================================
# 6. 写入Broker配置
# ==================================================
echo "=== 写入Broker配置 ==="
cat > ${INSTALL_DIR}/conf/broker.conf <<EOF
brokerIP1=${SERVER_IP}
listenPort=10911
namesrvAddr=${SERVER_IP}:9876
brokerClusterName=DefaultCluster
brokerName=broker-a
brokerId=0
deleteWhen=04
fileReservedTime=48
brokerRole=ASYNC_MASTER
flushDiskType=ASYNC_FLUSH
autoCreateTopicEnable=true

storePathRootDir=${DATA_DIR}/store
storePathCommitLog=${DATA_DIR}/store/commitlog
storePathConsumeQueue=${DATA_DIR}/store/consumequeue
storePathIndex=${DATA_DIR}/store/index
logPath=${DATA_DIR}/logs
rocketmqHome=${INSTALL_DIR}
EOF

# ==================================================
# 7. 防火墙配置
# ==================================================
echo "=== 开放防火墙端口 ==="
firewall-cmd --add-port=9876/tcp --permanent 2>/dev/null
firewall-cmd --add-port=10911/tcp --permanent 2>/dev/null
firewall-cmd --reload 2>/dev/null

# ==================================================
# 8. Systemd服务配置（双进程稳定版）
# ==================================================
echo "=== 配置Systemd服务 ==="
cat > /etc/systemd/system/rocketmq.service <<EOF
[Unit]
Description=RocketMQ 5.4.0
After=network.target

[Service]
User=${RUN_USER}
Group=${RUN_GROUP}
Environment="JAVA_HOME=${JAVA_HOME}"
Environment="ROCKETMQ_HOME=${INSTALL_DIR}"

Type=simple
ExecStart=/bin/sh -c '\
${INSTALL_DIR}/bin/mqnamesrv > ${DATA_DIR}/logs/namesrv.log 2>&1 & \
sleep 5 && \
${INSTALL_DIR}/bin/mqbroker -c ${INSTALL_DIR}/conf/broker.conf > ${DATA_DIR}/logs/broker.log 2>&1 & \
tail -f /dev/null'

ExecStop=/bin/sh -c '\
${INSTALL_DIR}/bin/mqshutdown broker; \
sleep 2; \
${INSTALL_DIR}/bin/mqshutdown namesrv'

Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# ==================================================
# 9. 启动服务并设置开机自启
# ==================================================
echo "=== 启动服务 ==="
systemctl daemon-reload
systemctl enable rocketmq
systemctl start rocketmq

# ==================================================
# 10. 验证结果
# ==================================================
echo "=================================================="
echo "✅ RocketMQ 安装完成！"
echo "运行用户：${RUN_USER}"
echo "安装目录：${INSTALL_DIR}"
echo "数据/日志目录：${DATA_DIR}"
echo "=================================================="
echo "📋 验证命令："
echo "1. 查看服务状态：systemctl status rocketmq"
echo "2. 查看进程：jps | grep -E \"NamesrvStartup|BrokerStartup\""
echo "3. 查看端口：ss -tlnp | grep -E \"9876|10911\""
echo "4. 查看日志：tail -f ${DATA_DIR}/logs/rocketmqlogs/broker.log"
echo "=================================================="