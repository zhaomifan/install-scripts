# RocketMq集群搭建手册

## 集群架构说明

本集群采用 **3主3从** 的高可用部署架构，共3台物理服务器（或虚拟机），**每台服务器上同时运行1个Master Broker和1个Slave Broker**，形成交叉备份的拓扑结构。

### 部署映射关系

| 服务器IP | Master Broker | Slave Broker | 说明 |
|----------|--------------|--------------|------|
| 192.168.15.80 | broker-a (主) | broker-b (从) | a-0 主节点，b-1 从节点 |
| 192.168.15.81 | broker-b (主) | broker-c (从) | b-0 主节点，c-1 从节点 |
| 192.168.15.82 | broker-c (主) | broker-a (从) | c-0 主节点，a-1 从节点 |

### 架构设计要点

1. **交叉复制模式**：每个Slave Broker都是**另一台服务器**上Master Broker的从节点，而非本机Master的备份。例如，`192.168.15.80`上的`broker-b (从)`是`192.168.15.81`上`broker-b (主)`的从节点。

2. **故障容灾**：当任意一台服务器宕机时，该服务器上的Master Broker角色会由其他服务器上对应的Slave Broker接管，保证消息服务不中断。

3. **资源均衡**：每台服务器同时承担一个Master和一个Slave的角色，读写负载相对均衡，避免单台服务器过载。

4. **数据可靠性**：每个分片的主从数据实时同步，确保消息不丢失。

这种部署方式兼顾了**高可用性**和**资源利用率**，是生产环境常用的RocketMQ集群方案。

---

## 部署
### 启动集群
1. 上传脚本文件以及安装包到/home/install/rocketmq
2. 在每个服务器运行以下下命令
```shell
dos2unix /home/install/rocketmq/install_cluster.sh
chmod +x /home/install/rocketmq/install_cluster.sh
sh /home/install/rocketmq/install_cluster.sh --force-clean

sh /home/install/rocketmq/install_cluster_v4_DLedgerController.sh. --force-clean
dos2unix /home/install/rocketmq/install_cluster_v4_DLedgerController.sh
chmod +x /home/install/rocketmq/install_cluster_v4_DLedgerController.sh
sh /home/install/rocketmq/install_cluster_v4_DLedgerController.sh --force-clean


dos2unix /home/install/rocketmq/clean_rocketmq.sh
chmod +x /home/install/rocketmq/clean_rocketmq.sh
sh /home/install/rocketmq/clean_rocketmq.sh

chmod +x /home/install/rocketmq/clean_controller_rocketmq.sh
sh /home/install/rocketmq/clean_controller_rocketmq.sh



sh /home/install/rocketmq/install_cluster_v4_DLedgerController.sh



dos2unix /home/install/rocketmq/install_cluster_v5_controller_version.sh
chmod +x /home/install/rocketmq/install_cluster_v5_controller_version.sh
sh /home/install/rocketmq/install_cluster_v5_controller_version.sh

chmod +x /home/install/rocketmq/check_controller_rocketmq.sh
sh /home/install/rocketmq/check_controller_rocketmq.sh

sh /home/install/rocketmq/repair_controller_rocketmq.sh



dos2unix /home/install/rocketmq/install_cluster_v5_Controller_3m3s.sh
chmod +x /home/install/rocketmq/install_cluster_v5_Controller_3m3s.sh
sh /home/install/rocketmq/install_cluster_v5_Controller_3m3s.sh




clean_cluster_v4_DLedgerController

dos2unix /home/install/rocketmq/clean_cluster_v5_Controller_3m3s.sh
chmod +x /home/install/rocketmq/clean_cluster_v5_Controller_3m3s.sh
sh /home/install/rocketmq/clean_cluster_v5_Controller_3m3s.sh

dos2unix /home/install/rocketmq/install_cluster_v5_Controller_3m3s.sh
chmod +x /home/install/rocketmq/install_cluster_v5_Controller_3m3s.sh
sh /home/install/rocketmq/install_cluster_v5_Controller_3m3s.sh




dos2unix /home/install/rocketmq/clean_cluster_v5_Controller_3m3s_fix2_zhipu.sh
chmod +x /home/install/rocketmq/clean_cluster_v5_Controller_3m3s_fix2_zhipu.sh
sh /home/install/rocketmq/clean_cluster_v5_Controller_3m3s_fix2_zhipu.sh


dos2unix /home/install/rocketmq/install_cluster_v3_3m3s_acl_handswitch.sh
chmod +x /home/install/rocketmq/install_cluster_v3_3m3s_acl_handswitch.sh
sh /home/install/rocketmq/install_cluster_v3_3m3s_acl_handswitch.sh
sh /home/install/rocketmq/install_cluster_v6_3m3s_acl_handswitch_newport.sh
```

