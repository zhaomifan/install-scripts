#!/bin/bash
# ==================================================
# RocketMQ 集群服务重启脚本（宕机恢复专用）
# 功能：仅启动服务，不删除任何数据
# 适用场景：机器重启、宕机恢复、服务异常停止
# ==================================================

# -------------- 配置区（与部署脚本保持一致） --------------
INSTALL_DIR="/ncpsmw/rocketmq_cluster"
DATA_DIR="/ncpsdata/rocketmq_cluster"
SERVICE_NAME="rocketmq-cluster"
JAVA_HOME="/ncpsmw/jdk21"
RUN_USER="rocketmq"

# 集群节点IP
IP_1="192.168.15.80"
IP_2="192.168.15.84"
IP_3="192.168.15.98"

# 端口配置
NS_PORT=9876
MASTER_PORT=10921
SLAVE_PORT=10931

# 用户认证
MQ_USER="rocketmq"
MQ_PASSWORD="ncps@2026"

# ==================================================
# 1. 获取本机IP并判断节点角色
# ==================================================
SERVER_IP=$(hostname -I | awk '{print $1}')

# 判断节点角色（仅用于显示信息）
if [ "$SERVER_IP" == "$IP_1" ]; then
    M_NAME="broker-a"
    S_NAME="broker-b"
    NODE_TYPE="Master: ${M_NAME}, Slave: ${S_NAME}"
elif [ "$SERVER_IP" == "$IP_2" ]; then
    M_NAME="broker-b"
    S_NAME="broker-c"
    NODE_TYPE="Master: ${M_NAME}, Slave: ${S_NAME}"
elif [ "$SERVER_IP" == "$IP_3" ]; then
    M_NAME="broker-c"
    S_NAME="broker-a"
    NODE_TYPE="Master: ${M_NAME}, Slave: ${S_NAME}"
else
    echo "⚠️  警告：本机IP $SERVER_IP 未在集群列表中配置"
    echo "继续尝试启动服务，但请确认配置是否正确..."
    NODE_TYPE="未知节点"
fi

NAMESRV_ADDR="${IP_1}:${NS_PORT};${IP_2}:${NS_PORT};${IP_3}:${NS_PORT}"

echo "=================================================="
echo "RocketMQ 集群服务重启脚本"
echo "=================================================="
echo "本机IP: ${SERVER_IP}"
echo "节点角色: ${NODE_TYPE}"
echo "NameServer地址: ${NAMESRV_ADDR}"
echo "当前时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=================================================="

# ==================================================
# 2. 检查环境
# ==================================================
echo ""
echo "=== 1. 环境检查 ==="

# 检查安装目录
if [ ! -d "${INSTALL_DIR}" ]; then
    echo "❌ 错误：安装目录 ${INSTALL_DIR} 不存在！"
    echo "请先执行部署脚本完成安装。"
    exit 1
fi
echo "✅ 安装目录存在: ${INSTALL_DIR}"

# 检查数据目录
if [ ! -d "${DATA_DIR}" ]; then
    echo "⚠️  警告：数据目录 ${DATA_DIR} 不存在，将自动创建"
    mkdir -p ${DATA_DIR}
    chown -R ${RUN_USER}:${RUN_USER} ${DATA_DIR}
else
    echo "✅ 数据目录存在: ${DATA_DIR}"
fi

# 检查Java环境
if [ ! -d "${JAVA_HOME}" ]; then
    echo "❌ 错误：JAVA_HOME ${JAVA_HOME} 不存在！"
    exit 1
fi
echo "✅ JAVA_HOME: ${JAVA_HOME}"

# 检查用户
if ! id ${RUN_USER} >/dev/null 2>&1; then
    echo "⚠️  用户 ${RUN_USER} 不存在，正在创建..."
    useradd -m -s /bin/bash ${RUN_USER}
fi
echo "✅ 用户 ${RUN_USER} 存在"

# 检查配置文件
CONF_FILES=("namesrv.conf" "master.conf" "slave.conf")
for file in "${CONF_FILES[@]}"; do
    if [ ! -f "${INSTALL_DIR}/conf/${file}" ]; then
        echo "❌ 错误：配置文件 ${INSTALL_DIR}/conf/${file} 不存在！"
        exit 1
    fi
done
echo "✅ 配置文件完整"

# ==================================================
# 3. 停止现有服务（如果正在运行）
# ==================================================
echo ""
echo "=== 2. 停止现有服务 ==="

# 检查服务状态
if systemctl is-active --quiet ${SERVICE_NAME} 2>/dev/null; then
    echo "服务正在运行，准备停止..."
    systemctl stop ${SERVICE_NAME}
    sleep 3
    echo "✅ 服务已停止"
else
    echo "服务未运行，跳过停止操作"
fi

# 额外清理可能残留的进程（避免端口冲突）
echo "检查残留进程..."
PIDS=$(ps aux | grep -E "mqnamesrv|mqbroker" | grep -v grep | awk '{print $2}' 2>/dev/null)
if [ -n "$PIDS" ]; then
    echo "发现残留进程，正在清理..."
    for pid in $PIDS; do
        kill -9 $pid 2>/dev/null || true
        echo "  - 已终止进程: $pid"
    done
    sleep 2
else
    echo "✅ 无残留进程"
fi

