# MySQL 自动化运维脚本集

[![MySQL Version](https://img.shields.io/badge/MySQL-8.4%20LTS-blue.svg)](https://dev.mysql.com/doc/refman/8.4/en/)
[![Platform](https://img.shields.io/badge/Platform-Debian%2012-red.svg)](https://www.debian.org/releases/bookworm/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![GitHub Stars](https://img.shields.io/github/stars/wangzhenye2019/mysql-scripts?style=social)](https://github.com/wangzhenye2019/mysql-scripts)
[![Auto-Deployment](https://img.shields.io/badge/Type-Binary%20Installation-orange.svg)](#快速开始)
[![Security](https://img.shields.io/badge/Security-Production%20Ready-red.svg)](#安全警告)

> 面向 **Debian 12** 的 MySQL 自动化脚本：包括 **MySQL 5.7.44 增强半同步 + Orchestrator + 受控写 VIP** 遗留高可用模块，以及 **MySQL 8.4 InnoDB Cluster + MySQL Shell + MySQL Router** 标准化模块。
>
> **重要说明：** 新增的 `mysql57_orchestrator_ha/` 和 `mysql84_innodb_cluster/` 模块分别服务于不同架构，禁止混用。原有单实例、异步复制、备份恢复和健康监控脚本已完成 MySQL 8.4 安全适配；旧 `mysql_install_mgr.sh`、`mysql_install_keepalived.sh` 与 `mysql_install_mha.sh` 不属于新的生产级自动化路径，不能与新模块并行控制同一集群。
> 
> 源项目: [dbops/mysql_ansible](https://github.com/yml/workspace/01_Projects/dbops)

---

## 核心特性

- **Binary Installation** - 无需依赖发行版包管理器，直接部署官方二进制包
- **Production Hardening** - 生产级安全加固（密码策略、权限最小化、审计日志）
- **Performance Tuning** - 基于服务器规格的自动化参数调优（Buffer Pool、Threads 等）
- **Multi-Architecture** - 支持单节点、主从复制、MGR、Keepalived、MHA 等多种架构
- **Backup & Recovery** - Xtrabackup 物理备份，支持全量+增量、定时清理
- **Health Monitoring** - 多维度健康检测 + 自动故障自愈 + 告警通知

---

## 脚本矩阵

| 类别 | 脚本文件 | 功能描述 | Ansible 源 | 技术要点 |
|------|----------|----------|------------|----------|
| **部署** | `mysql_install_single.sh` | 单节点安装 | `single_node.yml` | Binary 部署、目录规范、基础参数 |
| **部署** | `mysql_install_master_slave.sh` | 主从复制 | `master_slave.yml` | GTID 配置、复制安全、延迟监控 |
| **高可用** | `mysql_install_mgr.sh` | MGR 集群 | `mgr.yml` | 单主/多主模式、仲裁选主 |
| **高可用** | `mysql_install_keepalived.sh` | Keepalived HA | `keepalived_master_slave.yml` | VIP 漂移、心跳检测 |
| **高可用** | `mysql_install_mha.sh` | 旧 MHA 架构 | `mha.yml` | 仅保留参考，不建议用于新部署 |
| **Debian 12 / 5.7 HA** | `mysql57_orchestrator_ha/` | GTID 增强半同步、Orchestrator、受控 VIP | - | AFTER_SYNC、写入门禁、fencing hook、故障演练 |
| **Debian 12 / 8.4 HA** | `mysql84_innodb_cluster/` | 官方 InnoDB Cluster、Shell、Router | - | AdminAPI、Clone、Router metadata 路由 |
| **备份** | `mysql_backup_restore.sh` | 备份恢复 | `backup_script.yml` | Xtrabackup、流式压缩 |
| **监控** | `mysql_health_monitor.sh` | 故障自愈 | - | 健康检查、自动重启、告警 |

---

## 快速开始

### 1. 克隆仓库

```bash
git clone git@github.com:wangzhenye2019/mysql-scripts.git
cd mysql-scripts
```

### 2. 设置权限

```bash
chmod +x *.sh
```

### 3. 验证环境（预检）

```bash
# 生产环境部署前必检项
./mysql_install_single.sh --pre-check

# 检查项：OS版本、内存、磁盘、网络、依赖
```

### 4. 执行部署

```bash
# 单节点安装：必须通过环境变量或权限为 0600 的配置文件提供强密码
sudo MYSQL_ADMIN_PASSWORD='请替换为强密码' ./mysql_install_single.sh

# 指定版本、端口、数据库类型，并校验已下载二进制的 SHA-256
sudo MYSQL_ADMIN_PASSWORD='请替换为强密码' \
  MYSQL_PACKAGE_SHA256='官方发布的 SHA-256 值' \
  ./mysql_install_single.sh -v 8.4.6 -p 3306 -t mysql

# 服务器规格自动匹配
./mysql_install_single.sh -s 8c16g   # 自动配置 Buffer Pool
```

---

## 参数配置

### 通用参数

| 参数 | 默认值 | 说明 | 生产建议 |
|------|--------|------|----------|
| `-v, --version` | `8.4.6` | MySQL 版本 | 生产环境锁定小版本 |
| `-p, --port` | `3306` | 服务端口 | 多实例时递增 |
| `-t, --type` | `mysql` | 数据库类型 | MySQL 8.4 已验证；Percona/GreatSQL 需按其二进制包与参数单独验证 |
| `-s, --specs` | `auto` | 服务器规格 | auto/4c8g/8c16g/16c32g |

### 高级参数

| 变量 | 默认值 | 说明 | 调优原理 |
|------|--------|------|----------|
| `MYSQL_ADMIN_USER` | `admin` | 管理员账户 | 建议禁用 root 远程登录 |
| `MYSQL_ADMIN_PASSWORD` | 无默认值 | 管理员密码 | **必须通过环境变量或权限为 0600 的配置文件提供** |
| `MYSQL_DATA_DIR_BASE` | `/database/mysql` | 数据目录 | 建议独立磁盘/挂载点 |
| `innodb_buffer_pool_size` | **自动计算** | 缓冲池大小 | 建议为可用内存的 70-80% |
| `max_connections` | **自动计算** | 最大连接数 | 基于服务器规格动态调整 |

### 服务器规格与参数映射

| 规格 | Buffer Pool | max_connections | 适用场景 |
|------|-------------|-----------------|----------|
| `4c8g` | 3G | 800 | 开发/测试 |
| `8c16g` | 10G | 1500 | 小规模生产 |
| `16c32g` | 22G | 3000 | 中型生产 |
| `auto` | 内存×0.7 | CPU×150 | 自适应 |

---

## 最佳实践配置

### 1. Buffer Pool 智能调优

```bash
# 脚本自动计算逻辑
Available_Mem=$(free -g | awk '/Mem:/ {print $7}')
Buffer_Pool=$((Available_Mem * 7 / 10))  # 取 70%

# 实际效果：避免 OOM，确保系统仍有足够内存
```

### 2. 目录结构规范

```
/database/
├── mysql/
│   ├── data/          # 数据文件 (独立分区)
│   ├── redo/          # Redo 日志 (SSD 推荐)
│   ├── binlog/        # Binlog (高 IOPS 存储)
│   ├── tmp/           # 临时文件
│   └── conf/          # 配置文件
├── backup/
│   ├── full/          # 全量备份
│   └── inc/           # 增量备份
```

### 3. 安全加固项

- **凭据管理**: 脚本不再提供默认密码。请使用受限环境变量、受限配置文件或企业密钥管理服务，且避免把密码写入 Shell 历史、Git、进程参数和日志。
- **权限最小化**: 禁止 root 远程登录；备份账户仅创建在 `localhost`，日常运维账户需按来源网段和权限单独收敛。
- **认证插件**: MySQL 8.4 默认使用 `caching_sha2_password`，不再主动启用已默认关闭的 `mysql_native_password`。
- **网络隔离**: 仅监听内网 IP，生产环境禁用公网端口；复制链路应配置 TLS 证书，而非只依赖 `GET_SOURCE_PUBLIC_KEY`。

### 4. 性能优化建议

| 参数 | 推荐值 | 场景 |
|------|--------|------|
| `innodb_flush_log_at_trx_commit` | 1 | 数据强一致（默认） |
| `sync_binlog` | 1 | 防止 Binlog 丢失 |
| `innodb_flush_method` | O_DIRECT | 写入密集型 |
| `innodb_io_capacity` | 根据 SSD 调整 | 高 IOPS |

---

## 安全警告

> ⚠️ **生产环境部署前必读**

### 部署前检查清单

- [ ] 确认服务器规格与业务负载匹配
- [ ] 验证数据备份有效性
- [ ] 规划 VIP、网络段、端口范围
- [ ] 修改默认密码为强密码
- [ ] 配置防火墙规则（仅开放业务端口）
- [ ] 确认 SSH 免密登录已配置（多节点环境）

### 高危操作

| 操作 | 风险等级 | 防护措施 |
|------|----------|----------|
| 主从切换 | 🔴 高 | 提前演练，确认数据无延迟 |
| MGR 重建 | 🔴 高 | 确保所有节点数据一致 |
| 备份恢复 | 🟠 中 | 先在测试库验证，停止写入 |
| 参数调整 | 🟠 中 | 在非高峰期执行，观察监控 |

---

## 架构概览

```
┌─────────────────────────────────────────────────────────────────────┐
│                    MySQL 自动化运维架构                              │
├─────────────────────────────────────────────────────────────────────┤
│  1. 单节点部署  ──────────────────► 单机版 MySQL                   │
│     • Binary 安装                                                  │
│     • 基础参数调优                                                  │
│                                                              │
│  2. 主从复制  ──────────────────► Master-Slave 架构              │
│     • GTID 模式                                                 │
│     • 读写分离                                                   │
│                                                              │
│  3. MGR 集群  ──────────────────► MySQL Group Replication     │
│     • 自动选举主库                                              │
│     • 数据强一致性                                             │
│     • 单主/多主模式                                            │
│                                                              │
│  4. Keepalived HA  ────────────────► 双主+VIP漂移                │
│     • VRRP 协议                                                 │
│     • VIP 自动漂移                                              │
│                                                              │
│  5. MHA  ───────────────────────────► 一主两从+MHA Manager       │
│     • 自动故障转移                                              │
│     • 零数据丢失                                                │
│                                                              │
│  6. 备份恢复  ─────────────────────► Xtrabackup 物理备份          │
│     • 全量+增量                                                 │
│     • 自动清理                                                 │
│                                                              │
│  7. 故障自愈  ─────────────────────► 健康检查+自动恢复             │
│     • 多维度检测                                                │
│     • 自动重启                                                 │
│     • 告警通知                                                 │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 使用示例

### Debian 12 高可用模块

完整的架构前置条件、部署顺序和演练清单请见 [Debian 12 HA 运行手册](docs/DEBIAN12_HA_RUNBOOK.md)。简要入口如下：

```bash
# 5.7.44 遗留高可用：先以权限 0600 创建专用配置，再逐节点准备与预检
sudo install -d -m 0700 /etc/mysql-scripts
sudo install -m 0600 config/examples/mysql57_ha.env.example /etc/mysql-scripts/mysql57-ha.env
sudo mysql57_orchestrator_ha/01_prepare_instance.sh --config /etc/mysql-scripts/mysql57-ha.env
sudo mysql57_orchestrator_ha/02_configure_lossless_semisync.sh --config /etc/mysql-scripts/mysql57-ha.env --apply --install-guard

# 8.4 标准集群：每个节点预检后，以 AdminAPI 建群并在应用节点 bootstrap Router
sudo install -m 0600 config/examples/mysql84_innodb_cluster.env.example /etc/mysql-scripts/mysql84-ic.env
sudo mysql84_innodb_cluster/02_preflight_instance.sh --config /etc/mysql-scripts/mysql84-ic.env --instance ic-1.example.internal:3306
sudo mysql84_innodb_cluster/03_create_cluster.sh --config /etc/mysql-scripts/mysql84-ic.env --apply --configure-instances
sudo mysql84_innodb_cluster/04_bootstrap_router.sh --config /etc/mysql-scripts/mysql84-ic.env
```

### 1. 单节点安装

```bash
# 基本安装
./mysql_install_single.sh

# 指定版本和端口
./mysql_install_single.sh -v 8.4.6 -p 3306 -t greatsql -s 8c16g
```

### 2. Source-Replica 复制安装

```bash
# 先以 XtraBackup 或 CLONE 对所有副本完成一致性置备，再显式确认。
export MASTER_IP="192.168.199.131"
export SLAVE_IPS_CSV="192.168.199.132,192.168.199.133"
export MYSQL_ADMIN_PASSWORD='请替换为强密码'
export MYSQL_RPLE_PASSWORD='请替换为复制强密码'
export REPLICAS_PROVISIONED=true
./mysql_install_master_slave.sh
```

该脚本使用 MySQL 8.4 的 `CHANGE REPLICATION SOURCE TO`、`START REPLICA` 与 GTID 自动定位；它不再通过 `rsync` 复制正在运行的数据目录。

### 3. MGR 集群安装

```bash
# 单主模式 MGR
export MGR_HOSTS=("192.168.199.131" "192.168.199.132" "192.168.199.133")
export MGR_SINGLE_PRIMARY=true
./mysql_install_mgr.sh
```

### 4. Keepalived HA

```bash
# 双主 + VIP 漂移
export WRITE_VIP=192.168.199.200
export MASTER_IP=192.168.199.131
export BACKUP_IP=192.168.199.132
./mysql_install_keepalived.sh
```

### 5. 备份恢复

```bash
# 执行全量备份
./mysql_backup_restore.sh backup

# 查看备份列表
./mysql_backup_restore.sh list

# 恢复数据（破坏性操作；必须显式确认）
./mysql_backup_restore.sh restore --yes /backup/full/backup.xbstream

# 设置定时任务（每日 02:00 全量）
./mysql_backup_restore.sh cron --time "0 2 * * *"
```

### 6. 故障自愈监控

```bash
# 启动监控
./mysql_health_monitor.sh start

# 启用告警通知
export ALERT_WEBHOOK="https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxx"
./mysql_health_monitor.sh start --enable-alert

# 手动健康检查
./mysql_health_monitor.sh check

# 查看监控状态
./mysql_health_monitor.sh status
```

---

## 目录结构

```
scripts/
├── mysql_install_single.sh           # 单节点安装
├── mysql_install_master_slave.sh     # 主从复制
├── mysql_install_mgr.sh              # MGR 集群
├── mysql_install_keepalived.sh       # Keepalived HA
├── mysql_install_mha.sh              # MHA 高可用
├── mysql_backup_restore.sh           # 备份恢复
├── mysql_health_monitor.sh           # 故障自愈监控
└── README.md                         # 本文档
```

---

## 依赖要求

### 系统要求

| 组件 | 要求 | 说明 |
|------|------|------|
| OS | RHEL/CentOS/Rocky 7+ / Ubuntu 18.04+ | 建议使用 Rocky 9 |
| MySQL | **8.4 LTS** | 当前适配和回归检查目标；5.7/8.0 与 GreatSQL/Percona 需另行兼容性测试 |
| SSH | 免密登录 | 多节点环境必须 |
| 权限 | root | 需要安装系统包 |

### 依赖软件

- **MySQL 二进制包**: 下载到 `~/downloads/` 目录
- **Percona XtraBackup**: 8.4 数据库使用 `percona-xtrabackup-84`；工具主版本须与数据库创建版本匹配。
- **Keepalived**: HA 脚本依赖
- **MHA Manager**: MHA 脚本依赖

### SSH 免密登录配置

```bash
# 生成 SSH 密钥
ssh-keygen -t rsa -N '' -f ~/.ssh/id_rsa

# 复制到所有节点（多节点环境）
ssh-copy-id -o StrictHostKeyChecking=no user@192.168.199.131
ssh-copy-id -o StrictHostKeyChecking=no user@192.168.199.132
```

---

## 故障排查

### 无法连接 MySQL

```bash
# 检查进程状态
ps aux | grep mysqld

# 检查端口监听
netstat -tuln | grep 3306

# 查看错误日志
tail -f /database/mysql/data/error.log
```

### 主从复制异常

```bash
# 查看复制状态
mysql -e "SHOW REPLICA STATUS\G"

# 检查 GTID 同步
mysql -e "SELECT * FROM performance_schema.replication_group_member_stats\G"
```

### Keepalived VIP 不漂移

```bash
# 检查 Keepalived 状态
systemctl status keepalived

# 检查 MySQL 检测脚本日志
tail -f /var/log/keepalived/check_mysql.log
```

---

## 路线图 (Roadmap)

- [ ] **MGR 高可用增强**
  - [ ] 支持多主模式自动切换
  - [ ] 添加 MGR 脑裂检测与自动恢复
  - [ ] 集成 Prometheus Exporter

- [ ] **监控集成**
  - [ ] Grafana Dashboard 模板
  - [ ] Prometheus + AlertManager 告警规则
  - [ ] 支持 Prometheus metrics 导出

- [ ] **备份增强**
  - [ ] 增量备份基于 LSN 自动发现
  - [ ] 跨机房异地容灾备份
  - [ ] 备份加密（AES-256）

- [ ] **运维工具**
  - [ ] 在线参数调优（不重启）
  - [ ] 慢查询自动分析
  - [ ] 空间使用分析与预警

---

## 相关文档

- [MySQL 8.4 官方文档](https://dev.mysql.com/doc/refman/8.4/en/)
- [MySQL 8.4 Source-Replica 复制](https://dev.mysql.com/doc/refman/8.4/en/replication.html)
- [Percona XtraBackup 8.4 文档](https://docs.percona.com/percona-xtrabackup/8.4/)
- [GreatSQL 文档](https://docs.greatdb.com/)
- [Percona XtraBackup](https://www.percona.com/software/percona-xtrabackup)
- [MHA Manager](https://github.com/yoshinorim/mha4mysql-manager)
- [Ansible 源项目](https://github.com/yml/workspace/01_Projects/dbops)

---

## License

MIT License - See source project for details.