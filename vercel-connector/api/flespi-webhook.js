const { readConfig } = require('../src/config');
const { getFirestore, getMessaging } = require('../src/firebaseAdmin');
const {
  deactivateInvalidTokens,
  getActiveTokens,
} = require('../src/tokenRepository');

function firstDefined(source, keys) {
  for (const key of keys) {
    if (Object.prototype.hasOwnProperty.call(source, key) && source[key] != null) {
      return source[key];
    }
  }

  return null;
}

function normalizeReportCode(value) {
  if (value == null || value === '') {
    return null;
  }

  const raw = String(value).trim();
  if (/^\d+$/.test(raw)) {
    return raw.padStart(4, '0');
  }

  return raw;
}

function asBoolean(value) {
  if (typeof value === 'boolean') {
    return value;
  }
  if (typeof value === 'number') {
    return value !== 0;
  }
  if (typeof value === 'string') {
    const normalized = value.trim().toLowerCase();
    return ['true', '1', 'yes', 'on', 'alarm', 'active'].includes(normalized);
  }

  return false;
}

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
  const reportCode = normalizeReportCode(firstDefined(body, [
    'report.code',
    'report_code',
    'reportCode',
    'message.code',
    'code',
  ]));

  return {
    eventId: body.event_id || body.id || null,
    deviceId:
      body.device_id ||
      body.deviceId ||
      body.ident ||
      body['device.id'] ||
      body.device?.id ||
      body.device ||
      null,
    userId: body.user_id || body.userId || null,
    eventType: body.event_type || body.type || 'flespi_event',
    reportCode,
    title: body.title || 'Alerta OntaCoche',
    body: body.body || body.message || 'Se detecto una alerta en el tracker',
    severity: body.severity || 'info',
    ts: body.ts || Date.now(),
    raw: body,
  };
}

