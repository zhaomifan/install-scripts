#!/bin/bash
# ==================================================
# RocketMQ 主从切换脚本 (基于10931端口)
# 文件名: switch_broker_10931.sh
# ==================================================

# -------------- 配置区 --------------
INSTALL_DIR="/ncpsmw/rocketmq_cluster"
DATA_DIR="/ncpsdata/rocketmq_cluster"
JAVA_HOME="/ncpsmw/jdk21"
MQ_USER="rocketmq"
MQ_PASSWORD="ncps@2026"
NS_PORT=9876

# 集群节点IP
IP_1="192.168.15.80"
IP_2="192.168.15.84"
IP_3="192.168.15.98"

# 获取本机IP
LOCAL_IP=$(hostname -I | awk '{print $1}')

# NameServer地址
NAMESRV_ADDR="${IP_1}:${NS_PORT};${IP_2}:${NS_PORT};${IP_3}:${NS_PORT}"

# -------------- 函数定义 --------------
get_node() {
    case $1 in
        $IP_1) echo "a" ;;
        $IP_2) echo "b" ;;
        $IP_3) echo "c" ;;
        *) echo "unknown" ;;
    esac
}

get_slave_broker() {
    case $1 in
        "a") echo "broker-b" ;;
        "b") echo "broker-c" ;;
        "c") echo "broker-a" ;;
    esac
}

show_status() {
    echo ""
    echo "=================================================="
    echo "集群状态"
    echo "=================================================="
    ${INSTALL_DIR}/bin/mqadmin clusterList -n "${NAMESRV_ADDR}" 2>/dev/null || echo "无法获取集群状态，请检查NameServer"
    echo ""
    echo "=================================================="
    echo "本地Broker进程:"
    echo "=================================================="
    # 使用更精确的匹配方式
    ps -ef | grep -E "org.apache.rocketmq.broker.BrokerStartup" | grep -v grep
    if [ $? -ne 0 ]; then
        echo "未找到Broker进程"
    fi
    echo ""
    echo "端口监听状态:"
    echo "----------------------------------------"
    netstat -tlnp | grep -E "10921|10931" | grep -v grep
    if [ $? -ne 0 ]; then
        echo "未找到监听端口"
    fi
    echo ""
}

show_help() {
    echo "=================================================="
    echo "RocketMQ 主从切换工具 (基于10931端口)"
    echo "=================================================="
    echo ""
    echo "用法: ./broker_10931_switch.sh [参数]"
    echo ""
    echo "参数说明:"
    echo "  提升     - 将本地从节点提升为主节点 (故障转移)"
    echo "  恢复     - 将本地从节点恢复为从节点 (故障恢复)"
    echo "  状态     - 显示集群状态"
    echo "  交互     - 进入交互式菜单模式"
    echo "  帮助     - 显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  ./broker_10931_switch.sh 提升    # 故障转移"
    echo "  ./broker_10931_switch.sh 恢复    # 故障恢复"
    echo "  ./broker_10931_switch.sh 状态    # 查看状态"
    echo "  ./broker_10931_switch.sh 交互    # 交互式菜单"
    echo ""
}

