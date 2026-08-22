# mysql-scripts 代码审查与 MySQL 8.4 适配报告

> **审查对象：** `wangzhenye2019/mysql-scripts`，审查基线提交 `733eea3`。  
> **审查结论：** 原仓库具备运维脚本的基本结构，但不能按 README 所述直接视为“生产级”。本次已完成四个核心脚本的 MySQL 8.4 安全适配；MGR、Keepalived、MHA 三类高可用脚本仍应视为**需重构与隔离演练的候选代码**，不建议直接上线。

## 1. 审查范围与方法

本次审查覆盖仓库的 7 个 Shell 脚本和 README，重点检查 Shell 语义、幂等性、危险操作边界、凭据管理、MySQL 8.4 参数兼容性、备份可恢复性、异步复制初始化和监控自愈隔离性。审查方法包括 Bash 语法检查、ShellCheck 静态检查、关键路径人工复核，以及与 MySQL 和 Percona XtraBackup 官方文档的交叉核对。

| 维度 | 方法 | 结果 |
|---|---|---|
| Bash 语法 | 对全部 `*.sh` 执行 `bash -n` | **全部通过** |
| 核心脚本静态检查 | 对单实例、备份恢复、Source-Replica、健康监控执行 ShellCheck | 无阻断错误；保留 15 条以未使用变量、动态 `source` 为主的提示级告警 |
| 配置文件权限 | 以测试配置验证安全加载逻辑 | `0600` 文件可加载，`0644` 文件被拒绝 |
| 无副作用入口 | 执行 3 个核心脚本的 `--help` | **全部通过** |
| 代码格式 | `git diff --check` | **通过** |

> 本次没有连接真实 MySQL 实例、真实多节点 SSH 网络或生产数据盘执行安装、恢复和故障切换。因此，本报告证明的是**静态正确性与安全边界改进**，不是替代全链路集成测试或灾备演练的生产验收。

## 2. 总体判断

仓库的主要问题不是单纯的 Shell 风格，而是若干核心流程存在“看似成功、实际不可用”的实现。例如，原备份脚本把 `xbstream` 二进制流写给了日志管道，但清理和恢复逻辑又假定 `.xbstream` 文件存在；原主从脚本用单引号 here-document 生成远程配置，导致远端 `my.cnf` 保留 `${MYSQL_PORT}` 等字面占位符；健康监控则可能对同机所有 `mysqld` 执行 `pkill -9`。这些问题均可能造成**备份不可恢复、复制无法启动或误伤多实例**。

MySQL 8.4 还强化了仓库的兼容性风险。`mysql_native_password` 在 8.4 中默认禁用，使用该插件创建或修改用户可能直接失败；复制接口已提供 Source/Replica 术语及对应语句，`CHANGE REPLICATION SOURCE TO`、`STOP REPLICA`、`START REPLICA` 与 `SHOW REPLICA STATUS` 是本次适配的目标接口。[1] [2]

| 风险等级 | 数量 | 结论 |
|---|---:|---|
| P0：可能导致数据丢失、误恢复或核心功能不可用 | 6 | 已在四个核心脚本中修复或增加显式阻断 |
| P1：可能导致安全暴露、复制不一致或错误自愈 | 8 | 核心路径已缓解；HA 脚本仍有遗留 |
| P2：性能、可维护性和文档一致性问题 | 10+ | 需纳入后续重构与测试计划 |

## 3. 关键发现与处理状态

