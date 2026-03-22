const { readConfig } = require('../src/config');
const { getFirestore, getMessaging } = require('../src/firebaseAdmin');
const {
  deactivateInvalidTokens,
  getActiveTokens,
} = require('../src/tokenRepository');

function getRequestId(req) {
  return req.headers['x-request-id'] || `${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
}

function writeLog(level, message, context = {}) {
  const entry = {
    level,
    message,
    ...context,
    ts: new Date().toISOString(),
  };

  if (level === 'error') {
    console.error(JSON.stringify(entry));
    return;
  }

  console.log(JSON.stringify(entry));
}

function validateRequest(req, config) {
  if (req.method !== 'POST') {
    return { ok: false, status: 405, error: 'method not allowed' };
  }

  const authHeader = req.headers.authorization || '';
  const expected = `Bearer ${config.webhookBearerSecret}`;
  if (authHeader !== expected) {
    return { ok: false, status: 401, error: 'unauthorized' };
  }

  if (!req.headers['content-type'] || !req.headers['content-type'].includes('application/json')) {
    return { ok: false, status: 415, error: 'unsupported content type' };
  }

  if (!req.body || typeof req.body !== 'object') {
    return { ok: false, status: 400, error: 'invalid json payload' };
  }

  return { ok: true };
}

function normalizeEvent(body) {
  return {
    eventId: body.event_id || body.id || null,
    deviceId: body.device_id || body.deviceId || body.ident || null,
    userId: body.user_id || body.userId || null,
    eventType: body.event_type || body.type || 'flespi_event',
    title: body.title || 'Alerta OntaCoche',
    body: body.body || body.message || 'Se detecto una alerta en el tracker',
    severity: body.severity || 'info',
    ts: body.ts || Date.now(),
    raw: body,
  };
}

function buildFcmPayload(event) {
  return {
    notification: {
      title: String(event.title),
      body: String(event.body),
    },
    data: {
      event_id: String(event.eventId || ''),
      device_id: String(event.deviceId || ''),
      user_id: String(event.userId || ''),
      event_type: String(event.eventType || ''),
      severity: String(event.severity || ''),
      ts: String(event.ts || ''),
    },
    android: {
      priority: 'high',
      notification: {
        channelId: 'ontacoche_alerts',
      },
    },
    apns: {
      headers: {
        'apns-priority': '10',
      },
    },
  };
}

module.exports = async function handler(req, res) {
  const requestId = getRequestId(req);

  let config;
  try {
    config = readConfig();
  } catch (error) {
    writeLog('error', 'configuration error', {
      request_id: requestId,
      error: error.message,
    });
    return res.status(500).json({ ok: false, error: 'server misconfigured' });
  }

  const validation = validateRequest(req, config);
  if (!validation.ok) {
    writeLog('warn', 'request rejected', {
      request_id: requestId,
      status: validation.status,
      reason: validation.error,
    });
    return res.status(validation.status).json({ ok: false, error: validation.error });
  }

  const event = normalizeEvent(req.body);

  if (!event.deviceId && !event.userId) {
    writeLog('warn', 'missing routing fields', {
      request_id: requestId,
      event_id: event.eventId,
    });
    return res.status(400).json({ ok: false, error: 'device_id or user_id is required' });
  }

  try {
    const firestore = getFirestore(config);
    const messaging = getMessaging(config);

    const tokenRefsByValue = await getActiveTokens({
      firestore,
      collectionName: config.tokenCollection,
      deviceId: event.deviceId,
      userId: event.userId,
    });

    const tokens = Array.from(tokenRefsByValue.keys());
    if (tokens.length === 0) {
      writeLog('info', 'no active tokens found', {
        request_id: requestId,
        event_id: event.eventId,
        device_id: event.deviceId,
        user_id: event.userId,
      });
      return res.status(202).json({ ok: true, message: 'no active tokens', sent: 0 });
    }

    const payload = buildFcmPayload(event);
    const multicastResponse = await messaging.sendEachForMulticast({
      ...payload,
      tokens,
    });

    const deactivated = await deactivateInvalidTokens({
      tokenRefsByValue,
      multicastResponse,
      tokens,
    });

    writeLog('info', 'fcm sent', {
      request_id: requestId,
      event_id: event.eventId,
      device_id: event.deviceId,
      user_id: event.userId,
      tokens_total: tokens.length,
      success_count: multicastResponse.successCount,
      failure_count: multicastResponse.failureCount,
      deactivated_tokens: deactivated,
    });

    return res.status(200).json({
      ok: true,
      sent: multicastResponse.successCount,
      failed: multicastResponse.failureCount,
      deactivated,
    });
  } catch (error) {
    writeLog('error', 'webhook processing failed', {
      request_id: requestId,
      event_id: event.eventId,
      device_id: event.deviceId,
      user_id: event.userId,
      error: error.message,
    });

    return res.status(500).json({ ok: false, error: 'internal server error' });
  }
};