sh /home/install/rocketmq/install_cluster_remove.sh
3. 验证启动成功
显示有一个nameserver两个broker才算成功
```shell
jps | grep -E "NamesrvStartup|BrokerStartup|Controller"
3887823 NamesrvStartup
3888146 BrokerStartup
3887909 BrokerStartup
```

4. 同步topic(可选)
如果出现topic只在某一个节点,可通过该命令同步到其他节点
```shell
sh mqadmin updateTopic -n "192.168.15.80:9876;192.168.15.84:9876;192.168.15.98:9876" -c RocketMQ-Cluster -t test_real_hlj_v1 -o true
```
5. 添加用户
待补充

6. 查看集群状态
查看集群状态
```shell
sh /ncpsmw/rocketmq_cluster/bin/mqadmin clusterList -n 127.0.0.1:9876
```
### 启动控制台dashbaord
以在192.168.15.80上启动dashboard为例
1. 在192.168.15.80运行以下命令(注意:脚本里的DASH_IP需要按需修改)
```shell
dos2unix /home/install/rocketmq/install_dashboard_cluster.sh
chmod +x /home/install/rocketmq/install_dashboard_cluster.sh
sh /home/install/rocketmq/install_dashboard_cluster.sh


dos2unix /home/install/rocketmq/install_dashboard_cluster_v6_newport.sh
chmod +x /home/install/rocketmq/install_dashboard_cluster_v6_newport.sh
sh /home/install/rocketmq/install_dashboard_cluster_v6_newport.sh
```
### 卸载控制台
dos2unix /home/install/rocketmq/install_dashboard_cluster_remove.sh
chmod +x /home/install/rocketmq/install_dashboard_cluster_remove.sh
sh /home/install/rocketmq/install_dashboard_cluster_remove.sh


## 访问权限控制
集群启动权限校验,访问需使用账号密码,启动脚本初始化了两个账号
- admin:超级管理员
- rocketmq:业务侧普通用户
如需添加用户可通过命令动态添加,实时生效

# 查看进程
jps | grep -E "NamesrvStartup|BrokerStartup|Controller"

2. 访问 http://192.168.15.80:8089 查看控制台


dos2unix /home/install/rocketmq/verify_rocketmq.sh
chmod +x /home/install/rocketmq/verify_rocketmq.sh
sh /home/install/rocketmq/verify_rocketmq.sh



sh bin/mqadmin updateTopic \
    -n "192.168.15.99:9876" \
    -t TestZkf \
    -c DefaultCluster \
    -r 8 \
    -w 8 \
    --accessKey admin \
    --secretKey ncps@2026




dos2unix /home/install/rocketmq/install_cluster_V3.sh
chmod +x /home/install/rocketmq/install_cluster_V3.sh
sh /home/install/rocketmq/install_cluster_V3.sh



sh /home/install/rocketmq/clean_cluster_v5_Controller_3m3s_fix2_zhipu.sh
sh /home/install/rocketmq/install_cluster_v4_DLedgerController.sh



<!-- sh /home/install/rocketmq/clean_cluster_v5_Controller_3m3s_fix2_zhipu.sh -->
sh /home/install/rocketmq/clean_cluster_v5_Classic_3m3s_ACL.sh
sh /home/install/rocketmq/install_cluster_v4_DLedgerController.sh


sh /home/install/rocketmq/clean_cluster_v4_DLedgerController.sh
dos2unix /home/install/rocketmq/install_cluster_v5_Classic_3m3s_ACL.sh
chmod +x /home/install/rocketmq/install_cluster_v5_Classic_3m3s_ACL.sh
sh /home/install/rocketmq/install_cluster_v5_Classic_3m3s_ACL.sh


# 移除 install_cluster_v5_Controller_3m3s_fix2_zhipu_no_acl 安装 install_cluster_v5_Classic_3m3s_ACL
sh /home/install/rocketmq/clean_cluster_v5_Controller_3m3s_fix2_zhipu.sh
dos2unix /home/install/rocketmq/install_cluster_v5_Classic_3m3s_ACL.sh
chmod +x /home/install/rocketmq/install_cluster_v5_Classic_3m3s_ACL.sh
sh /home/install/rocketmq/install_cluster_v5_Classic_3m3s_ACL.sh


sh /home/install/rocketmq/clean_cluster_v5_Classic_3m3s_ACL.sh --delete-data




sh /home/install/rocketmq/install_v3.sh


sh /ncpsmw/rocketmq_cluster/bin/mqadmin clusterList -n "192.168.15.80:19876;192.168.15.84:19876;192.168.15.98:19876"