# -------------- 主程序开始 --------------
# 如果没有参数，默认进入交互模式
if [ $# -eq 0 ]; then
    ACTION="交互"
else
    ACTION=$1
fi

# 确定本机节点
LOCAL_NODE=$(get_node $LOCAL_IP)

case $ACTION in
    交互)
        # 检查本机IP是否在集群中
        if [ "$LOCAL_NODE" == "unknown" ]; then
            echo "错误：本机IP不在集群节点列表中"
            echo "本机IP: $LOCAL_IP"
            exit 1
        fi
        
        # 获取本机的主从信息
        LOCAL_MASTER="broker-${LOCAL_NODE}"
        LOCAL_SLAVE=$(get_slave_broker $LOCAL_NODE)
        
        echo "=================================================="
        echo "RocketMQ 主从切换工具"
        echo "=================================================="
        echo "本机IP: $LOCAL_IP"
        echo "本机节点: $LOCAL_NODE"
        echo "本机主节点: $LOCAL_MASTER (端口10921)"
        echo "本机从节点: $LOCAL_SLAVE (端口10931)"
        echo ""
        
        # 显示当前运行状态
        echo "当前Broker运行状态:"
        if ps -ef | grep "master.conf" | grep -v grep > /dev/null; then
            echo "  [运行中] 主节点 (10921)"
        else
            echo "  [未运行] 主节点 (10921)"
        fi
        
        if ps -ef | grep "slave.conf" | grep -v grep > /dev/null; then
            echo "  [运行中] 从节点 (10931)"
        else
            echo "  [未运行] 从节点 (10931)"
        fi
        echo ""
        
        # 显示菜单
        echo "请选择操作:"
        echo "  1) 将从节点提升为主节点 (故障转移)"
        echo "  2) 将从节点恢复为从节点 (故障恢复)"
        echo "  3) 查看集群状态"
        echo "  4) 退出"
        read -p "请输入选择 [1-4]: " MENU_CHOICE
        
        case $MENU_CHOICE in
            1)
                ACTION="提升"
                ;;
            2)
                ACTION="恢复"
                ;;
            3)
                show_status
                exit 0
                ;;
            4)
                echo "退出"
                exit 0
                ;;
            *)
                echo "无效选择"
                exit 1
                ;;
        esac
        ;;
esac