| 编号 | 原始问题 | 影响 | 处理状态 |
|---:|---|---|---|
| P0-01 | 单实例脚本在 here-document 展开前引用未定义的 `innodb_buffer_pool_instances`；在 `set -u` 下会中止 | 默认安装无法生成 `my.cnf` | **已修复**：在生成文件前完成变量计算 |
| P0-02 | 流式 XtraBackup 输出被 `tee` 到日志，未落盘为 `.xbstream` | 备份列表、清理与恢复找不到实际归档 | **已修复**：标准输出写入归档、标准错误进入日志、生成 SHA-256 sidecar |
| P0-03 | 恢复流程含 `compfind` 拼写错误，且以 `qpress` 解压，与 XtraBackup 8.4 默认 ZSTD 压缩语义不匹配 | 恢复会失败或得到不完整数据目录 | **已修复**：改用 `xtrabackup --decompress --remove-original` 后再 `--prepare` |
| P0-04 | 恢复前直接清空数据目录，并使用 `pkill` 兜底，没有二次确认 | 错误配置可能误删数据或终止其他实例 | **已修复**：要求 `restore --yes`、强制绝对路径、校验目标目录、仅停止目标 systemd unit |
| P0-05 | 主从脚本以单引号 here-document 写入 Master 配置 | 远端配置出现未展开的 `${...}` 文本 | **已修复**：以本地受控变量展开后通过 SSH 写入远端文件 |
| P0-06 | 主从脚本用 `rsync --delete` 同步运行中的数据目录 | 数据不一致且可能删除副本端文件 | **已修复**：禁止在线数据目录 rsync，要求先用 XtraBackup 或 CLONE 一致性置备并显式确认 |
| P1-01 | MySQL 8.4 单实例仍强制 `mysql_native_password` | 默认环境下用户修改失败 | **已修复**：切换为 `caching_sha2_password` [1] |
| P1-02 | 主从与监控脚本使用旧的 `SLAVE` / `MASTER` 复制语句和字段 | 与现代接口、告警规则和文档不一致 | **已修复**：核心路径改为 Source/Replica 语义 [2] |
| P1-03 | 健康监控按进程名检查并 `pkill -9 mysqld` | 多实例主机可能被误伤 | **已修复**：按 `mysql<port>.service` 管理，移除全局 kill |
| P1-04 | 监控锁文件不保证退出清理；命令参数在命令分支后才解析 | 僵尸锁阻止监控重启，`start --interval 60` 无效 | **已修复**：加入 `trap`，改为先解析选项后执行命令 |
| P1-05 | 管理、备份、复制密码硬编码于脚本 | 凭据泄露到 Git、镜像、Shell 历史和审计日志 | **核心脚本已修复**：取消默认密码，配置文件仅接受当前用户或 root 所有且权限不高于 `0600` |
| P1-06 | 下载二进制仅依赖网络下载结果 | 供应链完整性不可验证 | **已缓解**：默认禁用自动下载，支持 `MYSQL_PACKAGE_SHA256` 校验；上线应强制提供官方校验值 |
| P2-01 | README 宣称 5.7/8.0/8.4、MySQL/Percona/GreatSQL 均可用 | 用户可能把未验证组合用于生产 | **已修订**：明确 MySQL 8.4 为当前适配目标，其他组合需独立测试 |
| P2-02 | README 的 Buffer Pool、连接数“自动调优”说明与实际代码并不完全一致 | 容量规划预期错误 | **待重构**：需把性能模型独立为可测试的配置层 |
| P2-03 | README 展示 MIT 徽章，但仓库根目录未见 `LICENSE` 文件 | 许可证声明与文件资产不一致 | **待处理**：补充经权利人确认的许可证文本 |

## 4. 已实施的适配内容

本次改动保持“先阻止危险行为，再恢复正确工作流”的原则，改动位于 5 个文件：`mysql_install_single.sh`、`mysql_backup_restore.sh`、`mysql_install_master_slave.sh`、`mysql_health_monitor.sh` 和 `README.md`。变更统计为 **355 行新增、346 行删除**；这不是格式化提交，而是面向故障模式的定向修复。

### 4.1 单实例安装

