#!/bin/bash
# ============================================================
# RocketMQ 5.4.0 固定 3 主 3 从集群部署脚本（无自动切换，稳定可靠）
# 架构：3 节点，每节点 1 个 NameServer + 1 个 Master + 1 个 Slave
# 特性：固定角色、ACL 2.0 认证、禁用自动创建 Topic
# ============================================================

set -euo pipefail

# ============================================================
# 配置区（按实际环境修改）
# ============================================================

# 三台物理节点 IP
IP_1="192.168.15.80"
IP_2="192.168.15.84"
IP_3="192.168.15.98"

# 当前节点 IP（自动检测，也可手动指定）
SERVER_IP=$(hostname -I | awk '{print $1}')

# 安装路径
INSTALL_DIR="/ncpsmw/rocketmq_cluster"
DATA_DIR="/ncpsdata/rocketmq_cluster"
JAVA_HOME="/ncpsmw/jdk21"
PACKAGE_DIR="/home/install/rocketmq"
ZIP_FILE="rocketmq-all-5.4.0-bin-release.zip"
RUN_USER="rocketmq"

# 端口
NS_PORT=9876

# ACL 认证
MQ_USER="rocketmq"
MQ_PASSWORD="ncps@2026"

# ============================================================
# 节点与 Broker 映射（固定角色，永不切换）
# ============================================================
#
# 节点布局：
#   node1 (IP_1): Master-A (10911) + Slave-C (10921)
#   node2 (IP_2): Master-B (10911) + Slave-A (10921)
#   node3 (IP_3): Master-C (10911) + Slave-B (10921)
#
# 这样每组 1 主 1 从，跨节点部署，任意一节点宕机不影响服务

declare -A NODE_IPS=(
  ["node1"]="$IP_1"
  ["node2"]="$IP_2"
  ["node3"]="$IP_3"
)

# 判断当前节点
if [ "$SERVER_IP" == "$IP_1" ]; then
  CURRENT_NODE="node1"
elif [ "$SERVER_IP" == "$IP_2" ]; then
  CURRENT_NODE="node2"
elif [ "$SERVER_IP" == "$IP_3" ]; then
  CURRENT_NODE="node3"
else
  echo "错误：本机 IP $SERVER_IP 不在配置列表中"
  exit 1
fi

# NameServer 集群地址
NAMESRV_ADDR="${IP_1}:${NS_PORT};${IP_2}:${NS_PORT};${IP_3}:${NS_PORT}"

# ============================================================
# 工具函数
# ============================================================

log_info()  { echo -e "\033[32m[INFO]\033[0m  $*"; }
log_warn()  { echo -e "\033[33m[WARN]\033[0m  $*"; }
log_error() { echo -e "\033[31m[ERROR]\033[0m $*"; }

# ============================================================
# 准备目录与用户
# ============================================================

prepare_env() {
  log_info "准备环境..."

  # 创建运行用户
  if ! id ${RUN_USER} >/dev/null 2>&1; then
    useradd -m -s /bin/bash ${RUN_USER}
    log_info "创建用户 ${RUN_USER}"
  fi

  # 创建目录
  mkdir -p ${DATA_DIR}/{logs,store,controller}
  mkdir -p ${INSTALL_DIR}
  chown -R ${RUN_USER}:${RUN_USER} ${DATA_DIR} ${INSTALL_DIR}

  # 检查 Java
  if [ ! -d "${JAVA_HOME}" ]; then
    log_error "JAVA_HOME ${JAVA_HOME} 不存在，请先安装 JDK 21"
    exit 1
  fi

  # 检查安装包
  if [ ! -f "${PACKAGE_DIR}/${ZIP_FILE}" ]; then
    log_error "安装包不存在: ${PACKAGE_DIR}/${ZIP_FILE}"
    exit 1
  fi
}

# ============================================================
# 安装 RocketMQ
# ============================================================

