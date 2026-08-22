# Debian 12.8 下 MySQL 5.7.44 与 MySQL 8.4 架构适配评估

> **结论：可以适配，但不能以当前仓库的现有脚本直接上线。**  
> 应将目标拆分为两套**互相隔离、版本专用、可演练**的实现：一套为 MySQL 5.7.44 的 GTID 增强半同步复制 + Orchestrator + 安全 VIP 方案；另一套为 MySQL 8.4 官方 InnoDB Cluster（MGR + MySQL Shell AdminAPI + MySQL Router）方案。两者的复制语法、认证插件、安装方式、故障模型和流量入口都不同，不能共用同一份 `my.cnf` 模板或故障切换脚本。

## 1. 适配结论总览

| 目标 | 当前仓库适配性 | 结论 | 正确改造方向 |
|---|---|---|---|
| Debian 12.8 / 内核 6.1 | 部分适配 | **需要补齐 Debian 安装层** | 用官方 MySQL APT repo 或经校验的官方二进制；编写 Debian 专用依赖、目录、systemd 与防火墙适配层 |
| MySQL 5.7.44：GTID + 增强半同步 + Orchestrator + VIP | 不适配 | **必须新建 5.7 专用 HA 模块** | 不能复用当前 8.4 Source-Replica、Keepalived、MHA 脚本作为生产实现 |
| MySQL 8.4：InnoDB Cluster + Shell + Router | 不适配 | **必须以 AdminAPI/Router 方式重构** | 当前 `mysql_install_mgr.sh` 只能作为配置素材，不能称为官方 InnoDB Cluster 自动化 |

当前已同步的核心脚本是以 MySQL 8.4 单实例、异步 Source-Replica、物理备份恢复和健康监控为适配目标。它们**不应**被误用于 MySQL 5.7.44 的高可用部署：MySQL 5.7 不支持脚本所使用的 `caching_sha2_password`、`CHANGE REPLICATION SOURCE TO`、`START REPLICA` 等 MySQL 8.4 语义，且当前单实例模板还含 8.4 参数。反向地，旧 Keepalived/MHA 脚本也不满足 MySQL 8.4 InnoDB Cluster 的 AdminAPI 与 Router 管理模型。

## 2. Debian 12.8 基线判断

Debian 12.8 和内核 `6.1.0-27-amd64` 本身不是两套架构的阻塞条件；关键是**同机不能混用 5.7 与 8.4 的默认服务、APT 仓库选择、socket、数据目录和 systemd unit**。MySQL 官方建议 Debian/Ubuntu 使用 MySQL APT repository；启用后该仓库会接管 MySQL 包的安装与升级，而且升级按选定的 major release series 进行。[1] [2]

MySQL 5.7.44 是 5.7 系列最后一个版本，官方建议升级到 8.0、8.4 或 Innovation 系列。[3] 因此，5.7.44 应被定义为**遗留兼容集群**：固定版本、固定包哈希、固定镜像仓库、单独漏洞补偿与退出计划，而不是新系统的长期默认平台。5.7.44 发行说明显示其服务器链接 OpenSSL 3.0.10，这意味着 Debian 12 的 OpenSSL 3 环境并非天然 ABI 阻断；但这不等于它拥有当前版本的常规维护保障。[3]

| 事项 | 5.7.44 遗留集群 | 8.4 新建集群 |
|---|---|---|
| 安装来源 | 冻结的官方包/二进制及 SHA-256，禁止无控制升级 | 官方 MySQL APT repo 的 8.4 LTS 通道或经校验二进制 |
| systemd unit | 独立，例如 `mysql57@3306.service` | 官方 `mysql.service` 或独立 `mysql84@3306.service` |
| 数据/日志路径 | `/srv/mysql57/...` | `/srv/mysql84/...` |
| 配置文件 | `/etc/mysql57/my.cnf` | `/etc/mysql84/my.cnf` |
| 端口/Socket | 独立端口与 socket | 独立端口与 socket |
| 运维原则 | 只做必要变更并规划迁移 | 作为长期目标架构 |

