const admin = require('firebase-admin');

let app;

function getPrivateKey() {
  const value = process.env.FIREBASE_PRIVATE_KEY;
  if (!value) {
    return null;
  }

  return value
    .trim()
    .replace(/^"|"$/g, '')
    .replace(/^'|'$/g, '')
    .replace(/\\n/g, '\n');
}

function getFirestore() {
  if (app) {
    return app.firestore();
  }

  const projectId = process.env.FIREBASE_PROJECT_ID;
  const clientEmail = process.env.FIREBASE_CLIENT_EMAIL;
  const privateKey = getPrivateKey();

  if (!projectId || !clientEmail || !privateKey) {
    throw new Error('missing firebase admin credentials');
  }

  app = admin.initializeApp({
    credential: admin.credential.cert({
      projectId,
      clientEmail,
      privateKey,
    }),
  }, 'device-alerts-api');

  return app.firestore();
}

function maybeAuthorize(req) {
  const expectedBearer = (process.env.APP_READ_BEARER || '').trim();
  if (!expectedBearer) {
    return true;
  }

  const auth = req.headers.authorization || '';
  return auth === `Bearer ${expectedBearer}`;
}

module.exports = async function handler(req, res) {
  if (req.method !== 'GET') {
    return res.status(405).json({ ok: false, error: 'method not allowed' });
  }

  if (!maybeAuthorize(req)) {
    return res.status(401).json({ ok: false, error: 'unauthorized' });
  }

  const deviceId = String(req.query.device_id || '').trim();
  if (!deviceId) {
    return res.status(400).json({ ok: false, error: 'device_id is required' });
  }

  const requestedLimit = Number(req.query.limit || 50);
  const limit = Number.isFinite(requestedLimit)
    ? Math.min(Math.max(Math.floor(requestedLimit), 1), 200)
    : 50;

  const alertsCollection = (process.env.ALERTS_COLLECTION || 'device_alerts').trim() || 'device_alerts';

  try {
    const firestore = getFirestore();
    const snapshot = await firestore
      .collection(alertsCollection)
      .orderBy('source_ts_ms', 'desc')
      .limit(600)
      .get();

    const alerts = snapshot.docs
      .map((doc) => ({ id: doc.id, ...doc.data() }))
      .filter((item) => String(item.device_id || '') === deviceId)
      .slice(0, limit);

    return res.status(200).json({
      ok: true,
      device_id: deviceId,
      alerts,
    });
  } catch (error) {
    console.error(JSON.stringify({
      level: 'error',
      message: 'device alerts read failed',
      error: error.message,
      code: error.code || null,
      ts: new Date().toISOString(),
    }));

    return res.status(500).json({ ok: false, error: 'internal server error' });
  }
};
