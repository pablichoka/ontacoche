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
  if (method !== 'GET') {
    return res.status(405).json({ ok: false, error: 'method not allowed' });
  }

  if (!maybeAuthorize(req)) {
    return res.status(401).json({ ok: false, error: 'unauthorized' });
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