## 3. MySQL 5.7.44：GTID 增强半同步 + Orchestrator + VIP

### 3.1 架构本身是否成立

该架构**技术上成立**，且可以将“已向客户端成功确认的事务”设计为 RPO=0。MySQL 5.7 官方文档说明，半同步复制要求源库在至少一个副本接收事件、写入 relay log 并刷盘确认后，才继续提交；`rpl_semi_sync_master_wait_point=AFTER_SYNC` 是默认等待点。在该等待点，源库只有在副本确认后才提交存储引擎并向客户端返回，官方明确说明源库意外退出、切换至副本时可以 lossless。[4]

但这不是一个仅靠设置半同步插件即可无条件成立的承诺。半同步在确认超时后会**回退到异步复制**；一旦允许回退，成功返回给客户端的事务可能不再存在于任何可提升副本上。因此，RPO=0 必须被实现为端到端的不变量：当 `Rpl_semi_sync_master_status` 不正常、确认副本不足、复制链路异常或拓扑失去多数观察能力时，写流量必须被阻断或 fenced，而不能继续以异步模式对外提供写入。[4] [5]

> **准确表述应为：** 在 `AFTER_SYNC`、确认副本充足、未回退异步、候选副本已验证包含全部已确认 GTID、旧主已被可靠隔离的条件下，主库故障切换可实现已确认事务的 RPO=0。  
> **不应表述为：** “Keepalived + Orchestrator 自动切换天然保证任何网络分区下 RPO=0。”

### 3.2 Orchestrator 与 VIP 的职责边界

Orchestrator 能发现和修复 GTID 拓扑；官方文档明确要求自动故障切换的拓扑支持 Oracle GTID（`MASTER_AUTO_POSITION=1`）、MariaDB GTID、Pseudo-GTID 或 Binlog Server。它也允许通过 pre-/post-recovery hooks 执行外部动作。[6] 因此，Orchestrator **可以**成为 5.7 拓扑发现、候选副本选择、提升和副本回接的控制器。

但 Orchestrator 不替您完成 VIP 的安全漂移；其官方文档将“新主库服务发现”明确归为用户责任，推荐用 DNS、KV 存储、代理或外部 hook 实现。[6] 在 VIP 方案中，VIP 漂移只能在 Orchestrator 的故障切换状态机通过关键安全关卡后执行。该关卡至少应包括：旧主 fencing/STONITH 成功或旧主所在网络被隔离；候选副本的 GTID 集满足要求；候选副本可写；旧 VIP 已撤销或 ARP 宣告已完成；应用写入口已暂时封禁并在新主健康检查通过后再开放。

Orchestrator 的检测是基于主库和副本的多观察者判断，而不是对单一主库做一次 TCP 探测，这有助于减少网络抖动造成的误切换。[7] 但控制平面也必须高可用：建议以 Orchestrator Raft 或高可用后端部署至少 3 个控制节点；否则数据库的自动切换能力仍会因单个 Orchestrator 实例失效而消失。

### 3.3 当前仓库的缺口

| 当前文件 | 现状 | 与 5.7 RPO=0 架构的冲突/缺口 |
|---|---|---|
| `mysql_install_single.sh` | 已按 MySQL 8.4 认证、配置与服务模型适配 | `caching_sha2_password` 和 8.4 参数不适用于 5.7；不能作为 5.7 基础安装器 |
| `mysql_install_master_slave.sh` | 已改为 `CHANGE REPLICATION SOURCE TO`、`START REPLICA`、`SHOW REPLICA STATUS` | 这些是 8.x 现代语义；5.7 需要 `CHANGE MASTER TO`、`START SLAVE`、`SHOW SLAVE STATUS`；更重要的是未实现 `AFTER_SYNC`、半同步确认数、回退熔断、Orchestrator 或 fencing |
| `mysql_install_keepalived.sh` | 仅做 MySQL 存活探测和 VIP 漂移 | 健康检查使用 `root --skip-password`，与密码化安装冲突；通知脚本只是注释，没有实际 role switch；`NETMASK`/配置拼写也存在问题；没有 GTID 验证、STONITH、写入栅栏或 Orchestrator hook |
| `mysql_install_mha.sh` | 旧式 MHA 路径 | 与用户指定的 Orchestrator 架构不同，且当前实现存在大量吞错和不完整 failover 逻辑 |
| `mysql_health_monitor.sh` | 单实例 service 自愈 | 不理解 Orchestrator recovery 状态，不应自行重启、提升或修改 VIP |

