require('../src/compat-url');

const { readConfig } = require('../src/config');
const { getFirestore } = require('../src/firebaseAdmin');

function maybeAuthorize(req) {
  const expectedBearer = (process.env.VERCEL_CONNECTOR_READ_BEARER || process.env.APP_READ_BEARER || '').trim();
  if (!expectedBearer) {
    return true;
  }

  const auth = req.headers.authorization || '';
  return auth === `Bearer ${expectedBearer}`;
}

module.exports = async function handler(req, res) {
  const method = req.method || 'GET';

  // Allow GET for reads, DELETE for removal (requires write bearer)
  if (method !== 'GET' && method !== 'DELETE') {
    return res.status(405).json({ ok: false, error: 'method not allowed' });
  }

  if (method === 'GET') {
    if (!maybeAuthorize(req)) {
      return res.status(401).json({ ok: false, error: 'unauthorized' });
    }
  } else if (method === 'DELETE') {
    const expectedWrite = (process.env.VERCEL_CONNECTOR_WRITE_BEARER || process.env.APP_WRITE_BEARER || '').trim();
    if (expectedWrite) {
      const auth = req.headers.authorization || '';
      if (auth !== `Bearer ${expectedWrite}`) {
        return res.status(401).json({ ok: false, error: 'unauthorized' });
      }
    }
  }

  let config;
  try {
    config = readConfig();
  } catch (e) {
    return res.status(500).json({ ok: false, error: 'server misconfigured' });
  }

  const deviceId = (req.query.device_id || req.query.deviceId || '').toString().trim();
  const limitRaw = req.query.limit || '20';
  const limit = Math.min(Math.max(parseInt(limitRaw, 10) || 20, 1), 200);

  if (!deviceId) {
    return res.status(400).json({ ok: false, error: 'device_id is required' });
  }

  try {
    const firestore = getFirestore(config);
    const collectionName = config.tripsCollection || 'trips';
    if (method === 'DELETE') {
      // delete all trips for deviceId in batches
      const q = firestore.collection(collectionName).where('deviceIdent', '==', deviceId).limit(1000);
      const snapshot = await q.get();
      const docs = snapshot.docs;
      let deleted = 0;
      if (docs.length > 0) {
        let batch = firestore.batch();
        let ops = 0;
        for (const doc of docs) {
          batch.delete(doc.ref);
          ops += 1;
          deleted += 1;
          if (ops >= 450) {
            await batch.commit();
            batch = firestore.batch();
            ops = 0;
          }
        }
        if (ops > 0) await batch.commit();
      }

      return res.status(200).json({ ok: true, device_id: deviceId, deleted });
    }

    const q = firestore.collection(collectionName).where('deviceIdent', '==', deviceId).limit(limit);
    const snapshot = await q.get();

    const rows = snapshot.docs.map((doc) => {
      const data = doc.data();
      // include document id for client mapping
      return Object.assign({ id: doc.id }, data);
    });

    return res.status(200).json({ ok: true, trips: rows });
  } catch (error) {
    console.error(JSON.stringify({ level: 'error', message: 'failed to fetch trips', error: error.message }));
    return res.status(500).json({ ok: false, error: 'internal server error' });
  }
};
