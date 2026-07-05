#!/bin/bash
# ==================================================
# RocketMQ 5.4.0 DLedger Controller 3主3从 集群部署脚本（ACL 2.0 - 动态主备切换版）
# 架构：3个独立Broker Group，每个Group 2副本，共6节点
# 核心特性：依托 Controller 集群动态分配 Master/Slave 角色，支持自动主备切换
# ==================================================

# -------------- 配置区 --------------
# 三台物理节点
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
CONTROLLER_PORT=9877 # Controller Raft 端口

# ==================================================
# 3主3从 Group 规划 (每个Group 2副本)
# ==================================================
# Group-A: 副本1在 node1 (10911), 副本2在 node2 (10921)
# Group-B: 副本1在 node2 (10911), 副本2在 node3 (10921)
# Group-C: 副本1在 node3 (10911), 副本2在 node1 (10921)

# 节点 IP 映射
declare -A NODE_IPS=(
  ["node1"]="$IP_1"
  ["node2"]="$IP_2"
  ["node3"]="$IP_3"
)

# 判断当前节点名称
if [ "$SERVER_IP" == "$IP_1" ]; then
  CURRENT_NODE="node1"
elif [ "$SERVER_IP" == "$IP_2" ]; then
  CURRENT_NODE="node2"
elif [ "$SERVER_IP" == "$IP_3" ]; then
  CURRENT_NODE="node3"
else
  echo "错误：本机IP $SERVER_IP 未在列表中配置。"
  exit 1
fi

# NameServer 地址
NAMESRV_ADDR="${IP_1}:${NS_PORT};${IP_2}:${NS_PORT};${IP_3}:${NS_PORT}"

# Controller 集群地址
CONTROLLER_PEERS="n0-${IP_1}:${CONTROLLER_PORT};n1-${IP_2}:${CONTROLLER_PORT};n2-${IP_3}:${CONTROLLER_PORT}"

# 根据当前节点确定 Controller ID
case $CURRENT_NODE in
  node1) CONTROLLER_ID="n0" ;;
  node2) CONTROLLER_ID="n1" ;;
  node3) CONTROLLER_ID="n2" ;;
esac

# ACL 配置
MQ_USER="rocketmq"
MQ_PASSWORD="ncps@2026"

# ==================================================
# 检查并创建目录
# ==================================================
prepare_dirs() {
  echo "=== 准备目录 ==="
  mkdir -p ${DATA_DIR}/logs ${DATA_DIR}/store
  mkdir -p ${INSTALL_DIR}
  if ! id ${RUN_USER} >/dev/null 2>&1; then
    useradd -m -s /bin/bash ${RUN_USER}
  fi
  chown -R ${RUN_USER}:${RUN_USER} ${DATA_DIR} ${INSTALL_DIR}
}