# 检查端口是否释放
echo "检查端口状态..."
for port in ${NS_PORT} ${MASTER_PORT} ${SLAVE_PORT}; do
    if ss -tlnp | grep -q ":${port} "; then
        echo "⚠️  端口 ${port} 仍被占用，尝试强制释放..."
        PID=$(ss -tlnp | grep ":${port} " | awk '{print $7}' | cut -d'=' -f2 | cut -d',' -f1)
        if [ -n "$PID" ]; then
            kill -9 $PID 2>/dev/null || true
            echo "  - 已终止占用端口 ${port} 的进程: $PID"
        fi
    else
        echo "  - 端口 ${port} 空闲"
    fi
done

# ==================================================
# 4. 检查并修复数据目录权限
# ==================================================
echo ""
echo "=== 3. 检查数据目录权限 ==="
mkdir -p ${DATA_DIR}/logs
chown -R ${RUN_USER}:${RUN_USER} ${DATA_DIR}
chmod -R 755 ${DATA_DIR}
echo "✅ 数据目录权限已修复"

# ==================================================
# 5. 启动服务
# ==================================================
echo ""
echo "=== 4. 启动服务 ==="

# 重新加载systemd配置
systemctl daemon-reload

# 启用服务（确保开机自启）
systemctl enable ${SERVICE_NAME} 2>/dev/null || true

# 启动服务
echo "正在启动 ${SERVICE_NAME} 服务..."
systemctl start ${SERVICE_NAME}

# 等待服务启动
echo "等待服务启动..."
sleep 5

# ==================================================
# 6. 验证服务状态
# ==================================================
echo ""
echo "=== 5. 验证服务状态 ==="

# 检查systemd服务状态
if systemctl is-active --quiet ${SERVICE_NAME}; then
    echo "✅ 服务状态: 运行中"
else
    echo "❌ 服务状态: 未运行"
    echo ""
    echo "查看错误日志:"
    echo "  tail -50 ${DATA_DIR}/logs/ns.log"
    echo "  tail -50 ${DATA_DIR}/logs/m.log"
    echo "  tail -50 ${DATA_DIR}/logs/s.log"
    exit 1
fi

# 检查进程
echo ""
echo "进程状态:"
ps aux | grep -E "mqnamesrv|mqbroker" | grep -v grep || echo "⚠️  未找到 RocketMQ 进程"

# 检查端口
echo ""
echo "端口监听状态:"
for port in ${NS_PORT} ${MASTER_PORT} ${SLAVE_PORT}; do
    if ss -tlnp | grep -q ":${port} "; then
        echo "  ✅ 端口 ${port} 已监听"
    else
        echo "  ❌ 端口 ${port} 未监听"
    fi
done

# ==================================================
# 7. 功能验证（可选）
# ==================================================
echo ""
echo "=== 6. 功能验证 ==="

# 检查NameServer是否可访问
echo "检查NameServer连通性..."
if timeout 3 telnet ${SERVER_IP} ${NS_PORT} </dev/null 2>/dev/null; then
    echo "  ✅ NameServer ${SERVER_IP}:${NS_PORT} 可访问"
else
    echo "  ⚠️  NameServer ${SERVER_IP}:${NS_PORT} 可能未就绪"
fi

# 尝试执行mqadmin命令验证
echo ""
echo "执行集群状态检查..."
export JAVA_HOME=${JAVA_HOME}
export ROCKETMQ_HOME=${INSTALL_DIR}

if [ -f "${INSTALL_DIR}/conf/tools.yml" ]; then
    # 使用工具验证（如果有tools.yml配置）
    timeout 10 ${INSTALL_DIR}/bin/mqadmin clusterList -n "${NAMESRV_ADDR}" 2>/dev/null || echo "  ⚠️  集群列表查询超时，请稍后手动验证"
else
    echo "  ⚠️  tools.yml 不存在，跳过管理命令验证"
fi

# ==================================================
# 8. 输出结果
# ==================================================
echo ""
echo "=================================================="
echo "✅ RocketMQ 集群服务重启完成！"
echo "=================================================="
echo "服务名称: ${SERVICE_NAME}"
echo "NameServer端口: ${NS_PORT}"
echo "Master端口: ${MASTER_PORT}"
echo "Slave端口: ${SLAVE_PORT}"
echo ""
echo "日志位置: ${DATA_DIR}/logs/"
echo "  - NameServer日志: ${DATA_DIR}/logs/ns.log"
echo "  - Master日志: ${DATA_DIR}/logs/m.log"
echo "  - Slave日志: ${DATA_DIR}/logs/s.log"
echo ""
echo "验证命令:"
echo "  systemctl status ${SERVICE_NAME}"
echo "  sh ${INSTALL_DIR}/bin/mqadmin clusterList -n \"${NAMESRV_ADDR}\""
echo ""
echo "业务连接账号:"
echo "  accessKey: ${MQ_USER}"
echo "  secretKey: ${MQ_PASSWORD}"
echo "=================================================="

# 如果有错误，提示查看日志
if ! systemctl is-active --quiet ${SERVICE_NAME}; then
    echo ""
    echo "⚠️  服务启动失败，请查看日志:"
    echo "  tail -100 ${DATA_DIR}/logs/ns.log"
    echo "  tail -100 ${DATA_DIR}/logs/m.log"
    echo "  tail -100 ${DATA_DIR}/logs/s.log"
    exit 1
fi

exit 0