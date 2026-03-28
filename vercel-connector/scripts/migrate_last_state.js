/*
  Simple migration script: for each device in `stateHistoryCollection`,
  find the most recent doc (by `source_ts_ms`) and write it as the
  document in `deviceStateCollection`, using the compact schema.

  Usage:
    TIMEZONE=Europe/Madrid WEBHOOK_BEARER_SECRET=... \
    FIREBASE_PROJECT_ID=... FIREBASE_CLIENT_EMAIL=... FIREBASE_PRIVATE_KEY="..." \
    node scripts/migrate_last_state.js

  NOTE: ensure you have backups or run in dry-run first.
*/

const admin = require('firebase-admin');
const { readConfig } = require('../src/config');

function getPrivateKey() {
  const raw = process.env.FIREBASE_PRIVATE_KEY;
  if (!raw) return null;
  return raw.trim().replace(/^"|"$/g, '').replace(/^'|'$/g, '').replace(/\\n/g, '\n');
}

async function main() {
  const config = readConfig();
  const projectId = config.firebaseProjectId;
  const clientEmail = config.firebaseClientEmail;
  const privateKey = getPrivateKey();

  if (!projectId || !clientEmail || !privateKey) {
    console.error('missing firebase credentials in env');
    process.exit(1);
  }

  const app = admin.initializeApp({
    credential: admin.credential.cert({ projectId, clientEmail, privateKey }),
  }, 'migrate-last-state');

  const firestore = app.firestore();
  const historyCol = firestore.collection(config.stateHistoryCollection);
  const lastCol = firestore.collection(config.deviceStateCollection);

  console.log('Scanning distinct device ids in history...');
  const snapshot = await historyCol.select('device.id', 'device_id').get();
  const seen = new Set();
  const devices = [];
  snapshot.docs.forEach((doc) => {
    const data = doc.data();
    const did = (data.device && data.device.id) ? String(data.device.id) : (data.device_id ? String(data.device_id) : null);
    if (did && !seen.has(did)) {
      devices.push(did);
      seen.add(did);
    }
  });

  console.log(`Found ${devices.length} devices. Migrating...`);

  for (const deviceId of devices) {
    console.log('Processing', deviceId);
    const q = historyCol.where('device.id', '==', deviceId).orderBy('source_ts_ms', 'desc').limit(1);
    const qsnap = await q.get();
    if (qsnap.empty) {
      console.log(' no history for', deviceId);
      continue;
    }
    const doc = qsnap.docs[0];
    const data = doc.data();
    // ensure device.id present
    if (!data.device) data.device = {};
    data.device.id = String(deviceId);
    // write to last col (overwrite)
    await lastCol.doc(String(deviceId)).set(data);
    console.log(' wrote last state for', deviceId);
  }

  console.log('Migration finished.');
  process.exit(0);
}

main().catch((err) => {
  console.error('migration failed', err);
  process.exit(1);
});
