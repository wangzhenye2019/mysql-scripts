// MySQL Shell JavaScript. Invocation is controlled by 03_create_cluster.sh.
const required = [
  'IC_CLUSTER_NAME', 'IC_SEED_INSTANCE', 'IC_INSTANCES_CSV',
  'IC_COMMUNICATION_STACK', 'IC_SINGLE_PRIMARY', 'IC_RECOVERY_METHOD',
  'IC_ROOT_USER', 'IC_ROOT_PASSWORD', 'IC_CLUSTER_ADMIN',
  'IC_CLUSTER_ADMIN_PASSWORD', 'IC_CONFIGURE_INSTANCES'
];
for (const key of required) {
  if (!os.getenv(key)) throw new Error(`Missing ${key}`);
}

const cfg = {
  clusterName: os.getenv('IC_CLUSTER_NAME'),
  seed: os.getenv('IC_SEED_INSTANCE'),
  instances: os.getenv('IC_INSTANCES_CSV').split(',').map(v => v.trim()).filter(Boolean),
  communicationStack: os.getenv('IC_COMMUNICATION_STACK').toUpperCase(),
  singlePrimary: os.getenv('IC_SINGLE_PRIMARY') === 'true',
  recoveryMethod: os.getenv('IC_RECOVERY_METHOD'),
  rootUser: os.getenv('IC_ROOT_USER'),
  rootPassword: os.getenv('IC_ROOT_PASSWORD'),
  clusterAdmin: os.getenv('IC_CLUSTER_ADMIN'),
  clusterAdminPassword: os.getenv('IC_CLUSTER_ADMIN_PASSWORD'),
  configureInstances: os.getenv('IC_CONFIGURE_INSTANCES') === 'true'
};

if (!['MYSQL', 'XCOM'].includes(cfg.communicationStack)) {
  throw new Error(`Unsupported communication stack: ${cfg.communicationStack}`);
}
if (!['clone', 'incremental', 'auto'].includes(cfg.recoveryMethod)) {
  throw new Error(`Unsupported recovery method: ${cfg.recoveryMethod}`);
}
if (cfg.instances.length < 3 || cfg.instances[0] !== cfg.seed) {
  throw new Error('At least three instances are required and the first must be the seed.');
}

function parseEndpoint(value) {
  const pos = value.lastIndexOf(':');
  if (pos <= 0) throw new Error(`Invalid HOST:PORT endpoint: ${value}`);
  const host = value.slice(0, pos);
  const port = Number(value.slice(pos + 1));
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error(`Invalid port: ${value}`);
  return {scheme: 'mysql', host, port};
}
function rootConnection(value) {
  return Object.assign(parseEndpoint(value), {user: cfg.rootUser, password: cfg.rootPassword});
}
function adminConnection(value) {
  return Object.assign(parseEndpoint(value), {user: cfg.clusterAdmin, password: cfg.clusterAdminPassword});
}

if (cfg.configureInstances) {
  for (const instance of cfg.instances) {
    print(`Configuring ${instance} through AdminAPI ...`);
    // AdminAPI creates the same server-configuration account on every member.
    dba.configureInstance(rootConnection(instance), {
      clusterAdmin: cfg.clusterAdmin,
      clusterAdminPassword: cfg.clusterAdminPassword,
      restart: true
    });
  }
}

shell.connect(adminConnection(cfg.seed));
let cluster;
try {
  cluster = dba.getCluster(cfg.clusterName);
  print(`Using existing InnoDB Cluster '${cfg.clusterName}'.`);
} catch (err) {
  print(`Creating InnoDB Cluster '${cfg.clusterName}' from seed ${cfg.seed} ...`);
  cluster = dba.createCluster(cfg.clusterName, {
    communicationStack: cfg.communicationStack,
    multiPrimary: !cfg.singlePrimary
  });
}

for (const instance of cfg.instances.slice(1)) {
  print(`Adding ${instance} using recoveryMethod=${cfg.recoveryMethod} ...`);
  try {
    cluster.addInstance(adminConnection(instance), {recoveryMethod: cfg.recoveryMethod});
  } catch (err) {
    // Reruns can encounter already-managed members. Report the existing state
    // instead of forcing an unsafe reconfiguration or dissolve/recreate flow.
    print(`AddInstance for ${instance} did not complete: ${err.message}`);
  }
}

const status = cluster.status({extended: 1});
print(JSON.stringify(status, null, 2));
print('AdminAPI completed. Do not manually START GROUP_REPLICATION or edit group_replication_* settings on managed members.');
