# MySQL 自动化运维 Shell 脚本集

本目录包含从 dbops (Ansible 版本) 转换而来的 Shell 脚本，用于 MySQL 自动化部署、高可用和备份恢复。

> 源项目: [dbops/mysql_ansible](https://github.com/yml/workspace/01_Projects/dbops)

## 架构概览

```
┌─────────────────────────────────────────────────────────────────────┐
│                    MySQL 自动化运维架构                              │
├─────────────────────────────────────────────────────────────────────┤
│                                                              │
│  1. 单节点部署  ──────────────────► 单机版 MySQL                 │
│                                                              │
│  2. 主从复制  ──────────────────► Master-Slave 架构              │
│     - 读写分离                                               │
│     - 数据冗余                                                 │
│                                                              │
│  3. MGR 集群  ──────────────────► MySQL Group Replication     │
│     - 自动选举主库                                              │
│     - 数据强一致性                                             │
│     - 单主/多主模式                                            │
│                                                              │
│  4. Keepalived HA  ────────────────► 双主+VIP漂移                │
│     - 自动故障检测                                             │
│     - VIP 自动漂移                                             │
│                                                              │
│  5. MHA  ───────────────────────────► 一主两从+MHA Manager       │
│     - 自动故障转移                                             │
│     - 零数据丢失                                              │
│                                                              │
│  6. 备份恢复  ─────────────────────► Xtrabackup 物理备份         │
│     - 全量+增量                                               │
│     - 自动清理                                                │
│                                                              │
│  7. 故障自愈  ─────────────────────► 健康检查+自动恢复           │
│     - 多维度检测                                              │
│     - 自动重启                                                │
│     - 告警通知                                               │
│                                                              │
└─────────────────────────────────────────────────────────────────────┘
```

## 脚本列表

### 1. 基础部署

| 脚本 | 说明 | 对应Ansible版本 |
|------|------|-------------|
| [mysql_install_single.sh](scripts/mysql_install_single.sh) | 单节点安装 | `single_node.yml` |
| [mysql_install_master_slave.sh](scripts/mysql_install_master_slave.sh) | 主从复制安装 | `master_slave.yml` |

### 2. 高��用集群

| 脚本 | 说明 | 对应Ansible版本 |
|------|------|-------------|
| [mysql_install_mgr.sh](scripts/mysql_install_mgr.sh) | MGR集群安装 | `mgr.yml` |
| [mysql_install_keepalived.sh](scripts/mysql_install_keepalived.sh) | Keepalived HA | `keepalived_master_slave.yml` |
| [mysql_install_mha.sh](scripts/mysql_install_mha.sh) | MHA高可用 | `mha.yml` |

### 3. 备份恢复

| 脚本 | 说明 | 对应Ansible版本 |
|------|------|-------------|
| [mysql_backup_restore.sh](scripts/mysql_backup_restore.sh) | 备份恢复 | `backup_script.yml` |

### 4. 监控自愈

| 脚本 | 说明 |
|------|------|
| [mysql_health_monitor.sh](scripts/mysql_health_monitor.sh) | 故障自愈监控 |

## 使用示例

### 1. 单节点安装

```bash
# 基本安装
./mysql_install_single.sh

# 指定版本和端口
./mysql_install_single.sh -v 8.4.6 -p 3306 -t mysql

# 使用配置文件
./mysql_install_single.sh -c /path/to/config.ini
```

### 2. 主从复制安装

```bash
# 配置主从
./mysql_install_master_slave.sh

# 指定从库
export SLAVE_IPS=("192.168.199.132" "192.168.199.133")
./mysql_install_master_slave.sh
```

### 3. MGR集群安装

```bash
# 安装单主模式MGR
./mysql_install_mgr.sh

# 指定节点
export MGR_HOSTS=("192.168.199.131" "192.168.199.132" "192.168.199.133")
./mysql_install_mgr.sh
```

### 4. Keepalived HA

```bash
# 安装Keepalived双主
./mysql_install_keepalived.sh

# 指定VIP
export WRITE_VIP=192.168.199.200
./mysql_install_keepalived.sh
```

### 5. 备份恢复

```bash
# 执行备份
./mysql_backup_restore.sh backup

# 恢复数据
./mysql_backup_restore.sh restore /path/to/backup.xbstream

# 查看备份列表
./mysql_backup_restore.sh list

# 安装xtrabackup
./mysql_backup_restore.sh install

# 设置定时任务
./mysql_backup_restore.sh cron
```

### 6. 故障自愈监控

```bash
# 启动监控
./mysql_health_monitor.sh start

# 查看状态
./mysql_health_monitor.sh status

# 手动检测
./mysql_health_monitor.sh check

# 强制自愈
./mysql_health_monitor.sh heal

# 停止监控
./mysql_health_monitor.sh stop
```

## 参数说明

### 通用参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-v, --version` | 8.4.6 | MySQL版本 |
| `-p, --port` | 3306 | MySQL端口 |
| `-t, --type` | mysql | 数据库类型(mysql/percona/greatsql) |
| `-s, --specs` | auto | 服务器规格(auto/4c8g/8c16g) |

### MySQL配置

| 变量 | 默认值 | 说明 |
|------|--------|------|
| MYSQL_USER | mysql | 运行用户 |
| MYSQL_ADMIN_USER | admin | 管理用户 |
| MYSQL_ADMIN_PASSWORD | Dbops@8888 | 管理密码 |
| MYSQL_DATA_DIR_BASE | /database/mysql | 数据目录 |

### HA配置 (Keepalived)

| 变量 | 默认值 | 说明 |
|------|--------|------|
| WRITE_VIP | 192.168.199.200 | 写入VIP |
| MASTER_IP | - | 主节点IP |
| BACKUP_IP | - | 备节点IP |

### MGR配置

| 变量 | 默认值 | 说明 |
|------|--------|------|
| MGR_SINGLE_PRIMARY | true | 单主模式 |
| MGR_PORT | 13306 | MGR通信端口 |

## 目录结构

```
scripts/
├── mysql_install_single.sh          # 单节点安装
├── mysql_install_master_slave.sh    # 主从复制
├── mysql_install_mgr.sh            # MGR集群
├── mysql_install_keepalived.sh      # Keepalived HA
├── mysql_install_mha.sh           # MHA高可用
├── mysql_backup_restore.sh         # 备份恢复
├── mysql_health_monitor.sh     # 故障自愈
└── README.md                   # 本文件
```

## 依赖要求

### 系统要求

- Linux (RHEL/CentOS/Rocky 7+/Ubuntu 18.04+)
- MySQL 5.7+ / 8.0+ / GreatSQL
- SSH免密登录(多节点环境)
- root权限

### 依赖软件

- MySQL二进制包 (下载到 downloads 目录)
- Xtrabackup (备份脚本需要)
- Keepalived (HA脚本需要)
- MHA Manager (MHA脚本需要)

### SSH免密登录

```bash
# 生成SSH密钥
ssh-keygen -t rsa -N '' -f ~/.ssh/id_rsa

# 复制到所有节点
ssh-copy-id -o StrictHostKeyChecking=no user@host
```

## 注意事项

1. **生产环境谨慎**: 首次建议在测试环境验证
2. **数据备份**: 部署前确保有有效备份
3. **VIP规划**: 提前规划好VIP和网络
4. **密码安全**: 生产环境请修改默认密码
5. **防火墙**: 确保3306端口可访问
6. **资源规划**: 根据服务器规格调整参数

## 告警配置

配置企业微信/钉钉 webhook:

```bash
# 环境变量
export ALERT_WEBHOOK="https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxx"

# 启动监控
./mysql_health_monitor.sh start --enable-alert
```

## 故障排查

### 无法连接MySQL

```bash
# 检查进程
ps aux | grep mysqld

# 检查端口
netstat -tuln | grep 3306

# 检查日志
tail -f /database/mysql/error.log
```

### 主从复制异常

```bash
# 查看复制状态
mysql -e "SHOW SLAVE STATUS\G"

# 检查错误日志
tail -f /var/log/mha/app.log
```

### Keepalived VIP不漂移

```bash
# 检查Keepalived状态
systemctl status keepalived

# 检查日志
tail -f /var/log/keepalived/check_mysql.log
```

## 相关文档

- [Ansible版本源码](https://github.com/yml/workspace/01_Projects/dbops)
- [MySQL官方文档](https://dev.mysql.com/doc/refman/8.0/en/)
- [GreatSQL文档](https://docs.greatdb.com/)
- [Xtrabackup文档](https://www.percona.com/docs/xtrabackup)

## License

MIT License - See source project for details.