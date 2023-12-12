# bm-k8s
Infrastructure as Code (IaC) of Bare Metal Kubernetes


## 一键式安装
```shell script
# 一键式完成安装部署
./bootstrap.sh
```

## 功能列表

* 一键式底座管理k8s集群（当前单节点）：all in one @ 1C2GB
* (系统组件/用户集群&组件) 安装、部署、升级通过ArgoCD
* 模板化管理裸金属节点资源
* ClusterAPI管理负载裸金属k8s集群
* 支持kubevirt虚拟化resource provider
* 支持Rook-Ceph裸金属存算分离集群
* 客户集群三大插件管理：CNI、CSI、Device插件
* 统一管控面在底座集群：服务暴露、代理集成
* 云原生BMaaS方案Tinkerbell(golang)集成

 