// mongo-load.js — loads every <collection>.jsonl in DEMO_MONGO_DIR into the demo database, logged
// in as the demo login itself (condition 4). A document whose _id exists is left as it is
// ($setOnInsert): a re-run only adds, and edits made in the app survive (condition 11). The
// file name minus a leading "activity." and a trailing ".spike" gives the collection.
const fs = require('fs');
const env = process.env;
const conn = new Mongo('mongodb://127.0.0.1:27017');
const db = conn.getDB(env.DEMO_MONGO_DB);
db.auth(env.DEMO_MONGO_USER, env.DEMO_MONGO_PASSWORD);

const BATCH = 500;
for (const file of fs.readdirSync(env.DEMO_MONGO_DIR).filter((f) => f.endsWith('.jsonl')).sort()) {
  const collection = file.replace(/^activity\./, '').replace(/(\.spike)?\.jsonl$/, '');
  const docs = fs.readFileSync(`${env.DEMO_MONGO_DIR}/${file}`, 'utf8').split('\n').filter(Boolean).map((line) => EJSON.parse(line));
  let added = 0;
  for (let i = 0; i < docs.length; i += BATCH) {
    const ops = docs.slice(i, i + BATCH).map(({ _id, ...fields }) => ({
      updateOne: { filter: { _id }, update: { $setOnInsert: fields }, upsert: true },
    }));
    added += db.getCollection(collection).bulkWrite(ops, { ordered: false }).upsertedCount;
  }
  print(`${collection}: ${docs.length} documents, ${added} added`);
}
