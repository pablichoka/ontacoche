const admin = require('firebase-admin');

let app;

function getFirebaseApp() {
  if (app) {
    return app;
  }

  const missing = [
    'FIREBASE_PROJECT_ID',
    'FIREBASE_CLIENT_EMAIL',
    'FIREBASE_PRIVATE_KEY',
  ].filter((key) => !process.env[key]);

  if (missing.length > 0) {
    throw new Error(`missing required env vars: ${missing.join(', ')}`);
  }

  const privateKey = process.env.FIREBASE_PRIVATE_KEY
    .trim()
    .replace(/^"|"$/g, '')
    .replace(/^'|'$/g, '')
    .replace(/\\n/g, '\n');

  app = admin.initializeApp({
    credential: admin.credential.cert({
      projectId: process.env.FIREBASE_PROJECT_ID,
      clientEmail: process.env.FIREBASE_CLIENT_EMAIL,
      privateKey,
    }),
  }, 'register-token-app');

  return app;
}

function unauthorized(res) {
  return res.status(401).json({ ok: false, error: 'unauthorized' });
}

module.exports = async function handler(req, res) {
  if (req.method !== 'POST') {
    return res.status(405).json({ ok: false, error: 'method not allowed' });
  }

  const expected = process.env.FCM_TOKEN_SYNC_BEARER;
  if (!expected) {
    return res.status(500).json({ ok: false, error: 'server misconfigured' });
  }

  const auth = req.headers.authorization || '';
  if (auth !== `Bearer ${expected}`) {
    return unauthorized(res);
  }

  const body = req.body || {};
  const token = String(body.token || '').trim();
  const deviceId = String(body.device_id || '').trim();
  const userId = String(body.user_id || '').trim();
  const platform = String(body.platform || 'unknown').trim();
  const collection = (process.env.FCM_TOKEN_COLLECTION || 'fcm_tokens').trim() || 'fcm_tokens';

  if (!token || (!deviceId && !userId)) {
    return res.status(400).json({ ok: false, error: 'token and device_id or user_id are required' });
  }

  try {
    const firestore = getFirebaseApp().firestore();
    await firestore.collection(collection).doc(token).set({
      token,
      device_id: deviceId || null,
      user_id: userId || null,
      platform,
      active: true,
      updated_at: new Date().toISOString(),
    }, { merge: true });

    return res.status(200).json({ ok: true });
  } catch (error) {
    console.error(JSON.stringify({
      level: 'error',
      message: 'register token failed',
      error: error.message,
      code: error.code || null,
      ts: new Date().toISOString(),
    }));

    return res.status(500).json({ ok: false, error: 'internal server error' });
  }
};
