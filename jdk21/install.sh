#!/bin/bash

echo "====================================="
echo "  完整安装 OpenJDK 21 并设为默认版本"
echo "  保留旧 JDK，双版本共存"
echo "====================================="

# 1. 创建必需目录（日志/数据/临时 全部放到 /ncpsdata/jdk21）
mkdir -p /ncpsmw/jdk21
mkdir -p /ncpsdata/jdk21/{logs,data,tmp}

# 2. 进入安装包目录，解压到 /ncpsmw/jdk21（平铺不嵌套）
cd /home/install/jdk21
tar -zxvf OpenJDK21U-jdk_x64_linux_hotspot_21.0.10_7.tar.gz -C /ncpsmw/jdk21 --strip-components=1

# 3. 配置环境变量（只写一次，干净追加）
cat >> /etc/profile <<'EOF'

# JDK21
export JAVA_HOME=/ncpsmw/jdk21
export PATH=/ncpsmw/jdk21/bin:$PATH
export CLASSPATH=.:/ncpsmw/jdk21/lib
EOF

# 4. 生效环境变量
source /etc/profile
hash -r

# 5. 注册系统默认 JDK（优先级最高，不删除旧版本）
alternatives --install /usr/bin/java java /ncpsmw/jdk21/bin/java 9999
alternatives --install /usr/bin/javac javac /ncpsmw/jdk21/bin/javac 9999
alternatives --set java /ncpsmw/jdk21/bin/java
alternatives --set javac /ncpsmw/jdk21/bin/javac

# 6. 显示结果
echo -e "\n\033[32m === 安装并切换完成 ===\033[0m"
java -version
echo
echo "JAVA_HOME: $JAVA_HOME"
echo "数据日志目录: /ncpsdata/jdk21"
echo "旧版本 JDK 已保留，可随时切换"
