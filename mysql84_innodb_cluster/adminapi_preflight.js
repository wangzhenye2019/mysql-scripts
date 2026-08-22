// MySQL Shell JavaScript. Credentials are received only through environment variables.
const instance = os.getenv('IC_INSTANCE');
const rootUser = os.getenv('IC_ROOT_USER');
const rootPassword = os.getenv('IC_ROOT_PASSWORD');
const clusterAdmin = os.getenv('IC_CLUSTER_ADMIN');
const clusterAdminPassword = os.getenv('IC_CLUSTER_ADMIN_PASSWORD');

if (!instance || !rootUser || !rootPassword || !clusterAdmin || !clusterAdminPassword) {
  throw new Error('Missing required IC_* environment variables.');
}

const splitAtLastColon = (value) => {
  const pos = value.lastIndexOf(':');
  if (pos <= 0) throw new Error(`Invalid HOST:PORT instance: ${value}`);
  return { host: value.slice(0, pos), port: Number(value.slice(pos + 1)) };
};
const endpoint = splitAtLastColon(instance);

shell.connect({scheme: 'mysql', host: endpoint.host, port: endpoint.port, user: rootUser, password: rootPassword});
print(`Running AdminAPI configuration check for ${instance} ...`);
// The call reports (but does not silently apply) any configuration AdminAPI needs.
dba.checkInstanceConfiguration();
print(`AdminAPI configuration check passed for ${instance}.`);
print('Next step: run 03_create_cluster.sh with --configure-instances to invoke dba.configureInstance() under approved change control.');