单实例安装脚本默认目标调整为 MySQL 8.4，取消硬编码密码与自动下载默认值。它支持由 `MYSQL_PACKAGE_SHA256` 验证预下载的二进制包，并使用更严格的 HTTPS 下载参数作为显式开启自动下载时的兜底。账户初始化改用 `caching_sha2_password`，符合 MySQL 8.4 的默认认证策略。[1]

配置生成环节修复了未定义变量问题，采用 `binlog_expire_logs_seconds` 代替旧的按天保留参数，采用 `log_replica_updates`，并不再写入旧复制元数据仓库参数。服务启动与停止统一交给 systemd，避免产生脱离服务管理的后台进程。

### 4.2 备份与恢复

Percona 文档明确说明 `--stream` 会将 xbstream 数据写到标准输出，且流式备份必须在恢复前完成 prepare。[3] 原实现因此无法满足自身的清理和恢复约定。本次修复将标准输出保存为 `${timestamp}.xbstream`，记录 SHA-256，并在恢复前校验 sidecar（如存在）。

XtraBackup 8.4 的 `--compress` 默认采用 ZSTD；官方推荐用 `xtrabackup --decompress` 处理已压缩备份，再执行 `--prepare`。[3] [4] 脚本已按此流程替换原先错误的 `qpress` 路径，并根据 `MYSQL_VERSION` 选择 `percona-xtrabackup-84`、`-80` 或 `-24` 包名。需要注意，Percona 说明 XtraBackup 8.4 面向由 8.4 系列创建的数据库，因此不能把“工具装得上”理解为跨大版本恢复保证。[5]

### 4.3 Source-Replica 复制

脚本改用 GTID 自动定位和 MySQL 8.4 的 Source/Replica 接口。官方文档指出，副本应具有唯一 `server_id`；复制拓扑需要在副本启用 binary log 和 `log_replica_updates` 的相应能力。[2] 适配后，脚本要求调用方先完成一致性数据置备，再设置 `REPLICAS_PROVISIONED=true`，从而避免原先在线 `rsync` 数据目录的高风险做法。

当前脚本仍会通过 SSH 传递 MySQL 客户端密码，因此**建议下一阶段改为 TLS 客户端证书或远端受限 defaults 文件**，并将复制账户的允许来源从 `%` 收敛到实际副本地址或网段。

### 4.4 健康监控

监控脚本的自愈动作从全局 `pgrep/pkill` 改为目标服务单元操作，锁文件也按端口命名并用 `trap` 清理。复制检查切换到 `SHOW REPLICA STATUS` 与 `Replica_IO_Running`、`Replica_SQL_Running` 字段。对 `set -e` 环境中的后置自增表达式改为前置自增，避免首次计数时因返回状态为 1 而异常退出。

## 5. 未完成适配的高风险脚本

下表所列脚本已纳入审查，但本次没有进行大规模修改；原因是它们牵涉真正的故障转移、网络地址漂移和集群成员重建，无法仅靠静态修补而安全地宣称可用。它们应在独立分支、隔离环境和可重复测试框架中重构。

| 脚本 | 主要风险 | 建议处置 |
|---|---|---|
| `mysql_install_mgr.sh` | 硬编码凭据、关闭 Host Key 校验、`rsync --delete`、以 `pkill -9` 模拟故障 | 先重构认证、数据置备和故障演练流程；增加 3 节点集成测试后再启用 |
| `mysql_install_keepalived.sh` | MySQL 探活采用无密码 root，与单实例脚本冲突；Keepalived 配置存在可疑拼写与掩码写法 | 暂停生产使用；用真实 VIP 迁移演练和 `keepalived -t` 验证后重写 |
| `mysql_install_mha.sh` | 下载、解压、远程执行大量 `|| true`；变量展开和 failover Perl 逻辑不完整 | 不宜直接使用；优先评估 MySQL Router + InnoDB Cluster / MGR 等现代方案，或完整维护 MHA 分支 |

## 6. 建议的上线门槛

