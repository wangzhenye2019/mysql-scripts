# Debian 12 MySQL 高可用架构适配：中文演讲脚本

**建议总时长：8–10 分钟。** 本讲稿按演示文稿可见页顺序编排，可用于现场讲解、录屏或技术评审。每页的“讲解词”可直接朗读；“衔接句”用于自然进入下一页。

| 页码 | 标题 | 建议时长 | 核心结论 |
|---:|---|---:|---|
| 1 | Debian 12 MySQL 高可用架构适配 | 40 秒 | 两个版本对应两套隔离的高可用模型。 |
| 2 | 两套架构，两个生命周期 | 60 秒 | 5.7 是受控过渡，8.4 是长期标准。 |
| 3 | 5.7 的 RPO=0 是条件化承诺 | 75 秒 | AFTER_SYNC、写入门禁和 fencing 缺一不可。 |
| 4 | Orchestrator 管拓扑，Hook 管 VIP | 70 秒 | 拓扑提升与网络入口需按同一状态机顺序执行。 |
| 5 | 8.4 采用官方原生控制面 | 70 秒 | 用 AdminAPI、InnoDB Cluster 与 Router 取代手工 MGR 管理。 |
| 6 | 新脚本把高风险动作拆开 | 60 秒 | 模块化将准备、预检、变更和演练隔离。 |
| 7 | 生产上线以演练结果为准 | 65 秒 | 自动恢复必须以故障演练证据为准。 |
| 8 | 推荐实施路径 | 55 秒 | 8.4 优先，5.7 仅作为有退出计划的过渡。 |
| 9 | 结论与依据 | 45 秒 | 版本专用模块、受控切换、先演练后启用。 |

## 第 1 页：Debian 12 MySQL 高可用架构适配

各位好。本次分享聚焦 Debian 12 下两类 MySQL 高可用部署：一类是仍需承载遗留业务的 MySQL 5.7.44，另一类是面向新业务的 MySQL 8.4。我们的目标不是把旧脚本简单改成“能运行”，而是分别建立可审计、可演练、可恢复的自动化路径。接下来先解释为什么两套版本必须从生命周期上分开治理。

> **衔接句：** 先明确平台定位，才能避免在后续设计中混淆复制机制和故障切换边界。

## 第 2 页：两套架构，两个生命周期

结论很明确：MySQL 5.7 是遗留过渡平台，MySQL 8.4 是长期标准平台。5.7 采用 GTID、增强半同步、Orchestrator 和受控写 VIP；8.4 则采用 InnoDB Cluster、AdminAPI 与 Router。两者不能共用二进制、配置目录、端口、socket、服务单元、密钥和切换脚本。只有彻底隔离，才能让升级、故障切换和回退都保持可预测。

> **衔接句：** 在这两个平台中，风险最高的是 5.7 的“零数据丢失”目标，因此下一页先说明它的严格前提。

## 第 3 页：5.7 的 RPO=0 是条件化承诺

MySQL 5.7 的 RPO=0 不是一个只靠打开半同步插件就能获得的标签。我们必须使用 `AFTER_SYNC`，确保成功响应返回前至少一个副本已经写入并刷盘。同时，监控必须持续检查半同步状态和确认副本数；一旦回退异步或确认副本不足，就需要立即阻断写入。最后，任何提升前都必须完成权威 fencing，避免网络分区下旧主继续写入。

> **衔接句：** 因此，数据库拓扑的提升和 VIP 的发布必须按固定顺序协同，而这正是 Orchestrator 与 Hook 的分工。

## 第 4 页：Orchestrator 管拓扑，Hook 管 VIP

Orchestrator 的职责是理解 GTID 拓扑、选择候选副本、执行提升并记录审计。它不应独自决定网络入口。我们在 Pre-failover Hook 中执行 STONITH、网络隔离或其他基础设施级 fencing；只要围栏失败，就必须终止提升。在 Post-failover Hook 中，只有当新主确认 `read_only` 和 `super_read_only` 均已关闭时，才发布写 VIP。不要让独立 Keepalived 与该流程争夺同一个 VIP。

