# Debian 12 MySQL 高可用自动化运行手册

本仓库新增的模块面向 **Debian 12**，并严格区分两类数据库平台：`mysql57_orchestrator_ha/` 仅服务于必须保留 MySQL 5.7.44 的遗留业务；`mysql84_innodb_cluster/` 仅服务于官方 MySQL 8.4 InnoDB Cluster。两套模块不可混用配置、二进制、数据目录、socket、systemd service 或故障切换逻辑。

> **生产安全原则：** 自动化脚本并不替代故障演练。所有会启动、提升、重启、加入、重入或切换集群成员的命令均需要显式 `--apply`、`--restart` 或受控演练开关。先在隔离三节点环境完成验收，再配置生产自动恢复。

## 1. MySQL 5.7.44：增强半同步、Orchestrator 与写 VIP

MySQL 5.7.44 是 5.7 系列的最终版本，官方建议升级至 8.0、8.4 或 Innovation 系列。[1] 因此该模块仅适用于无法立即迁移的遗留工作负载，必须具有版本冻结、离线安装包校验、漏洞补偿和迁出计划。

增强半同步应使用 `rpl_semi_sync_master_wait_point=AFTER_SYNC`。此等待点下，源库在至少一个副本写入并刷盘确认后再提交存储引擎并向客户端成功返回；官方将此条件下的主库意外故障并切换到副本描述为 lossless。[2] 一旦确认超时，MySQL 将回退异步复制，因此本仓库会额外部署本机写入安全门禁：状态不为 `Rpl_semi_sync_master_status=ON` 或确认副本数量不足时，该节点被立即设置为 `super_read_only=ON` 与 `read_only=ON`。该门禁用于缩小失效窗口，但不能替代代理层写流量封禁和权威 fencing。

| 顺序 | 操作 | 验收条件 |
|---|---|---|
| 1 | 将 `config/examples/mysql57_ha.env.example` 复制到每个节点的受限配置文件，权限设为 `0600`。 | 所有密码均不在命令行、Git 或日志中出现。 |
| 2 | 安装经 SHA-256 校验的 MySQL 5.7.44 二进制，并在每个节点执行 `01_prepare_instance.sh --config …`。 | `mysqld --validate-config` 成功，GTID、ROW binlog 和 durability 参数完整。 |
| 3 | 每个节点执行 `02_configure_lossless_semisync.sh --config … --apply --install-guard`。 | `AFTER_SYNC` 已生效；安全门禁 timer 为 active。 |
| 4 | 使用一致性物理备份或已审计置备流程恢复副本，然后执行 `03_join_gtid_replica.sh --config … --source 主库 --provisioned`。 | `Slave_IO_Running` 和 `Slave_SQL_Running` 都为 `Yes`。 |
| 5 | 将 Orchestrator release `.deb` 及其可信 SHA-256 放至控制节点，执行 `04_deploy_orchestrator.sh`。 | Orchestrator 已发现完整 GTID 拓扑；自动主故障恢复仍保持关闭。 |
| 6 | 实现并测试 `VIP_FENCING_COMMAND`。 | 可证明旧主在网络分区、SSH 失联、系统挂死时均无法继续写入。 |
| 7 | 执行 `05_preflight_and_drill.sh --config …`。 | 半同步状态、确认副本数、GTID 与 Orchestrator 分析全部通过。 |
| 8 | 在变更窗口做 controlled graceful takeover 和故障注入。 | 确认新主、VIP、应用写入口、旧主隔离和回归重建均符合 SOP。 |

Orchestrator 的自动恢复必须显式 opt-in。其恢复 hook 能将前置 fencing 与成功后 VIP 发布纳入同一恢复事务：`PreFailoverProcesses` 返回非零会终止恢复；`PostMasterFailoverProcesses` 仅在提升成功后执行。[3] 仓库将 `RecoverMasterClusterFilters` 初始化为空数组，避免新部署在未演练前自动切换。验收完成后才可将其限制为明确的 cluster alias，而不是使用通配符。

> **不要将旧的 `mysql_install_keepalived.sh` 与新的 Orchestrator/VIP hook 并行用于同一个写 VIP。** 两套独立状态机同时争抢 VIP 会破坏 fencing 假设并产生双写风险。

## 2. MySQL 8.4：InnoDB Cluster、MySQL Shell 与 MySQL Router

MySQL 官方将 InnoDB Cluster 定义为至少三个 MySQL Server 实例配合 Group Replication、MySQL Shell 和 MySQL Router 的集成高可用方案。[4] 在成员加入集群后，官方要求通过 MySQL Shell AdminAPI 管理，而不支持手工修改关键 Group Replication 配置或手工 `START GROUP_REPLICATION`。[5]

| 顺序 | 操作 | 验收条件 |
|---|---|---|
| 1 | 将 `config/examples/mysql84_innodb_cluster.env.example` 复制为受限配置文件。 | 使用官方 MySQL 8.4 Server、Shell 和 Router；三者主版本为 8.4。 |
| 2 | 对每个节点运行 `01_prepare_node.sh --config … --instance HOST:3306 --server-id ID --install-packages --restart`。 | Node 的 `server_id` 唯一，GTID、ROW、`log_replica_updates` 和 TLS 基线完整。 |
| 3 | 每个节点执行 `02_preflight_instance.sh --config … --instance HOST:3306`。 | 无非 InnoDB 业务表；每张业务表都有主键或非空唯一键；AdminAPI 预检通过。 |
| 4 | 在受控窗口执行 `03_create_cluster.sh --config … --apply --configure-instances`。 | `cluster.status({extended:1})` 显示 3 个 ONLINE 成员和唯一 PRIMARY。 |
| 5 | 在每个应用节点或 Router 节点执行 `04_bootstrap_router.sh --config …`。 | Router RW 6446、RO 6447 等端口可监听；应用只连接 Router。 |
| 6 | 使用 `05_operate_cluster.sh --config … --status` 做日常状态采集。 | 不直接执行 Group Replication SQL；成员重入与恢复账号轮换均经 AdminAPI。 |

