// MySQL Shell JavaScript used by 07_drill_mgr_failover.sh.
const required = ['IC_CLUSTER_NAME', 'IC_SEED_INSTANCE', 'IC_CLUSTER_ADMIN', 'IC_CLUSTER_ADMIN_PASSWORD', 'IC_DRILL_ACTION'];
for (const key of required) {
  if (!os.getenv(key)) throw new Error(`Missing ${key}`);
}

const clusterName = os.getenv('IC_CLUSTER_NAME');
const seed = os.getenv('IC_SEED_INSTANCE');
const user = os.getenv('IC_CLUSTER_ADMIN');
const password = os.getenv('IC_CLUSTER_ADMIN_PASSWORD');
const action = os.getenv('IC_DRILL_ACTION');
const target = os.getenv('IC_DRILL_TARGET') || '';

function endpoint(value) {
  const pos = value.lastIndexOf(':');
  if (pos <= 0) throw new Error(`Invalid endpoint: ${value}`);
  return {scheme: 'mysql', host: value.slice(0, pos), port: Number(value.slice(pos + 1)), user, password};
}

shell.connect(endpoint(seed));
const cluster = dba.getCluster(clusterName);
if (action === 'primary') {
  const status = cluster.status({extended: 1});
  const topology = status.defaultReplicaSet && status.defaultReplicaSet.topology ? status.defaultReplicaSet.topology : {};
  const primary = Object.entries(topology).find(([, member]) => member.memberRole === 'PRIMARY' || member.mode === 'R/W');
  if (!primary) throw new Error('No PRIMARY member reported by AdminAPI.');
  print(JSON.stringify({primary: primary[0]}));
} else if (action === 'rejoin') {
  if (!target) throw new Error('A target HOST:PORT is required for rejoin.');
  cluster.rejoinInstance(endpoint(target));
  print(JSON.stringify(cluster.status({extended: 1}), null, 2));
} else {
  throw new Error(`Unsupported drill action: ${action}`);
}
