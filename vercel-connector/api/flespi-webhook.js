const { readConfig } = require('../src/config');
const { getFirestore, getMessaging } = require('../src/firebaseAdmin');
const {
  deactivateInvalidTokens,
  getActiveTokens,
} = require('../src/tokenRepository');

const VIBRATION_DEDUPE_WINDOW_SECONDS = 45;
const GEOFENCE_DEDUPE_WINDOW_SECONDS = 30;

function getNestedValue(source, key) {
  if (!source || typeof source !== 'object' || !key) {
    return null;
  }

  if (Object.prototype.hasOwnProperty.call(source, key) && source[key] != null) {
    return source[key];
  }

  const parts = key.split('.');
  let current = source;
  for (const part of parts) {
    if (!current || typeof current !== 'object' || !Object.prototype.hasOwnProperty.call(current, part)) {
      return null;
    }
    current = current[part];
  }

  return current == null ? null : current;
}

function firstDefined(source, keys) {
  for (const key of keys) {
    const value = getNestedValue(source, key);
    if (value != null) {
      return value;
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

function extractDeviceIdFromTopic(topic) {
  if (!topic || typeof topic !== 'string') {
    return null;
  }

  const match = topic.match(/\/devices\/([^/]+)/);
  return match ? match[1] : null;
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
  const payload = (body && typeof body.payload === 'object' && body.payload)
    ? body.payload
    : {};
  const root = (body && typeof body === 'object') ? body : {};

  const reportCode = normalizeReportCode(firstDefined(body, [
    'report.code',
    'report_code',
    'reportCode',
    'message.code',
    'code',
    'payload.report.code',
    'payload.report_code',
  ]));

  const rawTopic = firstDefined(root, ['topic', 'event.topic', 'payload.topic']);
  const inferredEventType =
    firstDefined(root, ['event_type', 'type', 'event.type']) ||
    firstDefined(payload, ['event_type', 'type', 'interval.type']) ||
    rawTopic ||
    'flespi_event';

  const deviceId =
    firstDefined(root, [
      'device_id',
      'deviceId',
      'ident',
      'device.id',
      'device.id',
    ]) ||
    firstDefined(payload, [
      'device_id',
      'deviceId',
      'ident',
      'device.id',
      'device.id',
    ]) ||
    extractDeviceIdFromTopic(rawTopic) ||
    null;

  return {
    eventId: firstDefined(root, ['event_id', 'id', 'event.id']) || firstDefined(payload, ['event_id', 'id']) || null,
    deviceId: deviceId != null ? String(deviceId) : null,
    userId: (firstDefined(root, ['user_id', 'userId']) || firstDefined(payload, ['user_id', 'userId']) || null),
    eventType: String(inferredEventType),
    reportCode,
    title: firstDefined(root, ['title', 'notification.title']) || firstDefined(payload, ['title']) || 'Alerta OntaCoche',
    body: firstDefined(root, ['body', 'message', 'notification.body']) || firstDefined(payload, ['body', 'message']) || 'Se detecto una alerta en el tracker',
    severity: firstDefined(root, ['severity']) || firstDefined(payload, ['severity']) || 'info',
    ts: firstDefined(root, ['ts', 'timestamp', 'server.timestamp']) || firstDefined(payload, ['ts', 'timestamp', 'server.timestamp']) || Date.now(),
    raw: {
      ...payload,
      ...root,
      payload,
    },
  };
}

function extractRawEvents(body) {
  const envelopeContext = (body && typeof body === 'object')
    ? {
      topic: body.topic || null,
      event_type: body.event_type || null,
      type: body.type || null,
      device_id: body.device_id || body.deviceId || body.ident || body['device.id'] || null,
      user_id: body.user_id || body.userId || null,
      title: body.title || null,
      body: body.body || body.message || null,
      severity: body.severity || null,
      ts: body.ts || body.timestamp || body['server.timestamp'] || null,
      payload: (body.payload && typeof body.payload === 'object') ? body.payload : null,
    }
    : {};

  const mergeWithEnvelope = (item) => {
    const itemPayload = item && typeof item.payload === 'object' ? item.payload : null;
    const mergedPayload = {
      ...(envelopeContext.payload || {}),
      ...(itemPayload || {}),
    };

    return {
      ...envelopeContext,
      ...item,
      payload: Object.keys(mergedPayload).length > 0 ? mergedPayload : undefined,
    };
  };

  if (Array.isArray(body)) {
    return body
      .filter((item) => item && typeof item === 'object')
      .map(mergeWithEnvelope);
  }

  if (body && Array.isArray(body.data)) {
    return body.data
      .filter((item) => item && typeof item === 'object')
      .map(mergeWithEnvelope);
  }

  if (body && Array.isArray(body.result)) {
    return body.result
      .filter((item) => item && typeof item === 'object')
      .map(mergeWithEnvelope);
  }

  if (body && typeof body === 'object') {
    return [mergeWithEnvelope(body)];
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
  const topic = String(firstDefined(raw, ['topic', 'event.topic']) || '').toLowerCase();
  const intervalType = String(firstDefined(raw, ['type', 'interval.type', 'geofence.event']) || '').toLowerCase();
  const messageText = String(firstDefined(raw, ['message', 'body']) || event.body || '').toLowerCase();
  const geofenceRaw = firstDefined(raw, [
    'geofence',
    'geofence.name',
    'plugin.geofence.name',
    'name',
  ]);
  const geofenceName = geofenceRaw && typeof geofenceRaw === 'object'
    ? (firstDefined(geofenceRaw, ['name', 'title', 'id']) || null)
    : geofenceRaw;

  const topicActivated = topic.includes('/activated') && !topic.includes('/deactivated');
  const eventActivated = eventType.includes('activated') && !eventType.includes('deactivated');
  const topicDeactivated = topic.includes('/deactivated');
  const eventDeactivated = eventType.includes('deactivated');
  const geofenceStatusValue = firstDefined(raw, ['plugin.geofence.status', 'geofence.status']);
  const geofenceAlarmFlag = asBoolean(firstDefined(raw, [
    'geofence_alarm',
    'geofence.alarm',
    'plugin.geofence.alarm',
  ]));
  const geofenceSignal =
    geofenceRaw != null ||
    geofenceStatusValue != null ||
    topic.includes('geofence') ||
    eventType.includes('geofence') ||
    intervalType.includes('geofence');

  const geofenceEnter =
    intervalType === 'enter' ||
    intervalType === 'activated' ||
    eventType.includes('geofence_enter') ||
    (geofenceSignal && (messageText.includes('entrada') || messageText.includes(' enter'))) ||
    eventActivated ||
    topicActivated;

  const geofenceExit =
    intervalType === 'exit' ||
    intervalType === 'deactivated' ||
    eventType.includes('geofence_exit') ||
    (geofenceSignal && (messageText.includes('salida') || messageText.includes(' exit'))) ||
    eventDeactivated ||
    topicDeactivated;

  const geofenceAlarm = geofenceAlarmFlag || geofenceEnter || geofenceExit;

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
    geofence_status: firstDefined(raw, ['plugin.geofence.status', 'geofence.status']),
    geofence_enter: classification.geofenceEnter,
    geofence_exit: classification.geofenceExit,
    communication_active: classification.communicationActive,
    payload: raw,
    source_ts: toIsoFromMs(sourceTsMs),
    source_ts_ms: sourceTsMs,
    updated_at: new Date().toISOString(),
  };
}

async function fetchLatestCalcInterval(config, deviceId) {
  if (!config.flespiToken || !config.geofenceCalcId || !deviceId) {
    return null;
  }

  const url = new URL(
    `https://flespi.io/gw/calcs/${config.geofenceCalcId}/devices/${deviceId}/intervals/last`,
  );
  url.searchParams.set('data', JSON.stringify({
    fields: 'id,type,geofence,begin,end,timestamp',
  }));

  const response = await fetch(url.toString(), {
    method: 'GET',
    headers: {
      Authorization: `FlespiToken ${config.flespiToken}`,
    },
  });

  if (!response.ok) {
    return null;
  }

  const payload = await response.json();
  const interval = Array.isArray(payload?.result) ? payload.result[0] : null;
  if (!interval || interval.id == null) {
    return null;
  }

  const type = String(interval.type || '').toLowerCase();
  return {
    id: String(interval.id),
    type,
    geofence: interval.geofence == null ? null : String(interval.geofence),
    begin: interval.begin ?? null,
    end: interval.end ?? null,
    timestamp: interval.timestamp ?? null,
  };
}

async function persistEvent({ firestore, config, event, classification }) {
  if (!event.deviceId) {
    return { alertCreated: false, dedupeKey: null };
  }

  const raw = event.raw || {};
  const stateRef = firestore
    .collection(config.deviceStateCollection)
    .doc(String(event.deviceId));

  let previousState = null;
  let currentGeofenceStatus = null;
  let previousGeofenceStatus = null;

  const currentRaw = firstDefined(raw, ['plugin.geofence.status', 'geofence.status']);
  currentGeofenceStatus = currentRaw == null ? null : asBoolean(currentRaw);

  if (classification.communicationActive || currentGeofenceStatus != null) {
    const existingState = await stateRef.get();
    previousState = existingState.exists ? (existingState.data() || null) : null;

    const previousRaw = previousState ? previousState.geofence_status : null;
    previousGeofenceStatus = previousRaw == null ? null : asBoolean(previousRaw);
  }

  let latestCalcInterval = null;
  try {
    latestCalcInterval = await fetchLatestCalcInterval(config, event.deviceId);
  } catch (_) {
    latestCalcInterval = null;
  }

  let effectiveClassification = classification;
  if (
    !classification.geofenceAlarm &&
    currentGeofenceStatus != null &&
    previousGeofenceStatus != null &&
    currentGeofenceStatus !== previousGeofenceStatus
  ) {
    const inferredEnter = currentGeofenceStatus === true;
    const inferredExit = currentGeofenceStatus === false;
    const inferredName =
      classification.geofenceName ||
      firstDefined(raw, ['plugin.geofence.name', 'geofence.name', 'geofence']) ||
      (previousState ? previousState.geofence_name : null) ||
      null;

    effectiveClassification = {
      ...classification,
      geofenceAlarm: true,
      geofenceEnter: inferredEnter,
      geofenceExit: inferredExit,
      geofenceName: inferredName,
      shouldPush: true,
      severity: 'high',
      title: 'Alerta de geocerca',
      body: inferredName
        ? (inferredEnter
          ? `Entrada en geocerca: ${inferredName}`
          : `Salida de geocerca: ${inferredName}`)
        : (inferredEnter
          ? 'Entrada en geocerca detectada'
          : 'Salida de geocerca detectada'),
    };
  }

  if (
    !effectiveClassification.geofenceAlarm &&
    latestCalcInterval &&
    latestCalcInterval.id &&
    String(previousState?.last_calc_interval_id || '') !== latestCalcInterval.id
  ) {
    const isEnter = latestCalcInterval.type === 'enter' || latestCalcInterval.type === 'activated';
    const isExit = latestCalcInterval.type === 'exit' || latestCalcInterval.type === 'deactivated';
    const geofenceName = latestCalcInterval.geofence || null;

    effectiveClassification = {
      ...effectiveClassification,
      geofenceAlarm: true,
      geofenceEnter: isEnter,
      geofenceExit: isExit,
      geofenceName,
      shouldPush: true,
      severity: 'high',
      title: 'Alerta de geocerca',
      body: geofenceName
        ? (isEnter ? `Entrada en geocerca: ${geofenceName}` : `Salida de geocerca: ${geofenceName}`)
        : (isEnter ? 'Entrada en geocerca detectada' : 'Salida de geocerca detectada'),
    };
  }

  const snapshot = buildStateSnapshot(event, effectiveClassification);
  if (latestCalcInterval) {
    snapshot.last_calc_interval_id = latestCalcInterval.id;
    snapshot.last_calc_interval_type = latestCalcInterval.type;
    snapshot.last_calc_geofence = latestCalcInterval.geofence;
  }

  if (classification.communicationActive || currentGeofenceStatus != null || latestCalcInterval != null) {
    await stateRef.set(snapshot, { merge: true });

    if (config.storeStateHistory) {
      await firestore.collection(config.stateHistoryCollection).add(snapshot);
    }
  }

  if (effectiveClassification.vibrationAlarm || effectiveClassification.geofenceAlarm) {
    const dedupeBucket = effectiveClassification.vibrationAlarm
      ? Math.floor(snapshot.source_ts_ms / (VIBRATION_DEDUPE_WINDOW_SECONDS * 1000))
      : Math.floor(snapshot.source_ts_ms / (GEOFENCE_DEDUPE_WINDOW_SECONDS * 1000));

    const alertKind = effectiveClassification.vibrationAlarm
      ? 'vibration_alert'
      : (effectiveClassification.geofenceEnter
        ? 'geofence_enter'
        : (effectiveClassification.geofenceExit ? 'geofence_exit' : 'geofence_alert'));

    const dedupeSource = [
      String(event.deviceId),
      alertKind,
      effectiveClassification.geofenceName || '',
      String(dedupeBucket),
    ].join('|');

    const dedupeKey = makeStableId(dedupeSource);
    const alertRef = firestore.collection(config.alertsCollection).doc(dedupeKey);
    const existing = await alertRef.get();

    await alertRef.set({
      ...snapshot,
      dedupe_key: dedupeKey,
      event_id: event.eventId || null,
      event_kind: alertKind,
      message: effectiveClassification.body,
      severity: effectiveClassification.severity,
      checked: existing.exists ? Boolean(existing.data()?.checked) : false,
      checked_at: existing.exists ? (existing.data()?.checked_at || null) : null,
      created_at: existing.exists
        ? (existing.data()?.created_at || new Date().toISOString())
        : new Date().toISOString(),
      last_seen_at: new Date().toISOString(),
    }, { merge: true });

    return {
      alertCreated: !existing.exists,
      dedupeKey,
      eventKind: alertKind,
      classification: effectiveClassification,
    };
  }

  return {
    alertCreated: false,
    dedupeKey: null,
    eventKind: null,
    classification: effectiveClassification,
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

      const effectiveClassification =
        persistenceResult.classification || classification;

      if (!event.deviceId && !event.userId) {
        skippedNoRouting += 1;
        continue;
      }

      if (!effectiveClassification.shouldPush) {
        skippedNonAlert += 1;
        continue;
      }

      if ((effectiveClassification.vibrationAlarm || effectiveClassification.geofenceAlarm) && !persistenceResult.alertCreated) {
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
      payload.notification.title = effectiveClassification.title;
      payload.notification.body = effectiveClassification.body;
      payload.data.severity = effectiveClassification.severity;
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