因此，**不能在当前 Keepalived 脚本上简单加几个参数就声称达成秒级 RPO=0**。正确做法是新建一个版本隔离的 `mysql57_orchestrator_ha/` 模块，并从当前脚本中仅复用通用日志、配置权限和 systemd 操作等低层函数。

### 3.4 推荐的 5.7 模块边界

建议最少拆分为 6 个脚本或角色，避免把数据库安装、复制、VIP 和灾难操作混在一个 Shell 文件中。

| 模块 | 关键职责 | 强制验收点 |
|---|---|---|
| `01_install_mysql57.sh` | 安装固定 5.7.44、独立路径、GTID 与 Row binlog 基线 | `mysqld --validate-config`；版本、校验和、systemd unit 正确 |
| `02_configure_lossless_semisync.sh` | 安装半同步插件，设置 `AFTER_SYNC`、确认副本数、监控状态 | 正常写入时半同步状态为 ON；失去确认副本时写流量被安全阻断而非异步回退 |
| `03_provision_replica.sh` | 使用 XtraBackup/Clone-equivalent 或逻辑流程建立一致副本 | GTID 集、校验表、复制线程和 relay log durability 合格 |
| `04_deploy_orchestrator.sh` | Orchestrator HA、候选策略、自动恢复策略 | `replication-analysis` 与模拟故障检测正确；恢复审计可追溯 |
| `05_vip_fencing_hooks.sh` | pre-failover fencing、VIP 释放/获取、ARP、read-only、写流量门控 | 旧主可达但业务网隔离、双向网络分区、旧主重启等场景均不双写 |
| `06_drill_and_audit.sh` | 故障注入、RPO/RTO 量化、回切与旧主重建 | 连续演练通过后才允许生产自动恢复 |

在半同步层面，至少需要明确并测量如下变量：`rpl_semi_sync_master_enabled=1`、`rpl_semi_sync_slave_enabled=1`、`rpl_semi_sync_master_wait_point=AFTER_SYNC`、确认副本数和 timeout 策略。应持续采集 `Rpl_semi_sync_master_status`、`Rpl_semi_sync_master_yes_tx`、`Rpl_semi_sync_master_no_tx`、`Rpl_semi_sync_master_no_times`，并将任何异步回退视为 SLO 违规。[4] [5]

## 4. MySQL 8.4：InnoDB Cluster（MGR + MySQL Shell + Router）

### 4.1 架构本身是推荐方向

用户提出的 MySQL 8.4 架构是更适合新建平台的方向。官方将 InnoDB Cluster 定义为至少 3 个 MySQL Server 实例、Group Replication、MySQL Shell 和 MySQL Router 组成的集成高可用方案。Group Replication 提供成员管理、容错与自动故障转移；常见部署是 single-primary，而 AdminAPI 是官方的部署与管理接口。[8] [11]

MySQL Router 负责把应用流量导向当前 PRIMARY。Router 会通过 bootstrap 读取集群元数据；官方推荐让 Router 与应用部署在同一主机，使应用连接本地 Router 而不是直接连接数据库成员。[9] 这正是“流量自动重定向”的正确实现，不需要对数据库 PRIMARY 再额外叠加写 VIP。Router 自身仍需按应用层冗余设计，例如每个应用实例/节点各部署一个 Router，或使用多个 Router 加独立四层入口。

### 4.2 InnoDB Cluster 的不可省略前提