# 实际执行操作
case $ACTION in
    提升)
        # 检查本机IP是否在集群中
        if [ "$LOCAL_NODE" == "unknown" ]; then
            echo "错误：本机IP不在集群节点列表中"
            echo "本机IP: $LOCAL_IP"
            exit 1
        fi
        
        LOCAL_SLAVE=$(get_slave_broker $LOCAL_NODE)
        
        echo ""
        echo "=================================================="
        echo "故障转移：将从节点提升为主节点"
        echo "=================================================="
        echo "正在将 ${LOCAL_SLAVE} 提升为主节点..."
        echo ""
        
        # 停止从节点
        echo "1. 停止从节点 (10931)..."
        # 使用更精确的进程查找
        SLAVE_PID=$(ps -ef | grep "slave.conf" | grep -v grep | grep "BrokerStartup" | awk '{print $2}')
        if [ -n "$SLAVE_PID" ]; then
            echo "   找到进程PID: $SLAVE_PID"
            kill $SLAVE_PID
            sleep 3
            # 检查是否还在运行
            if ps -p $SLAVE_PID > /dev/null 2>&1; then
                kill -9 $SLAVE_PID
                echo "   强制停止"
            fi
            # 清理残留
            pkill -f "slave.conf" 2>/dev/null || true
            echo "   [完成] 从节点已停止"
        else
            echo "   [警告] 从节点未运行"
        fi
        
        # 修改配置为主节点
        echo ""
        echo "2. 修改配置为主节点..."
        # 备份配置
        if [ -f ${INSTALL_DIR}/conf/slave.conf ]; then
            cp ${INSTALL_DIR}/conf/slave.conf ${INSTALL_DIR}/conf/slave.conf.备份.$(date +%Y%m%d_%H%M%S)
        fi
        
        # 修改配置
        sed -i 's/brokerId=1/brokerId=0/' ${INSTALL_DIR}/conf/slave.conf 2>/dev/null
        sed -i 's/brokerRole=SLAVE/brokerRole=ASYNC_MASTER/' ${INSTALL_DIR}/conf/slave.conf 2>/dev/null
        echo "   [完成] 配置已修改"
        
        # 启动为主节点
        echo ""
        echo "3. 启动 ${LOCAL_SLAVE} 作为主节点..."
        export JAVA_HOME=${JAVA_HOME}
        export ROCKETMQ_HOME=${INSTALL_DIR}
        nohup ${INSTALL_DIR}/bin/mqbroker -c ${INSTALL_DIR}/conf/slave.conf > ${DATA_DIR}/logs/${LOCAL_SLAVE}-主节点.log 2>&1 &
        
        sleep 5
        
        # 验证
        NEW_PID=$(ps -ef | grep "slave.conf" | grep -v grep | grep "BrokerStartup" | awk '{print $2}')
        if [ -n "$NEW_PID" ]; then
            echo ""
            echo "=================================================="
            echo "[成功] 故障转移完成！"
            echo "  ${LOCAL_SLAVE} 现在作为主节点运行在端口 10931"
            echo "  进程ID: $NEW_PID"
            echo ""
            echo "验证命令："
            echo "  ${INSTALL_DIR}/bin/mqadmin clusterList -n \"${NAMESRV_ADDR}\""
            echo "=================================================="
        else
            echo "[错误] 启动失败"
            echo "请查看日志: ${DATA_DIR}/logs/${LOCAL_SLAVE}-主节点.log"
            exit 1
        fi
        ;;
        
    恢复)
        # 检查本机IP是否在集群中
        if [ "$LOCAL_NODE" == "unknown" ]; then
            echo "错误：本机IP不在集群节点列表中"
            echo "本机IP: $LOCAL_IP"
            exit 1
        fi
        
        LOCAL_SLAVE=$(get_slave_broker $LOCAL_NODE)
        
        echo ""
        echo "=================================================="
        echo "故障恢复：将从节点恢复为从节点"
        echo "=================================================="
        echo "正在将 ${LOCAL_SLAVE} 恢复为从节点..."
        echo ""
        
        # 停止已提升的主节点
        echo "1. 停止已提升的主节点 (10931)..."
        SLAVE_PID=$(ps -ef | grep "slave.conf" | grep -v grep | grep "BrokerStartup" | awk '{print $2}')
        if [ -n "$SLAVE_PID" ]; then
            echo "   找到进程PID: $SLAVE_PID"
            kill $SLAVE_PID
            sleep 3
            if ps -p $SLAVE_PID > /dev/null 2>&1; then
                kill -9 $SLAVE_PID
                echo "   强制停止"
            fi
            pkill -f "slave.conf" 2>/dev/null || true
            echo "   [完成] 已停止"
        else
            echo "   [警告] Broker未运行"
        fi
        
        # 恢复从节点配置
        echo ""
        echo "2. 修改配置为从节点..."
        sed -i 's/brokerId=0/brokerId=1/' ${INSTALL_DIR}/conf/slave.conf 2>/dev/null
        sed -i 's/brokerRole=ASYNC_MASTER/brokerRole=SLAVE/' ${INSTALL_DIR}/conf/slave.conf 2>/dev/null
        echo "   [完成] 配置已修改"
        
        # 启动为从节点
        echo ""
        echo "3. 启动 ${LOCAL_SLAVE} 作为从节点..."
        export JAVA_HOME=${JAVA_HOME}
        export ROCKETMQ_HOME=${INSTALL_DIR}
        nohup ${INSTALL_DIR}/bin/mqbroker -c ${INSTALL_DIR}/conf/slave.conf > ${DATA_DIR}/logs/${LOCAL_SLAVE}-从节点.log 2>&1 &
        
        sleep 5
        
        # 验证
        NEW_PID=$(ps -ef | grep "slave.conf" | grep -v grep | grep "BrokerStartup" | awk '{print $2}')
        if [ -n "$NEW_PID" ]; then
            echo ""
            echo "=================================================="
            echo "[成功] 故障恢复完成！"
            echo "  ${LOCAL_SLAVE} 现在作为从节点运行在端口 10931"
            echo "  进程ID: $NEW_PID"
            echo ""
            echo "验证命令："
            echo "  ${INSTALL_DIR}/bin/mqadmin clusterList -n \"${NAMESRV_ADDR}\""
            echo "=================================================="
        else
            echo "[错误] 启动失败"
            echo "请查看日志: ${DATA_DIR}/logs/${LOCAL_SLAVE}-从节点.log"
            exit 1
        fi
        ;;
        
    状态)
        show_status
        ;;
        
    帮助)
        show_help
        ;;
        
    *)
        echo "未知参数: $ACTION"
        echo ""
        show_help
        exit 1
        ;;
esac