> **衔接句：** 相比之下，8.4 可以使用官方原生控制面，将成员管理和流量重定向整合起来。

## 第 5 页：8.4 采用官方原生控制面

MySQL 8.4 的推荐做法是使用 MySQL Shell AdminAPI 配置实例、创建集群、加入成员和处理重入；集群本身使用 Group Replication 实现成员管理和自动选主；应用只连接 MySQL Router，而不直接感知 PRIMARY 的变化。入群前必须检查业务表引擎、主键或唯一键、GTID、ROW binlog、双向网络和 TLS。成员纳入 AdminAPI 管理后，不再手工启动或修改 Group Replication。

> **衔接句：** 为了让这些规则真正可执行，仓库把高风险行为拆成了版本专用的脚本模块。

## 第 6 页：新脚本把高风险动作拆开

本次重构将 5.7 和 8.4 的流程拆成独立模块。5.7 模块负责半同步、GTID、副本加入、Orchestrator 和 VIP Hook；8.4 模块负责节点预检、AdminAPI 建群、Clone 恢复和 Router bootstrap；公共基础库则负责 Debian 12 校验、受限配置、凭据文件与安全远程执行。所有有破坏性的操作都要求显式参数，例如 `--apply`、`--restart` 或演练确认。

> **衔接句：** 但脚本模块化并不等同于生产就绪，真正的生产门槛仍然是故障演练。

## 第 7 页：生产上线以演练结果为准

生产就绪不能只看脚本是否执行成功，而要看故障条件下是否仍满足唯一写主、事务可追溯和应用恢复目标。5.7 必须演练主机断电、网络分区、旧主回归和 VIP 漂移；8.4 必须验证成员失效、Router 路由切换、Clone 恢复和成员重入。自动恢复在初始部署时保持关闭，只有当隔离环境中的演练证据完整、可复盘后，才在变更窗口中显式启用。

> **衔接句：** 基于这个安全边界，最后给出建议的落地顺序。

## 第 8 页：推荐实施路径

建议先将 MySQL 8.4 InnoDB Cluster 加 Router 建设成新业务默认标准，因为它使用官方原生控制面，长期维护和拓扑治理更清晰。MySQL 5.7 仅服务于暂时无法迁移的遗留业务，并且必须有退出时间表。两类环境都应先完成密钥治理、备份恢复和定期演练，再逐步接入生产流量。最后一步永远是经过批准的演练后再启用自动恢复。

> **衔接句：** 最后用一句话总结本次适配方案的交付边界和技术依据。

## 第 9 页：结论与依据

本次方案证明在 Debian 12 上同时支持 MySQL 5.7 和 8.4 是可行的，但前提是坚持版本专用模块、受控故障切换和先演练后启用。5.7 的关键是增强半同步、写入门禁和 fencing 闭环；8.4 的关键是 AdminAPI、InnoDB Cluster 和 Router 的官方管理模型。所有实现和运行手册均以 MySQL 官方文档与 Orchestrator 文档为依据。谢谢，欢迎进入实现细节和演练范围的讨论。

## 参考资料

[1] MySQL 5.7 Semisynchronous Replication: https://dev.mysql.com/doc/refman/5.7/en/replication-semisync.html

[2] Orchestrator Recovery Configuration: https://github.com/openark/orchestrator/blob/master/docs/configuration-recovery.md

[3] MySQL 8.4 InnoDB Cluster: https://dev.mysql.com/doc/refman/8.4/en/mysql-innodb-cluster-introduction.html

[4] MySQL 8.4 Group Replication Requirements: https://dev.mysql.com/doc/refman/8.4/en/group-replication-requirements.html

[5] MySQL Router bootstrapping: https://dev.mysql.com/doc/mysql-shell/8.4/en/admin-api-bootstrapping-router.html

---

**作者：Manus AI**