Group Replication 对业务数据和网络有硬性要求：可复制表应使用 InnoDB，且每张表必须具备主键或非空唯一键等主键等价物；成员之间必须维持双向通信；成员还需要唯一 `server_id`、binary log、`log_replica_updates=ON`、ROW binlog format、`gtid_mode=ON` 与 `enforce_gtid_consistency=ON`。[10] 这些条件不能由“脚本成功执行”自动证明，尤其是历史业务库的无主键表、非 InnoDB 表、跨机房高抖动网络和不一致的 `lower_case_table_names` 都可能阻断集群创建或造成运行风险。

AdminAPI 通过 MySQL Shell 的 `dba` API 创建、配置、加入和监控 InnoDB Cluster；它要求使用 TCP 连接，不支持 socket 连接。[11] 因而安装脚本要准备受控的 TCP 管理端点、TLS/账户策略和 metadata schema，而不是通过 SSH 在各节点直接拼接 `my.cnf` 后执行 `START GROUP_REPLICATION`。

### 4.3 当前 `mysql_install_mgr.sh` 为什么不等同于 InnoDB Cluster

当前仓库 MGR 脚本最多可视作“手工 Group Replication 配置草稿”，不是官方 InnoDB Cluster 自动化，不能直接对标您的目标架构。

| 维度 | 当前脚本 | 目标 InnoDB Cluster 实现 |
|---|---|---|
| 数据库产品默认值 | 默认 `greatsql` | **官方 MySQL 8.4**，版本需与 Shell/Router 同一主版本线 |
| 组建方式 | SSH 写 `my.cnf`、`INSTALL PLUGIN`、直接 `START GROUP_REPLICATION` | MySQL Shell AdminAPI：`dba.configureInstance()`、`dba.createCluster()`、`cluster.addInstance()` |
| 实例置备 | `rsync --delete` 数据目录 | AdminAPI 自动恢复策略/Clone 或经过验证的物理备份恢复 |
| Router | 没有实现 | 安装、`mysqlrouter --bootstrap`、systemd、元数据更新与应用接入验证 |
| 业务表准入 | 没有检查 | InnoDB、主键、GTID、ROW、网络和参数一致性预检 |
| 安全 | 硬编码密码、关闭 SSH Host Key 校验 | 受限密钥/证书、TLS、最小权限、密码不入代码 |
| 故障测试 | 用 `pkill -9 mysqld` | AdminAPI `cluster.status()`、Router RW 端点持续连接、受控的节点/网络故障演练 |
| Debian 12 | 仅粗略 `apt-get` fallback，二进制/路径仍偏 RHEL | 用 MySQL APT 8.4、`/etc/mysql`、systemd 和防火墙适配 |

### 4.4 推荐的 8.4 实现路径

推荐新建 `mysql84_innodb_cluster/` 模块，且不与 MySQL 5.7 的半同步/VIP 模块共享运行时配置。

| 阶段 | 自动化对象 | 完成标准 |
|---|---|---|
| 1. 预检 | Debian 12、DNS/IP、时间同步、磁盘、3306/33060/33061 与 MGR 端口、防火墙 | 节点名与 IP 可解析；全部端口/时钟/MTU 检查通过 |
| 2. 安装 | MySQL Server 8.4、MySQL Shell 8.4、MySQL Router 8.4 | 组件主版本一致；APT 源和包哈希可追溯 |
| 3. 实例配置 | 唯一 server_id、GTID、ROW、InnoDB、TLS、性能参数 | Shell 的 `dba.checkInstanceConfiguration()` 通过 |
| 4. 建群 | `dba.createCluster()`、`cluster.addInstance()`、恢复策略 | 3 个成员 ONLINE，single-primary 的 PRIMARY 唯一 |
| 5. 路由 | Router bootstrap、RW/RO 端口、systemd | 应用仅连 Router；PRIMARY 变化后 RW 连接自动恢复 |
| 6. 运维 | 备份、监控、扩缩容、重启、故障演练 | `cluster.status({extended: 1})`、Router 指标、告警与恢复 SOP 全部可验证 |

