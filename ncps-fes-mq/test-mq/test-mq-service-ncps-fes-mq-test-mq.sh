#!/bin/sh

JAR_NAME=test-mq-ncps-server-fes-mq
SERVICE_NAME=test-mq-ncps-server-fes-mq
LOCAL_IP=192.168.15.84
SERVER_PORT=41013

NACOS_HOST=192.168.15.84:8090
NACOS_USERNAME=nacos
NACOS_PASS=nacos
NACOS_NAMESPACE=cpms

echo "===== test-mq-ncps-server-fes-mq 服务测试专用-数据服务启动 ====="

# 查找最新jar包
jarName=$(find . -type f -name "$JAR_NAME*.jar" | sort -r | head -n 1)
if [ -z "$jarName" ]; then
    echo "错误：未找到 $JAR_NAME 相关jar包！"
    exit 1
fi
echo "找到jar包：$jarName"

# 帮助信息
function echoHelp() {
	echo "------------------------------------HELP------------------------------------"
	echo ""
	echo "    查看进程pid : ./service_XXX.sh"
	echo "    启动/停止/重启 : ./service_XXX.sh start/stop/restart"
	echo ""
	echo "-------------------------------------END-------------------------------------"
}

# 根据端口查PID
search() {
	temp=`lsof -i:$1 | grep "LISTEN"|awk '{print $2}'`
	echo $temp
}

# 杀进程
stop() {
	kill -9 $1
}

# 停止所有该服务进程
stopAll() {
 pids=$(ps -ef | grep "$JAR_NAME" | grep -v grep | awk '{print $2}')
	if [ ! -z "$pids" ]; then
	     echo "正在杀死进程：$pids"
	     kill -9 $pids
	fi
}

# 查看进程信息
searchInfo() {
	temp=`ps -ef|grep $JAR_NAME`
	echo $temp

	pids=$(ps -ef | grep "$JAR_NAME" | grep -v grep | awk '{print $2}')

	if [ ! -z "$pids" ]; then
	     echo "运行PID：$pids"
	fi

}

# 启动服务
start() {
	stopAll  # 先停旧进程
	echo "正在启动服务..."

	nohup java -Dfile.encoding=UTF-8 \
		 -Ddiscovery.server.type=nacos \
         -Ddiscovery.server.host=$NACOS_HOST \
		 -Ddiscovery.server.local-ip=$LOCAL_IP \
         -Ddiscovery.server.username=$NACOS_USERNAME \
         -Ddiscovery.server.password=$NACOS_PASS \
         -Ddiscovery.server.namespace=$NACOS_NAMESPACE \
		 -Ddiscovery.server.group=DEFAULT_GROUP \
		 -Dproject.name=$SERVICE_NAME \
		 -jar \
         -Xms256m -Xmx512m -Xss1m \
         -XX:MetaspaceSize=200m -XX:MaxMetaspaceSize=200m \
         -XX:+UseG1GC -XX:MaxGCPauseMillis=200 \
         $jarName \
         --server.port=$SERVER_PORT >/dev/null 2>&1 &

	sleep 2
}

# 执行逻辑
if [ "$1" = "help" ]; then
	echoHelp
elif  [ "$1" = "" ]; then
	searchInfo
elif  [ "$1" = "start" ]; then
	start
	pid=`search $SERVER_PORT`
	echo "服务启动完成，PID：$pid"
elif [ "$1" = "stop" ]; then
	stopAll
elif [ "$1" = "restart" ]; then
	echo "正在停止服务..."
	stopAll
	echo "正在启动服务..."
	start
	searchInfo
else
	echoHelp
fi
