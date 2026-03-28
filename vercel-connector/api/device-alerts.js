require('../src/compat-url');
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
  if (req.method !== 'GET' && req.method !== 'POST' && req.method !== 'DELETE') {
    return res.status(405).json({ ok: false, error: 'method not allowed' });
  }

  if (req.method === 'GET' || req.method === 'POST') {
    if (!maybeAuthorize(req)) {
      return res.status(401).json({ ok: false, error: 'unauthorized' });
    }
  } else if (req.method === 'DELETE') {
    const expectedWrite = (process.env.VERCEL_CONNECTOR_WRITE_BEARER || process.env.APP_WRITE_BEARER || '').trim();
    if (expectedWrite) {
      const auth = req.headers.authorization || '';
      if (auth !== `Bearer ${expectedWrite}`) {
        return res.status(401).json({ ok: false, error: 'unauthorized' });
      }
    }
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
    // log access to help track read-heavy usage
    console.info(JSON.stringify({
      level: 'info',
      message: 'device-alerts request',
      method: req.method,
      device_id: deviceId,
      limit,
      ts: new Date().toISOString(),
    }));
    // Prefer server-side filtering to avoid reading the whole collection.
    // If device_id can be stored as number or string, query for both when numeric.
    // Query by nested `device.id` without ordering to avoid requiring composite index.
    // We'll sort by `source_ts` in memory (backend) and return a limited set.
    const query = firestore.collection(alertsCollection).where('device.id', '==', deviceId).limit(1000);

    const snapshot = await query.get();
    let alerts = snapshot.docs.map((doc) => ({ id: doc.id, ...doc.data() }));

    if (req.method === 'DELETE') {
      // delete all alerts returned for this device
      const docs = snapshot.docs;
      let deleted = 0;
      if (docs.length > 0) {
        let batch = firestore.batch();
        let ops = 0;
        for (const d of docs) {
          batch.delete(d.ref);
          ops += 1;
          deleted += 1;
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

      return res.status(200).json({ ok: true, device_id: deviceId, deleted });
    }

    // Sort by `source_ts` (ISO) descending in memory and apply requested limit
    alerts = alerts
      .filter((a) => a && a.source_ts)
      .sort((x, y) => {
        const tx = Date.parse(String(x.source_ts) || '') || 0;
        const ty = Date.parse(String(y.source_ts) || '') || 0;
        return ty - tx;
      })
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
