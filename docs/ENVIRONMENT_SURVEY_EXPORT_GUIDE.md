# MySQL 环境巡检导出指南

本指南用于收集 13 套 MySQL 环境的**现网事实**，为风险评估、高可用架构设计、切换 Runbook 和运维交接文档提供可审计输入。巡检脚本为只读脚本：不会修改 MySQL、系统参数、复制状态、Group Replication、VIP、Router 或定时任务；不会导出密码、授权语句、业务数据、SQL 文本和表定义。

> **执行范围：** 每一个 MySQL 节点各执行一次。对于 MySQL Router 独立部署的环境，也建议在每个 Router 主机上执行一次，并将 `--role` 标为 `router-node`；该主机若没有 MySQL client 连通性，可仅保留系统层输出并单独说明。

## 1. 准备受限只读账号

在每个数据库实例上，使用最小权限的巡检账号，并把凭据写入仅 root 可读的客户端配置文件。不要把密码作为脚本参数、shell 历史、Git 文件或聊天文本传递。

```ini
# /root/.my-survey.cnf
[client]
user=survey_ro
password=请通过受控渠道写入真实密码
host=127.0.0.1
port=3306
protocol=TCP
```

```bash
sudo chown root:root /root/.my-survey.cnf
sudo chmod 0600 /root/.my-survey.cnf
```

巡检账号至少需要连接、全局状态/变量、`information_schema` 和 `performance_schema` 的只读权限。若账号没有权限读取某项，脚本会将其记录在 `collection.log`；这不影响其他事实的采集。

## 2. 执行方式

将仓库同步到目标节点后，逐节点执行脚本。建议输出目录使用受限权限的临时路径，并在汇总后通过受控通道上传，不要发送默认包含服务器 IP、端口与容量信息的原始目录到公开位置。

```bash
cd /opt/mysql-scripts
sudo ./tools/export_mysql_environment_survey.sh \
  --mysql-defaults /root/.my-survey.cnf \
  --environment prod \
  --cluster RA \
  --role primary \
  --output-dir /var/tmp/mysql-survey-export
```

脚本会生成一个带时间戳、权限为 `0700` 的目录：

| 文件 | 内容 | 用途 |
|---|---|---|
| `summary.md` | 节点级可读摘要 | 供人工复核和环境调研报告引用。 |
| `facts.tsv` | 键值形式事实表 | 供 Excel、CSV 或汇总脚本整理。 |
| `mysql_raw.txt` | MySQL 状态、容量、复制/组复制结果 | 供 DBA 复核；不包含业务数据。 |
| `system_raw.txt` | OS、内存、磁盘、网络、服务和 timer 信息 | 供系统与备份/监控现状评估。 |
| `collection.log` | 缺失权限、查询失败等采集告警 | 供补采和权限修复。 |

## 3. 已知四套集群的执行清单

下表根据当前已提供的节点与 VIP 信息整理。每一行均需在对应节点本机执行；`--role` 请按真实主从或成员角色修改，暂不确定时填 `unknown`，脚本仍会采集事实。

| 集群 | MySQL 版本目标 | 节点 | VIP | 建议命令中的集群名 |
|---|---|---|---|---|
| 外挂集群 | 8.4 | `192.168.132.96`、`.97`、`.98` | `192.168.132.99` | `external` |
| RA 集群 | 5.7.44 | `192.168.134.96`、`.97`、`.98` | `192.168.134.99` | `RA` |
| CA 集群 | 5.7.44 | `192.168.136.96`、`.97`、`.98` | `192.168.136.99` | `CA` |
| KM 集群 | 5.7.44 | `192.168.138.96`、`.97`、`.98` | `192.168.138.99` | `KM` |

例如，在外接 MySQL 8.4 集群的节点 `192.168.132.96` 上执行：

```bash
sudo ./tools/export_mysql_environment_survey.sh \
  --mysql-defaults /root/.my-survey.cnf \
  --environment prod \
  --cluster external \
  --role unknown \
  --output-dir /var/tmp/mysql-survey-export
```

同一集群三台节点都完成后，请保留每个输出目录。对于 5.7 集群，在确认当前主库后可把主库标为 `primary`，副本标为 `replica`；对于 8.4 集群，在确认 PRIMARY 成员后可标为 `primary`，其余成员标为 `replica`。

## 4. 汇总与回传

请将每一个节点的**完整输出目录**打包为独立压缩包，再上传或提供可访问路径。这样既能保留原始事实，也能避免不同节点文件相互覆盖。

```bash
cd /var/tmp/mysql-survey-export
sudo tar -C /var/tmp/mysql-survey-export -czf "$(hostname -s)-mysql-survey-$(date -u +%Y%m%dT%H%M%SZ).tar.gz" \
  "实际生成的节点目录名"
sudo chmod 0600 *-mysql-survey-*.tar.gz
```

收到 13 套环境的导出结果后，将按统一口径生成四份正式文档。对于暂缺的环境，报告会明确标记为“待调研”，不会将推测内容写成现网事实。

---

**作者：Manus AI**
