# ==================================================
# 2. 清理旧的集群环境（增强版）
# ==================================================
echo "=== 清理旧集群环境 ==="

# 停止 Systemd 服务
systemctl stop ${SERVICE_NAME} 2>/dev/null || true
systemctl disable ${SERVICE_NAME} 2>/dev/null || true

# 强制杀掉所有 RocketMQ 进程（包括独立启动的）
echo "强制停止所有 RocketMQ 进程..."
pkill -f "mqnamesrv" 2>/dev/null || true
pkill -f "mqbroker" 2>/dev/null || true
pkill -f "NamesrvStartup" 2>/dev/null || true
pkill -f "BrokerStartup" 2>/dev/null || true

# 等待进程退出
sleep 3

# 再次确认并强制杀掉残留
ps aux | grep -E "mqnamesrv|mqbroker|NamesrvStartup|BrokerStartup" | grep -v grep | awk '{print $2}' | xargs kill -9 2>/dev/null || true

# 删除目录和服务文件
rm -rf ${INSTALL_DIR}
rm -rf ${DATA_DIR}
rm -f /etc/systemd/system/${SERVICE_NAME}.service
systemctl daemon-reload

echo "=== 清理完成 ==="