install_rocketmq() {
  log_info "安装 RocketMQ 5.4.0..."

  # 清理旧安装（保留数据目录）
  rm -rf ${INSTALL_DIR}/*

  # 解压
  unzip -q -o ${PACKAGE_DIR}/${ZIP_FILE} -d /tmp/
  mv /tmp/rocketmq-all-5.4.0-bin-release/* ${INSTALL_DIR}/
  rm -rf /tmp/rocketmq-all-5.4.0-bin-release

  # 设置权限
  chown -R ${RUN_USER}:${RUN_USER} ${INSTALL_DIR}

  # 注入 JAVA_HOME
  for script in runserver.sh runbroker.sh mqadmin.sh; do
    if [ -f "${INSTALL_DIR}/bin/${script}" ]; then
      if ! grep -q "JAVA_HOME=${JAVA_HOME}" ${INSTALL_DIR}/bin/${script}; then
        sed -i "1i export JAVA_HOME=${JAVA_HOME}" ${INSTALL_DIR}/bin/${script}
      fi
    fi
  done

  # 调整 JVM 参数（生产环境根据内存调整）
  # NameServer: 1G
  sed -i 's/-Xms[0-9]*[mgMG] -Xmx[0-9]*[mgMG]/-Xms1g -Xmx1g/g' ${INSTALL_DIR}/bin/runserver.sh 2>/dev/null || true
  sed -i 's/-Xmn[0-9]*[mgMG]/-Xmn512m/g' ${INSTALL_DIR}/bin/runserver.sh 2>/dev/null || true

  # Broker: 4G
  sed -i 's/-Xms[0-9]*[mgMG] -Xmx[0-9]*[mgMG]/-Xms4g -Xmx4g/g' ${INSTALL_DIR}/bin/runbroker.sh 2>/dev/null || true
  sed -i 's/-Xmn[0-9]*[mgMG]/-Xmn2g/g' ${INSTALL_DIR}/bin/runbroker.sh 2>/dev/null || true

  log_info "RocketMQ 安装完成"
}

# ============================================================
# 生成 NameServer 配置
# ============================================================

configure_nameserver() {
  log_info "配置 NameServer..."

  mkdir -p ${INSTALL_DIR}/conf

  cat > ${INSTALL_DIR}/conf/namesrv.conf <<'EOF'
listenPort=9876
EOF

  chown ${RUN_USER}:${RUN_USER} ${INSTALL_DIR}/conf/namesrv.conf
}

# ============================================================
# 生成 Broker 配置（固定角色）
# ============================================================

configure_broker() {
  local broker_name=$1      # 如: broker-a
  local broker_role=$2      # ASYNC_MASTER 或 SLAVE
  local broker_id=$3        # 0 或 1
  local listen_port=$4      # 10911 或 10921
  local ha_port=$((listen_port + 1))
  local data_subdir=$5      # 数据子目录名

  local broker_dir="${INSTALL_DIR}/${broker_name}"
  local data_dir="${DATA_DIR}/store/${data_subdir}"

  log_info "配置 Broker: ${broker_name} (角色: ${broker_role}, 端口: ${listen_port})"

  mkdir -p ${broker_dir}/conf
  mkdir -p ${data_dir}/{commitlog,consumequeue,index}

  cat > ${broker_dir}/conf/broker.conf <<EOF
# ==========================================
# Broker 基础配置
# ==========================================
brokerClusterName=DefaultCluster
brokerName=${broker_name}
brokerId=${broker_id}
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
fileReservedTime=72
mapedFileSizeCommitLog=1073741824
mapedFileSizeConsumeQueue=300000
diskMaxUsedSpaceRatio=85
maxMessageSize=4194304

# ==========================================
# 刷盘策略（异步刷盘，同步复制）
# ==========================================
flushDiskType=ASYNC_FLUSH
brokerRole=${broker_role}

# 同步复制配置（Master 生效）
haSendHeartbeatInterval=5000
haHousekeepingInterval=20000
haTransferBatchSize=32768
haSlaveFallbehindMax=268435456

# ==========================================
# 消息配置（禁用自动创建）
# ==========================================
autoCreateTopicEnable=false
autoCreateSubscriptionGroup=false
defaultTopicQueueNums=8
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
enableTrace=true
traceTopicName=RMQ_SYS_TRACE_TOPIC
longPollingEnable=true
notifyConsumerIdsChangedEnable=true
enablePropertyFilter=false

# 延迟消息级别
messageDelayLevel=1s 5s 10s 30s 1m 2m 3m 4m 5m 6m 7m 8m 9m 10m 20m 30m 1h 2h
EOF

  chown -R ${RUN_USER}:${RUN_USER} ${broker_dir} ${data_dir}
}

# ============================================================
# 根据当前节点配置对应的 Master 和 Slave
# ============================================================

configure_brokers() {
  case $CURRENT_NODE in
    node1)
      # Master-A (本节点主) + Slave-C (node3 的从)
      configure_broker "broker-a" "ASYNC_MASTER" 0 10911 "broker-a"
      configure_broker "broker-c" "SLAVE"       1 10921 "broker-c-slave"
      ;;
    node2)
      # Master-B (本节点主) + Slave-A (node1 的从)
      configure_broker "broker-b" "ASYNC_MASTER" 0 10911 "broker-b"
      configure_broker "broker-a" "SLAVE"       1 10921 "broker-a-slave"
      ;;
    node3)
      # Master-C (本节点主) + Slave-B (node2 的从)
      configure_broker "broker-c" "ASYNC_MASTER" 0 10911 "broker-c"
      configure_broker "broker-b" "SLAVE"       1 10921 "broker-b-slave"
      ;;
  esac
}

# ============================================================
# 生成 tools.yml（mqadmin 认证）
# ============================================================

configure_tools() {
  log_info "配置管理工具认证..."

  mkdir -p ${INSTALL_DIR}/conf

  cat > ${INSTALL_DIR}/conf/tools.yml <<EOF
accessKey: ${MQ_USER}
secretKey: ${MQ_PASSWORD}
EOF

  chown ${RUN_USER}:${RUN_USER} ${INSTALL_DIR}/conf/tools.yml
}

# ============================================================
# 生成 Systemd 服务
# ============================================================

create_systemd_services() {
  log_info "创建 Systemd 服务..."

  # --- NameServer 服务 ---
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
LimitNOFILE=655350
StandardOutput=append:${DATA_DIR}/logs/namesrv.log
StandardError=append:${DATA_DIR}/logs/namesrv-error.log

[Install]
WantedBy=multi-user.target
EOF

  # --- Broker 服务（根据当前节点）---
  case $CURRENT_NODE in
    node1)
      _create_broker_service "broker-a" 10911 "ASYNC_MASTER"
      _create_broker_service "broker-c" 10921 "SLAVE"
      ;;
    node2)
      _create_broker_service "broker-b" 10911 "ASYNC_MASTER"
      _create_broker_service "broker-a" 10921 "SLAVE"
      ;;
    node3)
      _create_broker_service "broker-c" 10911 "ASYNC_MASTER"
      _create_broker_service "broker-b" 10921 "SLAVE"
      ;;
  esac

  systemctl daemon-reload
}

_create_broker_service() {
  local broker_name=$1
  local port=$2
  local role=$3

  cat > /etc/systemd/system/rocketmq-${broker_name}.service <<EOF
[Unit]
Description=RocketMQ Broker ${broker_name} (${role})
After=network.target rocketmq-namesrv.service
Wants=rocketmq-namesrv.service

[Service]
User=${RUN_USER}
Group=${RUN_USER}
Environment="JAVA_HOME=${JAVA_HOME}"
Environment="ROCKETMQ_HOME=${INSTALL_DIR}"
Type=simple
ExecStart=${INSTALL_DIR}/bin/mqbroker -c ${INSTALL_DIR}/${broker_name}/conf/broker.conf
ExecStop=/bin/kill -s TERM \$MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=655350
StandardOutput=append:${DATA_DIR}/logs/${broker_name}.log
StandardError=append:${DATA_DIR}/logs/${broker_name}-error.log

[Install]
WantedBy=multi-user.target
EOF
}

# ============================================================
# 防火墙配置
# ============================================================

configure_firewall() {
  log_info "配置防火墙..."

  if systemctl is-active --quiet firewalld; then
    for port in ${NS_PORT} 10911 10912 10921 10922; do
      firewall-cmd --add-port=${port}/tcp --permanent 2>/dev/null || true
    done
    firewall-cmd --reload 2>/dev/null || true
    log_info "防火墙端口已开放"
  else
    log_warn "firewalld 未运行，请手动开放端口: ${NS_PORT}, 10911-10912, 10921-10922"
  fi
}

# ============================================================
# 启动服务
# ============================================================

start_services() {
  log_info "启动服务..."

  # 先启动 NameServer
  systemctl enable rocketmq-namesrv
  systemctl restart rocketmq-namesrv
  log_info "NameServer 已启动"

  # 等待 NameServer 就绪
  sleep 5

  # 启动 Broker（先 Master 后 Slave）
  case $CURRENT_NODE in
    node1)
      systemctl enable rocketmq-broker-a && systemctl restart rocketmq-broker-a
      sleep 3
      systemctl enable rocketmq-broker-c && systemctl restart rocketmq-broker-c
      ;;
    node2)
      systemctl enable rocketmq-broker-b && systemctl restart rocketmq-broker-b
      sleep 3
      systemctl enable rocketmq-broker-a && systemctl restart rocketmq-broker-a
      ;;
    node3)
      systemctl enable rocketmq-broker-c && systemctl restart rocketmq-broker-c
      sleep 3
      systemctl enable rocketmq-broker-b && systemctl restart rocketmq-broker-b
      ;;
  esac

  log_info "Broker 已启动"
}

# ============================================================
# 健康检查
# ============================================================

health_check() {
  log_info "执行健康检查..."
  sleep 10

  echo ""
  echo "========== 服务状态 =========="
  systemctl is-active rocketmq-namesrv >/dev/null 2>&1 && \
    log_info "NameServer: 运行中" || log_error "NameServer: 未运行"

  case $CURRENT_NODE in
    node1)
      systemctl is-active rocketmq-broker-a >/dev/null 2>&1 && \
        log_info "Broker-A (Master): 运行中" || log_error "Broker-A (Master): 未运行"
      systemctl is-active rocketmq-broker-c >/dev/null 2>&1 && \
        log_info "Broker-C (Slave): 运行中" || log_error "Broker-C (Slave): 未运行"
      ;;
    node2)
      systemctl is-active rocketmq-broker-b >/dev/null 2>&1 && \
        log_info "Broker-B (Master): 运行中" || log_error "Broker-B (Master): 未运行"
      systemctl is-active rocketmq-broker-a >/dev/null 2>&1 && \
        log_info "Broker-A (Slave): 运行中" || log_error "Broker-A (Slave): 未运行"
      ;;
    node3)
      systemctl is-active rocketmq-broker-c >/dev/null 2>&1 && \
        log_info "Broker-C (Master): 运行中" || log_error "Broker-C (Master): 未运行"
      systemctl is-active rocketmq-broker-b >/dev/null 2>&1 && \
        log_info "Broker-B (Slave): 运行中" || log_error "Broker-B (Slave): 未运行"
      ;;
  esac

  echo ""
  echo "========== 端口监听 =========="
  ss -tlnp 2>/dev/null | grep -E ":${NS_PORT}|:10911|:10912|:10921|:10922" || \
    netstat -tlnp 2>/dev/null | grep -E ":${NS_PORT}|:10911|:10912|:10921|:10922" || \
    log_warn "无法检测端口，请手动检查"

  echo ""
  echo "========== 集群列表 =========="
  ${INSTALL_DIR}/bin/mqadmin clusterList -n "${NAMESRV_ADDR}" -a "${MQ_USER}:${MQ_PASSWORD}" 2>/dev/null || \
    log_warn "集群列表获取失败，服务可能尚未完全注册"
}

# ============================================================
# 部署信息汇总
# ============================================================

print_summary() {
  echo ""
  echo "============================================================"
  echo "  RocketMQ 5.4.0 固定 3 主 3 从集群部署完成"
  echo "============================================================"
  echo ""
  echo "  当前节点: ${CURRENT_NODE} (${SERVER_IP})"
  echo ""
  echo "  本节点 Broker:"
  case $CURRENT_NODE in
    node1)
      echo "    - broker-a (Master) @ ${SERVER_IP}:10911"
      echo "    - broker-c (Slave)  @ ${SERVER_IP}:10921"
      ;;
    node2)
      echo "    - broker-b (Master) @ ${SERVER_IP}:10911"
      echo "    - broker-a (Slave)  @ ${SERVER_IP}:10921"
      ;;
    node3)
      echo "    - broker-c (Master) @ ${SERVER_IP}:10911"
      echo "    - broker-b (Slave)  @ ${SERVER_IP}:10921"
      ;;
  esac
  echo ""
  echo "  全局架构:"
  echo "    Master-A @ ${IP_1}:10911  <--  Slave-A @ ${IP_2}:10921"
  echo "    Master-B @ ${IP_2}:10911  <--  Slave-B @ ${IP_3}:10921"
  echo "    Master-C @ ${IP_3}:10911  <--  Slave-C @ ${IP_1}:10921"
  echo ""
  echo "  NameServer: ${NAMESRV_ADDR}"
  echo "  用户名:     ${MQ_USER}"
  echo "  密码:       ${MQ_PASSWORD}"
  echo ""
  echo "  常用命令:"
  echo "    查看集群:  mqadmin clusterList -n '${NAMESRV_ADDR}' -a '${MQ_USER}:${MQ_PASSWORD}'"
  echo "    查看 Topic: mqadmin topicList -n '${NAMESRV_ADDR}' -a '${MQ_USER}:${MQ_PASSWORD}'"
  echo "    创建 Topic: mqadmin updateTopic -n '${NAMESRV_ADDR}' -a '${MQ_USER}:${MQ_PASSWORD}' -c DefaultCluster -t TestTopic"
  echo ""
  echo "  ⚠️  autoCreateTopicEnable=false，使用前必须手动创建 Topic"
  echo "============================================================"
}

# ============================================================
# 清理函数（--force-clean）
# ============================================================

force_clean() {
  log_warn "强制清理所有数据和服务..."

  # 停止服务
  systemctl stop rocketmq-namesrv 2>/dev/null || true
  systemctl stop rocketmq-broker-a 2>/dev/null || true
  systemctl stop rocketmq-broker-b 2>/dev/null || true
  systemctl stop rocketmq-broker-c 2>/dev/null || true

  # 禁用服务
  systemctl disable rocketmq-namesrv 2>/dev/null || true
  systemctl disable rocketmq-broker-a 2>/dev/null || true
  systemctl disable rocketmq-broker-b 2>/dev/null || true
  systemctl disable rocketmq-broker-c 2>/dev/null || true

  # 删除服务文件
  rm -f /etc/systemd/system/rocketmq-*.service
  systemctl daemon-reload

  # 删除安装目录
  rm -rf ${INSTALL_DIR}

  # 删除数据（可选：注释掉保留数据）
  rm -rf ${DATA_DIR}/store/*

  log_info "清理完成"
}

# ============================================================
# 主流程
# ============================================================

main() {
  echo "============================================================"
  echo "  RocketMQ 5.4.0 固定 3 主 3 从集群部署"
  echo "  当前节点: ${CURRENT_NODE} (${SERVER_IP})"
  echo "============================================================"

  if [ "${1:-}" == "--force-clean" ]; then
    force_clean
    exit 0
  fi

  prepare_env
  install_rocketmq
  configure_nameserver
  configure_brokers
  configure_tools
  create_systemd_services
  configure_firewall
  start_services
  health_check
  print_summary
}

main "$@"