# ==================================================
# 安装 RocketMQ 二进制
# ==================================================
install_rocketmq() {
  echo "=== 安装 RocketMQ 二进制 ==="
  cd ${PACKAGE_DIR}
  [ ! -f ${ZIP_FILE} ] && { echo "安装包不存在: ${PACKAGE_DIR}/${ZIP_FILE}"; exit 1; }

  # 清理旧安装
  rm -rf ${INSTALL_DIR}/*
  unzip -o ${ZIP_FILE} -d /tmp/ >/dev/null
  mv /tmp/rocketmq-all-5.4.0-bin-release/* ${INSTALL_DIR}/
  rm -rf /tmp/rocketmq-all-5.4.0-bin-release
  chown -R ${RUN_USER}:${RUN_USER} ${INSTALL_DIR}

  # 配置 JAVA_HOME
  sed -i "1i export JAVA_HOME=${JAVA_HOME}" ${INSTALL_DIR}/bin/runserver.sh
  sed -i "1i export JAVA_HOME=${JAVA_HOME}" ${INSTALL_DIR}/bin/runbroker.sh

  # JVM 配置
  sed -i '/JAVA_OPT="${JAVA_OPT} -server -Xms.*"/d' ${INSTALL_DIR}/bin/runserver.sh
  sed -i '/JAVA_OPT="${JAVA_OPT}"/a JAVA_OPT="${JAVA_OPT} -server -Xms1g -Xmx1g -Xmn512m"' ${INSTALL_DIR}/bin/runserver.sh
  sed -i '/JAVA_OPT="${JAVA_OPT} -server -Xms.*"/d' ${INSTALL_DIR}/bin/runbroker.sh
  sed -i '/JAVA_OPT="${JAVA_OPT}"/a JAVA_OPT="${JAVA_OPT} -server -Xms4g -Xmx4g -Xmn2g"' ${INSTALL_DIR}/bin/runbroker.sh
}

# ==================================================
# 生成 NameServer 配置
# ==================================================
configure_nameserver() {
  echo "=== 配置 NameServer ==="
  cat > ${INSTALL_DIR}/conf/namesrv.conf <<EOF
listenPort=${NS_PORT}
EOF
}

# ==================================================
# 生成 Controller 配置
# ==================================================
configure_controller() {
  echo "=== 配置 DLedger Controller ==="
  mkdir -p ${INSTALL_DIR}/controller/conf
  mkdir -p ${DATA_DIR}/controller_data
  cat > ${INSTALL_DIR}/controller/conf/controller.conf <<EOF
# DLedger Controller 配置
controllerDLegerPeers=${CONTROLLER_PEERS}
controllerDLegerSelfId=${CONTROLLER_ID}
controllerPort=${CONTROLLER_PORT}
dataDir=${DATA_DIR}/controller_data
rocketmqHome=${INSTALL_DIR}
EOF
}

# ==================================================
# 生成 Broker 配置文件 (动态主备模式)
# ==================================================
configure_broker() {
  local node=$1
  local group_name=$2
  local replica_role=$3 # REPLICA_1 或 REPLICA_2 (仅用于区分端口和目录，不再代表主备)
  local listen_port=$4
  local ha_port=$((listen_port + 1))
  
  # 统一目录命名，按 group 划分，不再按角色划分，防止主备切换后数据目录不一致
  local broker_dir="${INSTALL_DIR}/${group_name}_${replica_role}"
  local data_dir="${DATA_DIR}/store/${group_name}_${replica_role}"

  echo "配置 Broker: ${group_name} ${replica_role} (端口: ${listen_port})"
  mkdir -p ${broker_dir}/conf
  mkdir -p ${data_dir}/{commitlog,consumequeue,index}

  cat > ${broker_dir}/conf/broker.conf <<EOF
# ==========================================
# Broker 基础配置
# ==========================================
brokerClusterName=RocketMQ-Cluster
brokerName=${group_name}
# brokerId=-1 表示交由 Controller 动态分配 (0为Master, 1为Slave)
brokerId=-1
brokerIP1=${SERVER_IP}
listenPort=${listen_port}
haListenPort=${ha_port}
namesrvAddr=${NAMESRV_ADDR}

# ==========================================
# 存储路径
# ==========================================
storePathRootDir=${data_dir}
storePathCommitLog=${data_dir}/commitlog
storePathConsumeQueue=${data_dir}/consumequeue
storePathIndex=${data_dir}/index
storeCheckpoint=${data_dir}/checkpoint
abortFile=${data_dir}/abort

# ==========================================
# 存储配置
# ==========================================
deleteWhen=04
fileReservedTime=48
mapedFileSizeCommitLog=1073741824
mapedFileSizeConsumeQueue=300000
diskMaxUsedSpaceRatio=88
maxMessageSize=4194304

# ==========================================
# 刷盘策略
# ==========================================
flushDiskType=ASYNC_FLUSH
flushCommitLogLeastPages=4
flushCommitLogThoroughInterval=10000
flushConsumeQueueLeastPages=2
flushConsumeQueueThoroughInterval=10000

# ==========================================
# 主从角色配置 (Controller 模式核心)
# ==========================================
# 统一配置为 ASYNC_MASTER，实际角色由 Controller 根据 brokerId 动态下放
brokerRole=ASYNC_MASTER

# ==========================================
# DLedger Controller 模式 (核心)
# ==========================================
enableDLedgerController=true
controllerAddr=${CONTROLLER_PEERS}
dLegerGroup=${group_name}
brokerRegisterPeriodMs=10000

# ==========================================
# 消息配置
# ==========================================
defaultTopicQueueNums=8
autoCreateTopicEnable=true
autoCreateSubscriptionGroup=true
sendMessageTimeout=3000
compressMsgBodyOverHowmuch=4096

# ==========================================
# 线程池配置
# ==========================================
sendMessageThreadPoolNums=16
pullMessageThreadPoolNums=16
queryMessageThreadPoolNums=8
adminBrokerThreadPoolNums=8
clientManageThreadPoolNums=16
consumerManageThreadPoolNums=16

# ==========================================
# ACL 2.0 认证配置
# ==========================================
authenticationEnabled=true
authenticationProvider=org.apache.rocketmq.auth.authentication.provider.DefaultAuthenticationProvider
authenticationStrategy=org.apache.rocketmq.auth.authentication.strategy.StatefulAuthenticationStrategy
authenticationMetadataProvider=org.apache.rocketmq.auth.authentication.provider.LocalAuthenticationMetadataProvider
initAuthenticationUser={"username":"${MQ_USER}","password":"${MQ_PASSWORD}"}
innerClientAuthenticationCredentials={"accessKey":"${MQ_USER}","secretKey":"${MQ_PASSWORD}"}

# ==========================================
# ACL 2.0 授权配置
# ==========================================
authorizationEnabled=true
authorizationProvider=org.apache.rocketmq.auth.authorization.provider.DefaultAuthorizationProvider
authorizationStrategy=org.apache.rocketmq.auth.authorization.strategy.StatefulAuthorizationStrategy
authorizationMetadataProvider=org.apache.rocketmq.auth.authorization.provider.LocalAuthorizationMetadataProvider

# ==========================================
# 其他配置
# ==========================================
enablePropertyFilter=false
enableTrace=true
traceTopicName=RMQ_SYS_TRACE_TOPIC
longPollingEnable=true
notifyConsumerIdsChangedEnable=true

# ==========================================
# 高可用配置
# ==========================================
haSendHeartbeatInterval=1000
haHousekeepingInterval=20000
haTransferBatchSize=32768
haSlaveFallbehindMax=268435456
osPageCacheBusyTimeOutMills=1000
EOF

  chown -R ${RUN_USER}:${RUN_USER} ${broker_dir} ${data_dir}
}

# ==================================================
# 生成 tools.yml (ACL 认证)
# ==================================================
configure_tools() {
  echo "=== 配置工具认证 ==="
  cat > ${INSTALL_DIR}/conf/tools.yml <<EOF
accessKey: ${MQ_USER}
secretKey: ${MQ_PASSWORD}
EOF
}

# ==================================================
# 生成 Systemd 服务
# ==================================================
create_systemd_services() {
  echo "=== 创建 Systemd 服务 ==="

  # NameServer
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

  # Controller
  cat > /etc/systemd/system/rocketmq-controller.service <<EOF
[Unit]
Description=RocketMQ DLedger Controller
After=network.target rocketmq-namesrv.service

[Service]
User=${RUN_USER}
Group=${RUN_USER}
Environment="JAVA_HOME=${JAVA_HOME}"
Environment="ROCKETMQ_HOME=${INSTALL_DIR}"
Type=simple
ExecStart=${INSTALL_DIR}/bin/mqcontroller -c ${INSTALL_DIR}/controller/conf/controller.conf
ExecStop=/bin/kill -s TERM \$MAINPID
Restart=on-failure
RestartSec=5
StandardOutput=append:${DATA_DIR}/logs/controller.log
StandardError=append:${DATA_DIR}/logs/controller-error.log

[Install]
WantedBy=multi-user.target
EOF

  # 为当前节点创建 Broker 服务 (两副本)
  # node1: group-a 副本1 + group-c 副本2
  # node2: group-b 副本1 + group-a 副本2
  # node3: group-c 副本1 + group-b 副本2
  local replica1_group=""
  local replica2_group=""
  case $CURRENT_NODE in
    node1) replica1_group="group-a"; replica2_group="group-c" ;;
    node2) replica1_group="group-b"; replica2_group="group-a" ;;
    node3) replica1_group="group-c"; replica2_group="group-b" ;;
  esac

  # Broker 副本1 服务
  cat > /etc/systemd/system/rocketmq-broker-${replica1_group}-r1.service <<EOF
[Unit]
Description=RocketMQ Broker ${replica1_group} (Replica 1)
After=network.target rocketmq-namesrv.service rocketmq-controller.service
Wants=rocketmq-namesrv.service rocketmq-controller.service

[Service]
User=${RUN_USER}
Group=${RUN_USER}
Environment="JAVA_HOME=${JAVA_HOME}"
Environment="ROCKETMQ_HOME=${INSTALL_DIR}"
Type=simple
ExecStart=${INSTALL_DIR}/bin/mqbroker -c ${INSTALL_DIR}/${replica1_group}_REPLICA_1/conf/broker.conf
ExecStop=/bin/kill -s TERM \$MAINPID
Restart=on-failure
RestartSec=10
StandardOutput=append:${DATA_DIR}/logs/broker-${replica1_group}-r1.log
StandardError=append:${DATA_DIR}/logs/broker-${replica1_group}-r1-error.log

[Install]
WantedBy=multi-user.target
EOF

  # Broker 副本2 服务
  cat > /etc/systemd/system/rocketmq-broker-${replica2_group}-r2.service <<EOF
[Unit]
Description=RocketMQ Broker ${replica2_group} (Replica 2)
After=network.target rocketmq-namesrv.service rocketmq-controller.service
Wants=rocketmq-namesrv.service rocketmq-controller.service

[Service]
User=${RUN_USER}
Group=${RUN_USER}
Environment="JAVA_HOME=${JAVA_HOME}"
Environment="ROCKETMQ_HOME=${INSTALL_DIR}"
Type=simple
ExecStart=${INSTALL_DIR}/bin/mqbroker -c ${INSTALL_DIR}/${replica2_group}_REPLICA_2/conf/broker.conf
ExecStop=/bin/kill -s TERM \$MAINPID
Restart=on-failure
RestartSec=10
StandardOutput=append:${DATA_DIR}/logs/broker-${replica2_group}-r2.log
StandardError=append:${DATA_DIR}/logs/broker-${replica2_group}-r2-error.log

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
}

# ==================================================
# 防火墙配置
# ==================================================
configure_firewall() {
  echo "=== 配置防火墙 ==="
  if systemctl is-active --quiet firewalld; then
    firewall-cmd --add-port=${NS_PORT}/tcp --permanent
    firewall-cmd --add-port=${CONTROLLER_PORT}/tcp --permanent
    firewall-cmd --add-port=10911/tcp --permanent
    firewall-cmd --add-port=10912/tcp --permanent
    firewall-cmd --add-port=10921/tcp --permanent
    firewall-cmd --add-port=10922/tcp --permanent
    firewall-cmd --reload
    echo "✅ 防火墙端口已开放"
  else
    echo "⚠️ firewalld 未运行，请手动开放端口"
  fi
}

# ==================================================
# 启动服务
# ==================================================
start_services() {
  echo "=== 启动服务 ==="
  systemctl enable rocketmq-namesrv
  systemctl enable rocketmq-controller
  systemctl start rocketmq-namesrv
  sleep 3
  systemctl start rocketmq-controller
  sleep 5

  # 启动 Broker
  local replica1_group=""
  local replica2_group=""
  case $CURRENT_NODE in
    node1) replica1_group="group-a"; replica2_group="group-c" ;;
    node2) replica1_group="group-b"; replica2_group="group-a" ;;
    node3) replica1_group="group-c"; replica2_group="group-b" ;;
  esac

  systemctl enable rocketmq-broker-${replica1_group}-r1
  systemctl enable rocketmq-broker-${replica2_group}-r2
  systemctl start rocketmq-broker-${replica1_group}-r1
  sleep 3
  systemctl start rocketmq-broker-${replica2_group}-r2
}

# ==================================================
# 健康检查
# ==================================================
health_check() {
  echo "=== 健康检查 ==="
  sleep 10
  echo "--- 服务状态 ---"
  systemctl is-active rocketmq-namesrv && echo "✅ NameServer: 运行中" || echo "❌ NameServer: 未运行"
  systemctl is-active rocketmq-controller && echo "✅ Controller: 运行中" || echo "❌ Controller: 未运行"

  local replica1_group=""
  local replica2_group=""
  case $CURRENT_NODE in
    node1) replica1_group="group-a"; replica2_group="group-c" ;;
    node2) replica1_group="group-b"; replica2_group="group-a" ;;
    node3) replica1_group="group-c"; replica2_group="group-b" ;;
  esac

  systemctl is-active rocketmq-broker-${replica1_group}-r1 && echo "✅ Broker ${replica1_group} R1: 运行中" || echo "❌ Broker ${replica1_group} R1: 未运行"
  systemctl is-active rocketmq-broker-${replica2_group}-r2 && echo "✅ Broker ${replica2_group} R2: 运行中" || echo "❌ Broker ${replica2_group} R2: 未运行"

  echo "--- 端口监听 ---"
  ss -tlnp 2>/dev/null | grep -E "${NS_PORT}|${CONTROLLER_PORT}|10911|10921" || netstat -tlnp 2>/dev/null | grep -E "${NS_PORT}|${CONTROLLER_PORT}|10911|10921"
}

# ==================================================
# 输出部署信息
# ==================================================
print_summary() {
  local replica1_group=""
  local replica2_group=""
  case $CURRENT_NODE in
    node1) replica1_group="group-a"; replica2_group="group-c" ;;
    node2) replica1_group="group-b"; replica2_group="group-a" ;;
    node3) replica1_group="group-c"; replica2_group="group-b" ;;
  esac

  echo ""
  echo "=================================================="
  echo "✅ RocketMQ 3主3从 动态切换集群节点部署完成！"
  echo "=================================================="
  echo "当前节点: ${CURRENT_NODE} (${SERVER_IP})"
  echo ""
  echo "--- 本节点 Broker 副本 ---"
  echo " 副本1: ${replica1_group} (端口: 10911)"
  echo " 副本2: ${replica2_group} (端口: 10921)"
  echo ""
  echo "--- 全局架构 (Controller 动态选主) ---"
  echo " Group-A: 副本1@${IP_1}:10911, 副本2@${IP_2}:10921"
  echo " Group-B: 副本1@${IP_2}:10911, 副本2@${IP_3}:10921"
  echo " Group-C: 副本1@${IP_3}:10911, 副本2@${IP_1}:10921"
  echo ""
  echo "--- 连接信息 ---"
  echo " NameServer: ${NAMESRV_ADDR}"
  echo " Controller: ${CONTROLLER_PEERS}"
  echo " Username: ${MQ_USER}"
  echo " Password: ${MQ_PASSWORD}"
  echo ""
  echo "--- 验证命令 ---"
  echo " ${INSTALL_DIR}/bin/mqadmin clusterList -n \"${NAMESRV_ADDR}\" -a ${MQ_USER}:${MQ_PASSWORD}"
  echo " ${INSTALL_DIR}/bin/mqadmin topicList -n \"${NAMESRV_ADDR}\" -a ${MQ_USER}:${MQ_PASSWORD}"
  echo "=================================================="
}

# ==================================================
# 主执行流程
# ==================================================
main() {
  echo "=== RocketMQ 3主3从 动态切换集群部署 ==="
  echo "节点: ${CURRENT_NODE} (${SERVER_IP})"

  # 如果带 --force-clean 参数，清理数据
  if [ "$1" == "--force-clean" ]; then
    echo "强制清理数据..."
    rm -rf ${DATA_DIR}/store/*
    rm -rf ${INSTALL_DIR}
    systemctl stop rocketmq-* 2>/dev/null || true
    rm -f /etc/systemd/system/rocketmq-*.service
    systemctl daemon-reload
  fi

  prepare_dirs
  install_rocketmq
  configure_nameserver
  configure_controller
  configure_tools

  # 配置当前节点的两个副本
  case $CURRENT_NODE in
    node1)
      configure_broker "node1" "group-a" "REPLICA_1" 10911
      configure_broker "node1" "group-c" "REPLICA_2" 10921
      ;;
    node2)
      configure_broker "node2" "group-b" "REPLICA_1" 10911
      configure_broker "node2" "group-a" "REPLICA_2" 10921
      ;;
    node3)
      configure_broker "node3" "group-c" "REPLICA_1" 10911
      configure_broker "node3" "group-b" "REPLICA_2" 10921
      ;;
  esac

  create_systemd_services
  configure_firewall
  start_services
  health_check
  print_summary
}

main "$@"
