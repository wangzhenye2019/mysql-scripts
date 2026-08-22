// MySQL Shell JavaScript for 05_operate_cluster.sh.
const clusterName = os.getenv('IC_CLUSTER_NAME');
const seed = os.getenv('IC_SEED_INSTANCE');
const admin = os.getenv('IC_CLUSTER_ADMIN');
const password = os.getenv('IC_CLUSTER_ADMIN_PASSWORD');
const operation = os.getenv('IC_OPERATION');
const target = os.getenv('IC_TARGET_INSTANCE');

if (!clusterName || !seed || !admin || !password || !operation) {
  throw new Error('Missing required IC_* environment variables.');
}
function endpoint(value) {
  const pos = value.lastIndexOf(':');
  if (pos <= 0) throw new Error(`Invalid endpoint: ${value}`);
  return {scheme: 'mysql', host: value.slice(0, pos), port: Number(value.slice(pos + 1)), user: admin, password};
}

shell.connect(endpoint(seed));
const cluster = dba.getCluster(clusterName);
if (operation === 'status') {
  print(JSON.stringify(cluster.status({extended: 1}), null, 2));
} else if (operation === 'rejoin') {
  if (!target) throw new Error('A target HOST:PORT is required for rejoin.');
  cluster.rejoinInstance(endpoint(target));
  print(JSON.stringify(cluster.status({extended: 1}), null, 2));
} else if (operation === 'rotate-recovery-passwords') {
  cluster.resetRecoveryAccountsPassword();
  print('Recovery account passwords rotated successfully.');
} else {
  throw new Error(`Unsupported operation: ${operation}`);
}