## 5. 是否可直接在同一仓库适配

可以，但应采用**新增版本化模块**而不是继续扩大原脚本。推荐目录如下：

```text
mysql-scripts/
├── lib/                         # 无状态公共函数：日志、机密加载、预检、SSH、systemd
├── mysql57_orchestrator_ha/     # 只服务 MySQL 5.7.44
│   ├── install_mysql57.sh
│   ├── configure_lossless_semisync.sh
│   ├── provision_replica.sh
│   ├── deploy_orchestrator.sh
│   ├── vip_fencing_hooks.sh
│   └── test_failover.sh
├── mysql84_innodb_cluster/      # 只服务官方 MySQL 8.4
│   ├── install_mysql84_debian.sh
│   ├── preflight_adminapi.py
│   ├── create_cluster.js
│   ├── bootstrap_router.sh
│   └── validate_cluster.js
└── docs/
    ├── mysql57-rpo0-safety-case.md
    └── mysql84-innodb-cluster-runbook.md
```

两套模块应使用独立的 inventory、机密、端口、数据目录、备份策略和 CI 测试矩阵。若两套集群必须共存于同一 Debian 12 主机，必须额外实施服务隔离、CPU/内存/IO 隔离和故障域隔离；从可靠性和升级治理角度，**优先建议物理或虚拟机级分离**。

## 6. 最终建议

MySQL 8.4 InnoDB Cluster 是推荐的长期标准化方向；它应优先落地为官方 MySQL Shell AdminAPI + Router 自动化，而不是修补现有 MGR 脚本。MySQL 5.7.44 的 Orchestrator + 无损半同步 + VIP 方案可以作为业务兼容过渡架构，但只有将半同步回退、候选副本 GTID、fencing、VIP 漂移和应用写流量门控闭环后，才能将 RPO=0 写入运行目标。

> **实施建议：** 先实现并验收 MySQL 8.4 InnoDB Cluster 模块；5.7 模块仅在存在不可迁移业务时开发，并附带明确的迁移退出时间表。两套架构均应先在 3 节点隔离环境完成网络分区、主机断电、磁盘满、进程崩溃、旧主回归和 Router/Orchestrator 控制面失效演练。

## References

[1]: https://dev.mysql.com/doc/en/linux-installation-apt-repo.html "Installing MySQL on Linux Using the MySQL APT Repository"
[2]: https://dev.mysql.com/doc/mysql-apt-repo-quick-guide/en/ "A Quick Guide to Using the MySQL APT Repository"
[3]: https://dev.mysql.com/doc/relnotes/mysql/5.7/en/news-5-7-44.html "Changes in MySQL 5.7.44"
[4]: https://dev.mysql.com/doc/refman/5.7/en/replication-semisync.html "MySQL 5.7 Semisynchronous Replication"
[5]: https://dev.mysql.com/doc/refman/5.7/en/replication-semisync-interface.html "MySQL 5.7 Semisynchronous Replication Interface"
[6]: https://github.com/openark/orchestrator/blob/master/docs/topology-recovery.md "Orchestrator Topology Recovery"
[7]: https://github.com/openark/orchestrator/blob/master/docs/failure-detection.md "Orchestrator Failure Detection"
[8]: https://dev.mysql.com/doc/refman/8.4/en/mysql-innodb-cluster-introduction.html "MySQL 8.4 InnoDB Cluster Introduction"
[9]: https://dev.mysql.com/doc/mysql-router/8.4/en/mysql-router-innodb-cluster.html "MySQL Router 8.4: Routing for InnoDB Cluster"
[10]: https://dev.mysql.com/doc/refman/8.4/en/group-replication-requirements.html "MySQL 8.4 Group Replication Requirements"
[11]: https://dev.mysql.com/doc/mysql-shell/8.4/en/admin-api-overview.html "MySQL Shell 8.4 AdminAPI Overview"

---

**作者：Manus AI**  
**状态：** 架构兼容性评估完成；尚未实施新的 5.7 与 8.4 专用模块。 
