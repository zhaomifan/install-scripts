#!/bin/bash
# ==================================================
# RocketMQ 5.4.0 DLedger Controller 3主3从 集群部署脚本（ACL 2.0）
# 架构：3个 Broker Group，每个 Group 2 副本（1主1从），共6节点
# 修正版：启用 enableControllerMode，删除硬编码 brokerId/brokerRole，实现 Controller 自动选主
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
CONTROLLER_PORT=9091          # Controller Raft 端口

# ==================================================
# 3主3从 Group 规划 (每个Group 2副本)
# ==================================================
# Group-A: 副本在 node1(10911) + node2(10921)
# Group-B: 副本在 node2(10911) + node3(10921)
# Group-C: 副本在 node3(10911) + node1(10921)
# 注意：同一 Group 内的两个节点由 Controller 选举决定谁是 Master

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

    # 清理旧安装（保留数据目录，除非带 --force-clean）
    rm -rf ${INSTALL_DIR}/*
    unzip -o ${ZIP_FILE} -d /tmp/ >/dev/null
    mv /tmp/rocketmq-all-5.4.0-bin-release/* ${INSTALL_DIR}/
    rm -rf /tmp/rocketmq-all-5.4.0-bin-release

    chown -R ${RUN_USER}:${RUN_USER} ${INSTALL_DIR}

    # 配置 JAVA_HOME
    sed -i "1i export JAVA_HOME=${JAVA_HOME}" ${INSTALL_DIR}/bin/runserver.sh
    sed -i "1i export JAVA_HOME=${JAVA_HOME}" ${INSTALL_DIR}/bin/runbroker.sh

    # JVM 配置
    sed -i '/JAVA_OPT="\${JAVA_OPT} -server -Xms.*"/d' ${INSTALL_DIR}/bin/runserver.sh
    sed -i '/JAVA_OPT="\${JAVA_OPT}"/a JAVA_OPT="${JAVA_OPT} -server -Xms1g -Xmx1g -Xmn512m"' ${INSTALL_DIR}/bin/runserver.sh

    sed -i '/JAVA_OPT="\${JAVA_OPT} -server -Xms.*"/d' ${INSTALL_DIR}/bin/runbroker.sh
    sed -i '/JAVA_OPT="\${JAVA_OPT}"/a JAVA_OPT="${JAVA_OPT} -server -Xms4g -Xmx4g -Xmn2g"' ${INSTALL_DIR}/bin/runbroker.sh
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
controllerDLegerGroup=group1
controllerDLegerPeers=${CONTROLLER_PEERS}
controllerDLegerSelfId=${CONTROLLER_ID}
controllerPort=${CONTROLLER_PORT}
controllerStorePath=${DATA_DIR}/controller_data
enableElectUncleanMaster=false
notifyBrokerRoleChanged=true
EOF
}

# ==================================================
# 生成 Broker 配置文件 (Controller 模式)
# ==================================================
# 关键修正：
# 1. 删除 brokerId 和 brokerRole（由 Controller 动态分配）
# 2. 添加 enableControllerMode=true 和 controllerAddr
# 3. 删除 haMasterAddress（Slave 从 Controller 获取当前 Master）
# 4. 删除 enableDLedgerController/dLegerControllerAddr（5.x 废弃参数）
# ==================================================
configure_broker() {
    local node=$1
    local group_name=$2
    local listen_port=$3
    local ha_port=$((listen_port + 1))

    local broker_dir="${INSTALL_DIR}/${group_name}"
    local data_dir="${DATA_DIR}/store/${group_name}"

    echo "配置 Broker: ${group_name} (端口: ${listen_port})"

    mkdir -p ${broker_dir}/conf
    mkdir -p ${data_dir}/{commitlog,consumequeue,index}

    cat > ${broker_dir}/conf/broker.conf <<EOF
# ==========================================
# Broker 基础配置
# ==========================================
brokerClusterName=RocketMQ-Cluster
brokerName=${group_name}
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
# DLedger Controller 自动切换模式 (核心修正)
# ==========================================
# 总开关：启用 Controller 模式，自动主从切换
enableControllerMode=true
# Controller 集群地址（所有 Broker 配置一致）
controllerAddr=${IP_1}:${CONTROLLER_PORT};${IP_2}:${CONTROLLER_PORT};${IP_3}:${CONTROLLER_PORT}
# Epoch 文件存储路径（非常重要，不可删除）
storePathEpochFile=${data_dir}/epoch
# 同步 Broker 元数据到 Controller 的间隔
syncBrokerMetadataPeriod=5000
# 检查 SyncStateSet 的间隔
checkSyncStateSetPeriod=5000
# 同步 Controller 元数据的间隔
syncControllerMetadataPeriod=10000
# Slave 未跟上 Master 的最大时间间隔
haMaxTimeSlaveNotCatchup=15000
# 是否要求所有同步副本 ACK 后才返回成功（false=性能优先，true=强一致）
allAckInSyncStateSet=false
# 需保持同步的副本组数量
inSyncReplicas=1
# 最小需保持同步的副本组数量
minInSyncReplicas=1
# Slave 空盘启动时是否从最后一个文件复制
syncFromLastFile=false
# 是否为异步 Learner（不参与选主）
asyncLearner=false

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

    # 为当前节点创建 Broker 服务
    # node1: group-a (10911) + group-c (10921)
    # node2: group-b (10911) + group-a (10921)
    # node3: group-c (10911) + group-b (10921)

    local broker1_group=""
    local broker1_port=""
    local broker2_group=""
    local broker2_port=""

    case $CURRENT_NODE in
        node1)
            broker1_group="group-a"; broker1_port=10911
            broker2_group="group-c"; broker2_port=10921
            ;;
        node2)
            broker1_group="group-b"; broker1_port=10911
            broker2_group="group-a"; broker2_port=10921
            ;;
        node3)
            broker1_group="group-c"; broker1_port=10911
            broker2_group="group-b"; broker2_port=10921
            ;;
    esac

    # Broker 1 服务
    cat > /etc/systemd/system/rocketmq-broker-${broker1_group}.service <<EOF
[Unit]
Description=RocketMQ Broker ${broker1_group}
After=network.target rocketmq-namesrv.service rocketmq-controller.service
Wants=rocketmq-namesrv.service rocketmq-controller.service

[Service]
User=${RUN_USER}
Group=${RUN_USER}
Environment="JAVA_HOME=${JAVA_HOME}"
Environment="ROCKETMQ_HOME=${INSTALL_DIR}"
Type=simple
ExecStart=${INSTALL_DIR}/bin/mqbroker -c ${INSTALL_DIR}/${broker1_group}/conf/broker.conf
ExecStop=/bin/kill -s TERM \$MAINPID
Restart=on-failure
RestartSec=10
StandardOutput=append:${DATA_DIR}/logs/broker-${broker1_group}.log
StandardError=append:${DATA_DIR}/logs/broker-${broker1_group}-error.log

[Install]
WantedBy=multi-user.target
EOF

    # Broker 2 服务
    cat > /etc/systemd/system/rocketmq-broker-${broker2_group}.service <<EOF
[Unit]
Description=RocketMQ Broker ${broker2_group}
After=network.target rocketmq-namesrv.service rocketmq-controller.service
Wants=rocketmq-namesrv.service rocketmq-controller.service

[Service]
User=${RUN_USER}
Group=${RUN_USER}
Environment="JAVA_HOME=${JAVA_HOME}"
Environment="ROCKETMQ_HOME=${INSTALL_DIR}"
Type=simple
ExecStart=${INSTALL_DIR}/bin/mqbroker -c ${INSTALL_DIR}/${broker2_group}/conf/broker.conf
ExecStop=/bin/kill -s TERM \$MAINPID
Restart=on-failure
RestartSec=10
StandardOutput=append:${DATA_DIR}/logs/broker-${broker2_group}.log
StandardError=append:${DATA_DIR}/logs/broker-${broker2_group}-error.log

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
        # Broker 端口 (每个节点两个 Group)
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
    local broker1_group=""
    local broker2_group=""
    case $CURRENT_NODE in
        node1) broker1_group="group-a"; broker2_group="group-c" ;;
        node2) broker1_group="group-b"; broker2_group="group-a" ;;
        node3) broker1_group="group-c"; broker2_group="group-b" ;;
    esac

    systemctl enable rocketmq-broker-${broker1_group}
    systemctl enable rocketmq-broker-${broker2_group}

    systemctl start rocketmq-broker-${broker1_group}
    sleep 3
    systemctl start rocketmq-broker-${broker2_group}
}

# ==================================================
# 健康检查
# ==================================================
health_check() {
    echo "=== 健康检查 ==="
    sleep 15

    echo "--- 服务状态 ---"
    systemctl is-active rocketmq-namesrv && echo "✅ NameServer: 运行中" || echo "❌ NameServer: 未运行"
    systemctl is-active rocketmq-controller && echo "✅ Controller: 运行中" || echo "❌ Controller: 未运行"

    local broker1_group=""
    local broker2_group=""
    case $CURRENT_NODE in
        node1) broker1_group="group-a"; broker2_group="group-c" ;;
        node2) broker1_group="group-b"; broker2_group="group-a" ;;
        node3) broker1_group="group-c"; broker2_group="group-b" ;;
    esac

    systemctl is-active rocketmq-broker-${broker1_group} && echo "✅ Broker ${broker1_group}: 运行中" || echo "❌ Broker ${broker1_group}: 未运行"
    systemctl is-active rocketmq-broker-${broker2_group} && echo "✅ Broker ${broker2_group}: 运行中" || echo "❌ Broker ${broker2_group}: 未运行"

    echo "--- 端口监听 ---"
    ss -tlnp 2>/dev/null | grep -E "${NS_PORT}|${CONTROLLER_PORT}|10911|10921" || netstat -tlnp 2>/dev/null | grep -E "${NS_PORT}|${CONTROLLER_PORT}|10911|10921"

    echo "--- Controller 日志检查（Broker 注册情况）---"
    grep -i "broker\|register\|elect\|master" ${DATA_DIR}/logs/controller.log 2>/dev/null | tail -20 || echo "请手动检查 ${DATA_DIR}/logs/controller.log"

    echo "--- Broker 角色检查 ---"
    grep -i "brokerRole\|brokerId\|controller\|epoch" ${DATA_DIR}/logs/broker-*.log 2>/dev/null | tail -10 || echo "Broker 日志检查完成"
}

# ==================================================
# 输出部署信息
# ==================================================
print_summary() {
    local broker1_group=""
    local broker2_group=""
    local broker1_port=""
    local broker2_port=""
    case $CURRENT_NODE in
        node1) broker1_group="group-a"; broker1_port=10911; broker2_group="group-c"; broker2_port=10921 ;;
        node2) broker1_group="group-b"; broker1_port=10911; broker2_group="group-a"; broker2_port=10921 ;;
        node3) broker1_group="group-c"; broker1_port=10911; broker2_group="group-b"; broker2_port=10921 ;;
    esac

    echo ""
    echo "=================================================="
    echo "✅ RocketMQ 3主3从 集群节点部署完成！"
    echo "=================================================="
    echo "当前节点: ${CURRENT_NODE} (${SERVER_IP})"
    echo ""
    echo "--- 本节点 Broker 实例 ---"
    echo "  Broker 1: ${broker1_group} @ ${SERVER_IP}:${broker1_port} (角色由 Controller 选举决定)"
    echo "  Broker 2: ${broker2_group} @ ${SERVER_IP}:${broker2_port} (角色由 Controller 选举决定)"
    echo ""
    echo "--- 全局架构 ---"
    echo "  Group-A: 副本 @ ${IP_1}:10911 + ${IP_2}:10921"
    echo "  Group-B: 副本 @ ${IP_2}:10911 + ${IP_3}:10921"
    echo "  Group-C: 副本 @ ${IP_3}:10911 + ${IP_1}:10921"
    echo ""
    echo "--- Controller 自动切换说明 ---"
    echo "  每个 Group 内，Controller 会选举一个 Master，另一个为 Slave"
    echo "  当 Master 故障时，Controller 自动将 Slave 提升为 Master"
    echo "  新 Master 选举后，NameServer 路由自动更新，客户端无感知"
    echo ""
    echo "--- 连接信息 ---"
    echo "  NameServer: ${NAMESRV_ADDR}"
    echo "  Controller: ${CONTROLLER_PEERS}"
    echo "  Username:   ${MQ_USER}"
    echo "  Password:   ${MQ_PASSWORD}"
    echo ""
    echo "--- 验证命令 ---"
    echo "  查看集群列表: ${INSTALL_DIR}/bin/mqadmin clusterList -n \"${NAMESRV_ADDR}\" -a ${MQ_USER}:${MQ_PASSWORD}"
    echo "  查看 Topic 列表: ${INSTALL_DIR}/bin/mqadmin topicList -n \"${NAMESRV_ADDR}\" -a ${MQ_USER}:${MQ_PASSWORD}"
    echo "  查看 Broker 状态: ${INSTALL_DIR}/bin/mqadmin brokerStatus -b ${broker1_group} -n \"${NAMESRV_ADDR}\" -a ${MQ_USER}:${MQ_PASSWORD}"
    echo ""
    echo "--- 故障切换测试 ---"
    echo "  1. 在某节点执行: systemctl stop rocketmq-broker-<当前为master的group>"
    echo "  2. 等待 10-20 秒"
    echo "  3. 在另一节点查看: ${INSTALL_DIR}/bin/mqadmin clusterList -n \"${NAMESRV_ADDR}\" -a ${MQ_USER}:${MQ_PASSWORD}"
    echo "  4. 观察该 Group 的 Master 是否已切换到另一节点"
    echo "=================================================="
}

# ==================================================
# 主执行流程
# ==================================================
main() {
    echo "=== RocketMQ 3主3从 集群部署 (Controller 自动切换模式) ==="
    echo "节点: ${CURRENT_NODE} (${SERVER_IP})"

    # 如果带 --force-clean 参数，清理数据
    if [ "$1" == "--force-clean" ]; then
        echo "⚠️ 强制清理数据..."
        read -p "确认删除所有数据? [y/N]: " confirm
        if [ "$confirm" == "y" ] || [ "$confirm" == "Y" ]; then
            rm -rf ${DATA_DIR}/store/*
            rm -rf ${INSTALL_DIR}
            systemctl stop rocketmq-* 2>/dev/null || true
            rm -f /etc/systemd/system/rocketmq-*.service
            systemctl daemon-reload
            echo "✅ 数据已清理"
        else
            echo "取消清理"
            exit 0
        fi
    fi

    prepare_dirs
    install_rocketmq
    configure_nameserver
    configure_controller
    configure_tools

    # 配置当前节点的两个 Broker 实例
    case $CURRENT_NODE in
        node1)
            configure_broker "node1" "group-a" 10911
            configure_broker "node1" "group-c" 10921
            ;;
        node2)
            configure_broker "node2" "group-b" 10911
            configure_broker "node2" "group-a" 10921
            ;;
        node3)
            configure_broker "node3" "group-c" 10911
            configure_broker "node3" "group-b" 10921
            ;;
    esac

    create_systemd_services
    configure_firewall
    start_services
    health_check
    print_summary
}

main "$@"