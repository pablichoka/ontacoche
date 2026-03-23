const { readConfig } = require('../src/config');
const { getFirestore, getMessaging } = require('../src/firebaseAdmin');
const {
  deactivateInvalidTokens,
  getActiveTokens,
} = require('../src/tokenRepository');

const VIBRATION_DEDUPE_WINDOW_SECONDS = 45;
const GEOFENCE_DEDUPE_WINDOW_SECONDS = 30;

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

function parseTimestampToMs(value) {
  if (value == null || value === '') {
    return null;
  }

  if (typeof value === 'number') {
    if (value > 1e12) {
      return Math.floor(value);
    }
    if (value > 1e9) {
      return Math.floor(value * 1000);
    }
    return Math.floor(value * 1000);
  }

  if (typeof value === 'string') {
    const numeric = Number(value);
    if (!Number.isNaN(numeric)) {
      return parseTimestampToMs(numeric);
    }
    const parsed = Date.parse(value);
    if (!Number.isNaN(parsed)) {
      return parsed;
    }
  }

  return null;
}

function toIsoFromMs(ms) {
  if (ms == null) {
    return new Date().toISOString();
  }

  return new Date(ms).toISOString();
}

function makeStableId(input) {
  let hash = 0;
  for (let i = 0; i < input.length; i += 1) {
    hash = ((hash << 5) - hash) + input.charCodeAt(i);
    hash |= 0;
  }

  return `k${Math.abs(hash).toString(36)}`;
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

  const eventType = String(event.eventType || '').toLowerCase();
  const intervalType = String(firstDefined(raw, ['type', 'interval.type', 'geofence.event']) || '').toLowerCase();
  const geofenceName = firstDefined(raw, [
    'geofence',
    'geofence.name',
    'plugin.geofence.name',
    'name',
  ]);

  const geofenceEnter =
    intervalType === 'enter' ||
    intervalType === 'activated' ||
    eventType.includes('geofence_enter') ||
    eventType.includes('activated');

  const geofenceExit =
    intervalType === 'exit' ||
    intervalType === 'deactivated' ||
    eventType.includes('geofence_exit') ||
    eventType.includes('deactivated');

  const geofenceAlarm = geofenceEnter || geofenceExit;

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
    if (geofenceName && geofenceEnter) {
      body = `Entrada en geocerca: ${geofenceName}`;
    } else if (geofenceName && geofenceExit) {
      body = `Salida de geocerca: ${geofenceName}`;
    } else {
      body = 'Se detecto un evento de geocerca';
    }
    severity = 'high';
  } else if (communicationActive) {
    title = 'Comunicacion activa';
    body = 'Tracker reportando posicion activa';
    severity = 'info';
  }

  return {
    vibrationAlarm,
    geofenceAlarm,
    geofenceEnter,
    geofenceExit,
    geofenceName: geofenceName ? String(geofenceName) : null,
    communicationActive,
    shouldPush,
    title,
    body,
    severity,
  };
}

function buildStateSnapshot(event, classification) {
  const raw = event.raw || {};
  const sourceTsMs =
    parseTimestampToMs(firstDefined(raw, ['server.timestamp', 'timestamp', 'end', 'begin'])) ||
    parseTimestampToMs(event.ts) ||
    Date.now();

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
    geofence_name: classification.geofenceName,
    geofence_enter: classification.geofenceEnter,
    geofence_exit: classification.geofenceExit,
    communication_active: classification.communicationActive,
    payload: raw,
    source_ts: toIsoFromMs(sourceTsMs),
    source_ts_ms: sourceTsMs,
    updated_at: new Date().toISOString(),
  };
}

async function persistEvent({ firestore, config, event, classification }) {
  if (!event.deviceId) {
    return { alertCreated: false, dedupeKey: null };
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
    const dedupeBucket = classification.vibrationAlarm
      ? Math.floor(snapshot.source_ts_ms / (VIBRATION_DEDUPE_WINDOW_SECONDS * 1000))
      : Math.floor(snapshot.source_ts_ms / (GEOFENCE_DEDUPE_WINDOW_SECONDS * 1000));

    const alertKind = classification.vibrationAlarm
      ? 'vibration_alert'
      : (classification.geofenceEnter ? 'geofence_enter' : 'geofence_exit');

    const dedupeSource = [
      String(event.deviceId),
      alertKind,
      classification.geofenceName || '',
      String(dedupeBucket),
      String(event.eventId || ''),
    ].join('|');

    const dedupeKey = makeStableId(dedupeSource);
    const alertRef = firestore.collection(config.alertsCollection).doc(dedupeKey);
    const existing = await alertRef.get();

    await alertRef.set({
      ...snapshot,
      dedupe_key: dedupeKey,
      event_id: event.eventId || null,
      event_kind: alertKind,
      message: classification.body,
      severity: classification.severity,
      created_at: existing.exists
        ? (existing.data()?.created_at || new Date().toISOString())
        : new Date().toISOString(),
      last_seen_at: new Date().toISOString(),
    }, { merge: true });

    return {
      alertCreated: !existing.exists,
      dedupeKey,
      eventKind: alertKind,
    };
  }

  return { alertCreated: false, dedupeKey: null, eventKind: null };
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
    let skippedDuplicatedAlert = 0;

    for (const event of events) {
      if (!event.deviceId && config.defaultDeviceId) {
        event.deviceId = config.defaultDeviceId;
      }

      const classification = classifyEvent(event, config);

      let persistenceResult = {
        alertCreated: false,
        dedupeKey: null,
      };

      if (event.deviceId) {
        persistenceResult = await persistEvent({
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

      if ((classification.vibrationAlarm || classification.geofenceAlarm) && !persistenceResult.alertCreated) {
        skippedDuplicatedAlert += 1;
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
      payload.data.event_kind = String(persistenceResult.eventKind || event.eventType || '');
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
      skipped_duplicated_alert: skippedDuplicatedAlert,
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
      skipped_duplicated_alert: skippedDuplicatedAlert,
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
