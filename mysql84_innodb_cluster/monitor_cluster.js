// MySQL Shell JavaScript used by 06_monitor_cluster.sh. Emits exactly one JSON object on the final line.
const required = ['IC_CLUSTER_NAME', 'IC_SEED_INSTANCE', 'IC_INSTANCES_CSV', 'IC_CLUSTER_ADMIN', 'IC_CLUSTER_ADMIN_PASSWORD'];
for (const key of required) {
  if (!os.getenv(key)) throw new Error(`Missing ${key}`);
}

const clusterName = os.getenv('IC_CLUSTER_NAME');
const seed = os.getenv('IC_SEED_INSTANCE');
const expectedCount = os.getenv('IC_INSTANCES_CSV').split(',').map(v => v.trim()).filter(Boolean).length;
const admin = os.getenv('IC_CLUSTER_ADMIN');
const password = os.getenv('IC_CLUSTER_ADMIN_PASSWORD');

function endpoint(value) {
  const separator = value.lastIndexOf(':');
  if (separator <= 0) throw new Error(`Invalid endpoint: ${value}`);
  return {scheme: 'mysql', host: value.slice(0, separator), port: Number(value.slice(separator + 1)), user: admin, password};
}

shell.connect(endpoint(seed));
const cluster = dba.getCluster(clusterName);
const report = cluster.status({extended: 1});
const topology = report.defaultReplicaSet && report.defaultReplicaSet.topology ? report.defaultReplicaSet.topology : {};
const members = Object.values(topology);
const online = members.filter(member => member.status === 'ONLINE').length;
const primary = members.filter(member => member.memberRole === 'PRIMARY' || member.mode === 'R/W').length;
const majority = Math.floor(expectedCount / 2) + 1;
let status = 0;
const messages = [];

if (online < majority) {
  status = 2;
  messages.push(`online-members-${online}-below-majority-${majority}`);
} else if (online < expectedCount) {
  status = 1;
  messages.push(`online-members-${online}-below-expected-${expectedCount}`);
}
if (primary !== 1) {
  status = 2;
  messages.push(`primary-count-${primary}`);
}
if (report.defaultReplicaSet && report.defaultReplicaSet.status && report.defaultReplicaSet.status !== 'OK') {
  if (status < 1) status = 1;
  messages.push(`replicaset-status-${report.defaultReplicaSet.status}`);
}
if (messages.length === 0) messages.push('healthy');

print(JSON.stringify({
  profile: 'mysql84_innodb_cluster',
  cluster: clusterName,
  status,
  expectedMembers: expectedCount,
  onlineMembers: online,
  primaryMembers: primary,
  messages
}));