在任何生产执行前，应满足下列门槛。它们既是技术验收条件，也是防止“脚本已通过静态检查”被误解为“可直接上线”的控制点。

| 阶段 | 必须完成的验收 | 通过标准 |
|---|---|---|
| 供应链 | 固定 MySQL、XtraBackup、OS 版本；校验二进制 SHA-256 | 每个安装包的来源、哈希、下载日期可追溯 |
| 单实例 | 在 Rocky 9 或 Ubuntu LTS 的隔离主机执行安装 | systemd 正常、`mysqladmin ping` 成功、配置无 deprecated/unknown variable |
| 备份恢复 | 备份后在新主机恢复同版本实例 | 校验归档哈希、`--prepare` 成功、业务校验 SQL 与对象计数一致 |
| 复制 | 用 XtraBackup/CLONE 创建副本，执行 GTID 复制 | `SHOW REPLICA STATUS` 双线程为 Yes，写入校验和延迟阈值满足 SLO |
| 自愈 | 模拟目标服务失败与非目标实例共存 | 仅重启指定 service，锁文件按预期清理，告警可达 |
| HA | 断网、进程退出、磁盘满、脑裂等故障演练 | 依据 RPO/RTO 与人工介入流程签字通过，不依赖脚本“自动成功” |

## 7. 推荐的后续重构顺序

首先应建立 `lib/` 公共库，把日志、参数校验、机密加载、OS 检测、命令执行、SSH 选项和 systemd 操作统一实现。其次，应使用 Bats 或 ShellSpec 为参数解析、配置渲染、归档清理和恢复确认建立单元测试；再使用容器或虚拟机组建 MySQL 8.4 的单机、Source-Replica、MGR、备份恢复集成测试矩阵。最后才应考虑让 Keepalived/MHA 的自动故障转移具备生产发布资格。

性能调优不应继续依赖散落在 heredoc 中的固定值。应以“可用内存、cgroup 限额、CPU 核数、存储介质、连接池上限、业务写入模式”为输入，输出可审阅的配置文件和变更说明。特别是 `max_connections`、Buffer Pool、IO capacity、binlog 保留时间必须与容量测算、监控阈值和恢复目标相一致。

## 8. 使用本次适配

本报告与适配代码已直接同步至仓库。更新后，建议在目标主机的干净工作树中执行以下最小回归检查：

```bash
bash -n *.sh
shellcheck -S warning mysql_install_single.sh mysql_backup_restore.sh \
  mysql_install_master_slave.sh mysql_health_monitor.sh
```

请不要把密码重新写回脚本。建议先创建 root 所有、权限为 `0600` 的配置文件，再通过 `-c` 参数加载；调用单实例安装器前还应对实际下载的 MySQL 二进制提供 `MYSQL_PACKAGE_SHA256`。

## References

[1]: https://dev.mysql.com/doc/refman/8.4/en/native-pluggable-authentication.html "MySQL 8.4 Native Pluggable Authentication"
[2]: https://docs.oracle.com/cd/E17952_01/mysql-8.4-en/replication-howto-slavebaseconfig.html "MySQL 8.4: Setting the Replica Configuration"
[3]: https://docs.percona.com/percona-xtrabackup/8.4/take-streaming-backup.html "Percona XtraBackup 8.4: Take a Streaming Backup"
[4]: https://docs.percona.com/percona-xtrabackup/8.4/prepare-compressed-backup.html "Percona XtraBackup 8.4: Decompress and Prepare a Backup"
[5]: https://docs.percona.com/percona-xtrabackup/8.4/quickstart-overview.html "Percona XtraBackup 8.4: Quickstart Overview"
[6]: https://dev.mysql.com/doc/refman/8.4/en/replication-options-reference.html "MySQL 8.4 Replication and Binary Logging Options"

---

**作者：Manus AI**  
**结论状态：** 静态审查与核心安全适配完成；生产验收待真实环境集成测试和灾备演练。 
