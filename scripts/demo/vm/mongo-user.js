// mongo-user.js — creates the demo database's own login (readWrite on that database only), as
// the engine's root user. Runs inside the mongo container with --nodb: the root credentials are
// the container's own MONGO_INITDB_ROOT_* and the demo ones come from `docker exec -e`, so no
// secret is on a command line. An existing login is reset only when vm-bootstrap.sh generated
// a fresh password (DEMO_MONGO_RESET=true, the mount is not registered yet: condition 1).
const env = process.env;
const name = env.DEMO_MONGO_USER;
if (!/^demo_[0-9a-f]{8}_activity$/.test(name) || name !== env.DEMO_MONGO_DB) {
  throw new Error(`refused: ${name} is not a demo activity login for ${env.DEMO_MONGO_DB}`);
}
const admin = new Mongo('mongodb://127.0.0.1:27017').getDB('admin');
admin.auth(env.MONGO_INITDB_ROOT_USERNAME, env.MONGO_INITDB_ROOT_PASSWORD);
const target = admin.getSiblingDB(name);
const roles = [{ role: 'readWrite', db: name }];
if (!target.getUser(name)) {
  target.createUser({ user: name, pwd: env.DEMO_MONGO_PASSWORD, roles });
  print(`created login ${name}`);
} else if (env.DEMO_MONGO_RESET === 'true') {
  target.updateUser(name, { pwd: env.DEMO_MONGO_PASSWORD, roles }); // resume-password
  print(`reset the password of ${name}`);
}