Group Replication 要求业务可复制表使用 InnoDB 并且存在主键或非空唯一键，成员之间保持双向通信，同时需配置唯一 `server_id`、binary log、ROW 格式、GTID 与 `log_replica_updates`。[6] `02_preflight_instance.sh` 将这些条件作为入群门槛，而不是在创建集群后才发现问题。

MySQL Router 通过 `--bootstrap` 从集群 metadata 获取路由配置，并在拓扑变更时自动调整连接目的地，因此应用不需要自行感知 PRIMARY 变化。[7] Router bootstrap 会创建 Router 专用 metadata 账户和随机密码；仓库的脚本将管理员密码以受控交互方式传给 bootstrap，不把它写入参数、环境变量、日志或配置文件。[8]

## 3. 验收与回退

生产启用前，两个架构都至少应覆盖主机断电、进程终止、磁盘写满、数据库端口单向阻断、数据库网络分区、控制平面/Router 不可用、旧主回归、备份恢复和应用长连接重连。成功标准不是“脚本没有报错”，而是已确认写事务不丢失（5.7 条件化 RPO=0）、任意时刻只有一个写主、应用在目标 RTO 内恢复、审计日志可复盘。

回退策略必须区分架构。5.7 非计划主切换后的旧主不可直接再次作为复制源，因为它可能含有未被副本确认的事务。[2] 应将其隔离、备份证据、重新从已提升主库置备。8.4 成员需要通过 AdminAPI 的 rejoin/recovery 过程回归，不可修改 metadata 后手工启动 Group Replication。

## References

[1]: https://dev.mysql.com/doc/relnotes/mysql/5.7/en/news-5-7-44.html "MySQL 5.7.44 Release Notes"
[2]: https://dev.mysql.com/doc/refman/5.7/en/replication-semisync.html "MySQL 5.7 Semisynchronous Replication"
[3]: https://github.com/openark/orchestrator/blob/master/docs/configuration-recovery.md "Orchestrator Recovery Configuration"
[4]: https://dev.mysql.com/doc/refman/8.4/en/mysql-innodb-cluster-introduction.html "MySQL 8.4 InnoDB Cluster Introduction"
[5]: https://dev.mysql.com/doc/mysql-shell/8.4/en/create-cluster.html "Creating an InnoDB Cluster"
[6]: https://dev.mysql.com/doc/refman/8.4/en/group-replication-requirements.html "Group Replication Requirements"
[7]: https://dev.mysql.com/doc/mysql-shell/8.4/en/admin-api-bootstrapping-router.html "Bootstrapping MySQL Router"
[8]: https://dev.mysql.com/doc/mysql-router/8.4/en/mysqlrouter.html "MySQL Router 8.4 Command Line Options"

---

**作者：Manus AI**

## 4. 自动化巡检、监控与故障演练

新增的巡检脚本默认只读，不会启动复制、修改只读状态、重启服务或触发故障切换。它们使用统一的退出码：`0` 表示健康，`1` 表示降级但仍具备主要服务能力，`2` 表示不安全或关键异常，`3` 表示配置、依赖或管理接口不可用。外部监控平台应采集退出码和 JSON 输出，而不是仅依据进程存活判断数据库健康。

| 架构 | 巡检入口 | 覆盖范围 | 定时安装 |
|---|---|---|---|
| MySQL 5.7.44 | `mysql57_orchestrator_ha/06_monitor_health.sh --config … --json` | 半同步状态、确认副本数、GTID/durability、复制线程、Orchestrator API、VIP 与读写角色 | 加 `--install-systemd --interval 30` |
| MySQL 8.4 | `mysql84_innodb_cluster/06_monitor_cluster.sh --config … --json` | AdminAPI 集群状态、ONLINE 成员、PRIMARY 唯一性、Router service 与 RW/RO listener | 加 `--install-systemd --interval 30` |

5.7 的监控结果若显示半同步回退或确认副本数不足，应将其视为写入安全事件，而不只是复制告警。8.4 的监控脚本以 AdminAPI metadata 为准，不直接手工检查或启动 Group Replication。两者均可通过本机 systemd timer 以秒级周期运行；它们不会通过 Manus 定时任务执行。

故障演练脚本将危险操作与预检分离。`07_drill_orchestrator_failover.sh --mode preflight` 和 `07_drill_mgr_failover.sh --mode preflight` 只收集基线和阻断不合格演练。任何实际切换都要求 `--apply`、变更单号及受控配置；5.7 的注入模式还要求 `--acknowledge-production-impact`。本仓库不内置 `kill -9`、网络断开或数据目录复制等不安全动作。故障注入必须由运行环境提供、审计并显式配置为 `DRILL_FAULT_INJECTION_COMMAND`，例如 PDU、虚拟化平台或安全组隔离操作。

> **演练成功的最低标准：** 只有一个可写主库；监控状态符合预期；应用入口已恢复；证据目录保留了演练前后主库、Router/Orchestrator 状态与命令日志；故障成员只通过定义的重新置备或 AdminAPI rejoin 流程回归。

---

**作者：Manus AI**
