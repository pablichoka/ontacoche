/*
  Normalize device_state_history documents to ensure `device.id` is present
  and legacy top-level or nested `device.device_id` fields are removed.

  Usage:
    set firebase env vars and run:
    node scripts/normalize_history.js

  This script will:
  - For each doc in stateHistoryCollection, if `device.device_id` exists, copy it to `device.id` and delete `device.device_id`.
  - If top-level `device_id` exists, copy it into `device.id`.
  - Remove legacy top-level `latitude`, `longitude`, `battery_level` fields when present to favor nested `position` and `battery`.

  BE CAREFUL: Run on a copy / backup first if needed.
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
  }, 'normalize-history');

  const firestore = app.firestore();
  const historyCol = firestore.collection(config.stateHistoryCollection);

  console.log('Reading history documents in batches...');

  const pageSize = 500;
  let last = null;
  let updated = 0;

  while (true) {
    let q = historyCol.orderBy('__name__').limit(pageSize);
    if (last) q = q.startAfter(last);
    const snap = await q.get();
    if (snap.empty) break;

    for (const doc of snap.docs) {
      const data = doc.data();
      let changed = false;

      // ensure nested device map
      if (!data.device || typeof data.device !== 'object') {
        data.device = {};
        changed = true;
      }

      if (data.device && data.device.device_id && !data.device.id) {
        data.device.id = String(data.device.device_id);
        delete data.device.device_id;
        changed = true;
      }

      if (data.device_id && !data.device.id) {
        data.device.id = String(data.device_id);
        delete data.device_id;
        changed = true;
      }

      // remove legacy top-level geo and battery fields if nested versions exist
      if (data.position && (data.latitude || data.longitude)) {
        if (data.latitude !== undefined) { delete data.latitude; changed = true; }
        if (data.longitude !== undefined) { delete data.longitude; changed = true; }
      }

      if (data.battery && (data.battery.level !== undefined) && data.battery_level !== undefined) {
        delete data.battery_level;
        changed = true;
      }

      if (changed) {
        await historyCol.doc(doc.id).set(data, { merge: true });
        updated += 1;
      }
    }

    last = snap.docs[snap.docs.length - 1];
    if (snap.size < pageSize) break;
  }

  console.log(`Normalization complete. Documents updated: ${updated}`);
  process.exit(0);
}

main().catch(err => { console.error('failed', err); process.exit(1); });
