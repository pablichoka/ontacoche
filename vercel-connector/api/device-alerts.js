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
  if (req.method !== 'GET' && req.method !== 'POST') {
    return res.status(405).json({ ok: false, error: 'method not allowed' });
  }

  if (!maybeAuthorize(req)) {
    return res.status(401).json({ ok: false, error: 'unauthorized' });
  }

  const body = req.body && typeof req.body === 'object' ? req.body : {};
  const rawDeviceId = req.method === 'GET' ? req.query.device_id : body.device_id;
  const deviceId = String(rawDeviceId || '').trim();
  if (!deviceId) {
    return res.status(400).json({ ok: false, error: 'device_id is required' });
  }

  const requestedLimit = Number(req.method === 'GET' ? req.query.limit : body.limit || 50);
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

    if (req.method === 'POST') {
      const alertIds = Array.isArray(body.alert_ids)
        ? body.alert_ids.map((value) => String(value || '').trim()).filter(Boolean)
        : [];
      const idSet = new Set(alertIds);

      const toMark = alerts.filter((item) => {
        if (item.checked === true) {
          return false;
        }

        if (idSet.size === 0) {
          return true;
        }

        return idSet.has(String(item.id || ''));
      });

      let marked = 0;
      if (toMark.length > 0) {
        let batch = firestore.batch();
        let ops = 0;

        for (const item of toMark) {
          const ref = firestore.collection(alertsCollection).doc(String(item.id));
          batch.update(ref, {
            checked: true,
            checked_at: admin.firestore.FieldValue.serverTimestamp(),
          });
          ops += 1;
          marked += 1;

          if (ops >= 450) {
            await batch.commit();
            batch = firestore.batch();
            ops = 0;
          }
        }

        if (ops > 0) {
          await batch.commit();
        }
      }

      return res.status(200).json({
        ok: true,
        device_id: deviceId,
        marked,
      });
    }

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