function extractRawEvents(body) {
  if (Array.isArray(body)) {
    return body.filter((item) => item && typeof item === 'object');
  }

  if (body && Array.isArray(body.data)) {
    return body.data.filter((item) => item && typeof item === 'object');
  }

  if (body && typeof body === 'object') {
    return [body];
  }

  return [];
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
      report_code: String(event.reportCode || ''),
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

function classifyEvent(event, config) {
  const raw = event.raw || {};
  const alarmValue = firstDefined(raw, [
    'alarm',
    'vibration.alarm',
    'alarm.vibration',
    'vibration_alarm',
  ]);

  const vibrationAlarm =
    asBoolean(firstDefined(raw, ['vibration.alarm', 'alarm.vibration', 'vibration_alarm'])) ||
    (typeof alarmValue === 'string' && alarmValue.toLowerCase().includes('vibration'));

  const geofenceAlarm =
    asBoolean(firstDefined(raw, ['geofence.alarm', 'geofence_alarm'])) ||
    firstDefined(raw, ['geofence.id', 'geofence.name', 'geofence.event']) != null ||
    String(event.eventType || '').toLowerCase().includes('geofence');

  const communicationActive = event.reportCode === '0200';
  const shouldPush =
    vibrationAlarm || geofenceAlarm || (communicationActive && config.pushOnCommunicationActive);

  let title = event.title;
  let body = event.body;
  let severity = 'info';

  if (vibrationAlarm) {
    title = 'Alerta de vibracion';
    body = 'Se detecto vibracion en el tracker';
    severity = 'high';
  } else if (geofenceAlarm) {
    title = 'Alerta de geocerca';
    body = 'Se detecto un evento de geocerca';
    severity = 'high';
  } else if (communicationActive) {
    title = 'Comunicacion activa';
    body = 'Tracker reportando posicion activa';
    severity = 'info';
  }

  return {
    vibrationAlarm,
    geofenceAlarm,
    communicationActive,
    shouldPush,
    title,
    body,
    severity,
  };
}

function buildStateSnapshot(event, classification) {
  const raw = event.raw || {};
  return {
    device_id: event.deviceId,
    user_id: event.userId || null,
    report_code: event.reportCode || null,
    event_type: event.eventType || null,
    latitude: firstDefined(raw, ['position.latitude', 'latitude']),
    longitude: firstDefined(raw, ['position.longitude', 'longitude']),
    speed: firstDefined(raw, ['position.speed', 'speed']),
    battery_level: firstDefined(raw, ['battery.level', 'battery_level']),
    alarm: firstDefined(raw, ['alarm']),
    vibration_alarm: classification.vibrationAlarm,
    geofence_alarm: classification.geofenceAlarm,
    communication_active: classification.communicationActive,
    payload: raw,
    source_ts: event.ts || null,
    updated_at: new Date().toISOString(),
  };
}

async function persistEvent({ firestore, config, event, classification }) {
  if (!event.deviceId) {
    return;
  }

  const snapshot = buildStateSnapshot(event, classification);

  if (classification.communicationActive) {
    await firestore
      .collection(config.deviceStateCollection)
      .doc(String(event.deviceId))
      .set(snapshot, { merge: true });

    if (config.storeStateHistory) {
      await firestore.collection(config.stateHistoryCollection).add(snapshot);
    }
  }

  if (classification.vibrationAlarm || classification.geofenceAlarm) {
    await firestore.collection(config.alertsCollection).add({
      ...snapshot,
      event_id: event.eventId || null,
      created_at: new Date().toISOString(),
    });
  }
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

  const rawEvents = extractRawEvents(req.body);
  if (rawEvents.length === 0) {
    return res.status(400).json({ ok: false, error: 'invalid events payload' });
  }

  const events = rawEvents.map(normalizeEvent);

  try {
    const firestore = getFirestore(config);
    const messaging = getMessaging(config);

    let sent = 0;
    let failed = 0;
    let deactivatedTotal = 0;
    let processed = 0;
    let persisted = 0;
    let skippedNoRouting = 0;
    let skippedNoTokens = 0;
    let skippedNonAlert = 0;

    for (const event of events) {
      if (!event.deviceId && config.defaultDeviceId) {
        event.deviceId = config.defaultDeviceId;
      }

      const classification = classifyEvent(event, config);

      if (event.deviceId) {
        await persistEvent({
          firestore,
          config,
          event,
          classification,
        });
        persisted += 1;
      }

      if (!event.deviceId && !event.userId) {
        skippedNoRouting += 1;
        continue;
      }

      if (!classification.shouldPush) {
        skippedNonAlert += 1;
        continue;
      }

      processed += 1;

      const tokenRefsByValue = await getActiveTokens({
        firestore,
        collectionName: config.tokenCollection,
        deviceId: event.deviceId,
        userId: event.userId,
      });

      const tokens = Array.from(tokenRefsByValue.keys());
      if (tokens.length === 0) {
        skippedNoTokens += 1;
        continue;
      }

      const payload = buildFcmPayload(event);
      payload.notification.title = classification.title;
      payload.notification.body = classification.body;
      payload.data.severity = classification.severity;
      payload.data.report_code = String(event.reportCode || '');
      const multicastResponse = await messaging.sendEachForMulticast({
        ...payload,
        tokens,
      });

      const deactivated = await deactivateInvalidTokens({
        tokenRefsByValue,
        multicastResponse,
        tokens,
      });

      sent += multicastResponse.successCount;
      failed += multicastResponse.failureCount;
      deactivatedTotal += deactivated;
    }

    const status = 200;
    writeLog('info', 'fcm batch processed', {
      request_id: requestId,
      events_total: events.length,
      events_processed: processed,
      events_persisted: persisted,
      skipped_no_routing: skippedNoRouting,
      skipped_non_alert: skippedNonAlert,
      skipped_no_tokens: skippedNoTokens,
      sent,
      failed,
      deactivated_tokens: deactivatedTotal,
    });

    return res.status(status).json({
      ok: true,
      events_total: events.length,
      events_processed: processed,
      events_persisted: persisted,
      skipped_no_routing: skippedNoRouting,
      skipped_non_alert: skippedNonAlert,
      skipped_no_tokens: skippedNoTokens,
      sent,
      failed,
      deactivated: deactivatedTotal,
    });
  } catch (error) {
    writeLog('error', 'webhook processing failed', {
      request_id: requestId,
      error_code: error.code || null,
      error: error.message,
    });

    return res.status(500).json({
      ok: false,
      error: 'internal server error',
      code: error.code || 'unknown',
    });
  }
};
