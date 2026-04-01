const { readConfig } = require('../src/config');
const { getFirestore, getMessaging } = require('../src/firebaseAdmin');
const {
  deactivateInvalidTokens,
  getActiveTokens,
} = require('../src/tokenRepository');

const { DateTime } = require('luxon');

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

function formatIsoInZone(ms, zone) {
  if (ms == null) {
    return DateTime.now().setZone(zone).toISO();
  }

  try {
    return DateTime.fromMillis(ms, { zone }).toISO();
  } catch (e) {
    return new Date(ms).toISOString();
  }
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

  const geofenceId = firstDefined(root, ['geofence_id', 'geofenceId', 'payload.geofence_id', 'payload.geofenceId'])
    || firstDefined(payload, ['geofence_id', 'geofenceId'])
    || null;

  const logCode = normalizeReportCode(firstDefined(root, ['log_code', 'logCode', 'payload.log_code', 'payload.logCode']))
    || null;

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

  const normalizedRaw = {
    ...root,
    ...payload,
    payload,
  };

  return {
    eventId: firstDefined(root, ['event_id', 'id', 'event.id']) || firstDefined(payload, ['event_id', 'id']) || null,
    deviceId: deviceId != null ? String(deviceId) : null,
    userId: (firstDefined(root, ['user_id', 'userId']) || firstDefined(payload, ['user_id', 'userId']) || null),
    eventType: String(inferredEventType),
    reportCode,
    geofenceId: geofenceId != null ? String(geofenceId) : null,
    logCode,
    title: firstDefined(root, ['title', 'notification.title']) || firstDefined(payload, ['title']) || 'Alerta OntaCoche',
    body: firstDefined(root, ['body', 'message', 'notification.body']) || firstDefined(payload, ['body', 'message']) || 'Se detecto una alerta en el tracker',
    severity: firstDefined(root, ['severity']) || firstDefined(payload, ['severity']) || 'info',
    ts: firstDefined(root, ['ts', 'timestamp', 'server.timestamp']) || firstDefined(payload, ['ts', 'timestamp', 'server.timestamp']) || Date.now(),
    tripBeginTs: firstDefined(root, ['begin', 'interval.begin', 'payload.begin']) || firstDefined(payload, ['begin', 'interval.begin']) || null,
    tripEndTs: firstDefined(root, ['end', 'interval.end', 'payload.end']) || firstDefined(payload, ['end', 'interval.end']) || null,
    raw: normalizedRaw,
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
  const geofenceRaw = firstDefined(raw, [
    'geofence',
    'geofence.name',
    'plugin.geofence.name',
    'name',
  ]);
  const explicitEnterGeofence = firstDefined(raw, ['enter_geofence', 'payload.enter_geofence']);
  const explicitExitGeofence = firstDefined(raw, ['exit_geofence', 'payload.exit_geofence']);
  const geofenceName = geofenceRaw && typeof geofenceRaw === 'object'
    ? (firstDefined(geofenceRaw, ['name', 'title', 'id']) || null)
    : geofenceRaw;

  const geofenceAlarmFlag = asBoolean(firstDefined(raw, [
    'geofence_alarm',
    'geofence.alarm',
    'plugin.geofence.alarm',
  ]));
  const geofenceSignal =
    geofenceRaw != null ||
    topic.includes('geofence') ||
    eventType.includes('geofence') ||
    intervalType.includes('geofence');

  const geofenceConfigChange =
    eventType.includes('geofence_update') ||
    event.logCode === '0002' ||
    event.logCode === '2' ||
    event.geofenceId != null ||
    topic.includes('/geofences/') ||
    topic.includes('flespi/log/gw/geofences');

  const geofenceEnterByField = asBoolean(explicitEnterGeofence);
  const geofenceExitByField = asBoolean(explicitExitGeofence);

  const geofenceEventKind = String(firstDefined(raw, [
    'event_kind',
    'payload.event_kind',
    'interval.event',
  ]) || '').toLowerCase();

  const geofenceEnter =
    geofenceSignal && (
      geofenceEnterByField ||
      intervalType === 'enter' ||
      intervalType === 'activated' ||
      geofenceEventKind === 'geofence_enter' ||
      eventType.includes('geofence_enter') ||
      topic.includes('/activated')
    );

  const geofenceExit =
    geofenceSignal && (
      geofenceExitByField ||
      intervalType === 'exit' ||
      intervalType === 'deactivated' ||
      geofenceEventKind === 'geofence_exit' ||
      eventType.includes('geofence_exit') ||
      topic.includes('/deactivated')
    );

  const geofenceAlarm = geofenceAlarmFlag || geofenceEnter || geofenceExit;

  const communicationActive = event.reportCode === '0200';
  const tripClosed =
    eventType === 'calculator_interval_closed' ||
    eventType === 'interval_closed' ||
    topic.includes('calculator_interval_closed') ||
    topic.includes('/interval/closed') ||
    (eventType.includes('calculator_interval') && event.tripEndTs != null);
  const shouldPush =
    vibrationAlarm || geofenceAlarm || (communicationActive && config.pushOnCommunicationActive);

  let title = event.title;
  let body = event.body;
  let severity = 'info';

  if (vibrationAlarm) {
    title = 'Alerta de vibración';
    body = 'Se detecto vibración en el tracker';
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
  } else if (geofenceConfigChange) {
    title = 'Geocerca actualizada';
    body = geofenceName
      ? `Se actualizo la geocerca: ${geofenceName}`
      : 'Se actualizo una geocerca';
    severity = 'info';
  }

  return {
    vibrationAlarm,
    geofenceAlarm,
    geofenceEnter,
    geofenceExit,
    geofenceName: geofenceName ? String(geofenceName) : null,
    geofenceConfigChange,
    communicationActive,
    tripClosed,
    shouldPush,
    title,
    body,
    severity,
  };
}

function resolveSourceTimestampMs(event, classification) {
  const raw = event.raw || {};

  // for closed intervals (trips) we want the interval edge, not webhook receive time
  if (classification && classification.tripClosed) {
    return (
      parseTimestampToMs(firstDefined(raw, ['end', 'interval.end', 'payload.end', 'begin', 'interval.begin', 'payload.begin'])) ||
      parseTimestampToMs(event.tripEndTs) ||
      parseTimestampToMs(event.tripBeginTs) ||
      parseTimestampToMs(firstDefined(raw, ['server.timestamp', 'timestamp'])) ||
      parseTimestampToMs(event.ts) ||
      Date.now()
    );
  }

  // for alerts/state snapshots use event time first to avoid stale interval begin values
  return (
    parseTimestampToMs(firstDefined(raw, ['server.timestamp', 'timestamp'])) ||
    parseTimestampToMs(event.ts) ||
    parseTimestampToMs(firstDefined(raw, ['end', 'interval.end', 'payload.end', 'begin', 'interval.begin', 'payload.begin'])) ||
    Date.now()
  );
}

function buildStateSnapshot(event, classification, config) {
  const raw = event.raw || {};
  const sourceTsMs = resolveSourceTimestampMs(event, classification);
  const batteryLevel = firstDefined(raw, ['battery.level', 'battery_level']);
  const batteryVoltage = firstDefined(raw, ['battery.voltage', 'battery_voltage', 'battery.v']);
  const position = {
    altitude: firstDefined(raw, ['position.altitude', 'altitude']) || 0,
    direction: firstDefined(raw, ['position.direction', 'direction']) || 0,
    latitude: firstDefined(raw, ['position.latitude', 'latitude']),
    longitude: firstDefined(raw, ['position.longitude', 'longitude']),
    satellites: firstDefined(raw, ['position.satellites', 'satellites']) || 0,
    speed: firstDefined(raw, ['position.speed', 'speed']) || 0,
  };

  const deviceName = firstDefined(raw, ['device.name', 'deviceName', 'device.name']) || null;

  const snapshot = {
    battery: {
      level: batteryLevel == null ? null : Number(batteryLevel),
      voltage: batteryVoltage == null ? null : Number(batteryVoltage),
    },
    communication_active: Boolean(classification.communicationActive),
    device: { id: event.deviceId ? String(event.deviceId) : null, name: deviceName || null },
    position,
    source_ts_ms: sourceTsMs,
    source_ts: formatIsoInZone(sourceTsMs, (config && config.timezone) || 'UTC'),
    updated_at: new Date().toISOString(),
  };

  return snapshot;
}

function normalizeNumber(value) {
  if (value == null || value === '') {
    return null;
  }

  const num = Number(value);
  return Number.isFinite(num) ? num : null;
}

function parseTripPayload(event, classification) {
  if (!classification.tripClosed) {
    return null;
  }

  const raw = event.raw || {};
  const beginMs = parseTimestampToMs(firstDefined(raw, ['begin', 'interval.begin', 'payload.begin']) || event.tripBeginTs);
  const endMs = parseTimestampToMs(firstDefined(raw, ['end', 'interval.end', 'payload.end']) || event.tripEndTs);

  if (beginMs == null || endMs == null || endMs < beginMs) {
    return null;
  }

  const distanceM =
    normalizeNumber(firstDefined(raw, [
      'distance',
      'distance_m',
      'mileage',
      'interval.distance',
      'payload.distance',
      'summary.distance',
    ])) || 0;
  const maxSpeedKph =
    normalizeNumber(firstDefined(raw, [
      'max_speed',
      'max_speed_kph',
      'max.speed',
      'interval.max_speed',
      'payload.max_speed',
      'summary.max_speed',
    ])) || 0;

  const polylineEncoded = firstDefined(raw, [
    'polyline',
    'polyline_encoded',
    'interval.polyline',
    'route.polyline',
    'payload.polyline',
  ]);

  return {
    beginMs,
    endMs,
    distanceM,
    maxSpeedKph,
    polylineEncoded: typeof polylineEncoded === 'string' ? polylineEncoded : null,
  };
}

function buildTripDocument(event, trip) {
  return {
    deviceId: String(event.deviceId),
    startedAt: toIsoFromMs(trip.beginMs),
    endedAt: toIsoFromMs(trip.endMs),
    durationSec: Math.max(0, Math.floor((trip.endMs - trip.beginMs) / 1000)),
    distanceM: trip.distanceM,
    maxSpeedKph: trip.maxSpeedKph,
    polylineEncoded: trip.polylineEncoded,
    source: 'flespi_calculator',
    eventId: event.eventId || null,
    createdAt: new Date().toISOString(),
  };
}

async function writeAlertDocument({ firestore, config, event, alertKind, alertDoc }) {
  const collection = firestore.collection(config.alertsCollection);

  if (event.eventId) {
    const docId = `${String(event.eventId)}:${alertKind}`;
    try {
      await collection.doc(docId).create(alertDoc);
      return { created: true, id: docId };
    } catch (error) {
      if (error && error.code === 6) {
        return { created: false, id: docId };
      }
      throw error;
    }
  }

  const docRef = await collection.add(alertDoc);
  return { created: true, id: docRef.id };
}

async function persistEvent({ firestore, config, event, classification }) {
  if (!event.deviceId) {
    return { alertCreated: false, dedupeKey: null };
  }

  const raw = event.raw || {};
  const deviceIdStr = String(event.deviceId);
  const stateRef = firestore.collection(config.deviceStateCollection).doc(deviceIdStr);

  const snapshot = buildStateSnapshot(event, classification, config);
  const writeSnapshot = { ...snapshot };
  delete writeSnapshot.source_ts_ms;
  delete writeSnapshot.updated_at;

  const isPeriodicPos = event.reportCode === '0200';
  const hasValidGPS = snapshot.position.latitude != null && snapshot.position.longitude != null;

  if (config.storeStateHistory && isPeriodicPos && hasValidGPS) {
    const historyCol = firestore.collection(config.stateHistoryCollection);
    const historyDocRef = historyCol.doc();
    const batch = firestore.batch();
    batch.set(historyDocRef, writeSnapshot);
    batch.set(stateRef, writeSnapshot);
    await batch.commit();
  }

  if (!config.storeStateHistory) {
    try {
      await stateRef.set(writeSnapshot);
    } catch (e) {
      writeLog('error', 'failed to write device_last_state', { deviceId: deviceIdStr, error: e.message });
    }
  }

  const tripPayload = parseTripPayload(event, classification);
  if (tripPayload) {
    const tripsCollection = config.tripsCollection || 'device_trips';
    const tripDoc = buildTripDocument(event, tripPayload);
    if (event.eventId) {
      await firestore.collection(tripsCollection).doc(String(event.eventId)).set(tripDoc, { merge: true });
    } else {
      await firestore.collection(tripsCollection).add(tripDoc);
    }
  }

  if (classification.vibrationAlarm || classification.geofenceAlarm) {
    const alertKind = classification.vibrationAlarm
      ? 'vibration_alert'
      : (classification.geofenceEnter
        ? 'geofence_enter'
        : (classification.geofenceExit ? 'geofence_exit' : 'geofence_alert'));

    const alertDocBase = {
      source_ts: snapshot.source_ts,
      device: { id: deviceIdStr, name: snapshot.device?.name || null },
      event_id: event.eventId || null,
      event_kind: alertKind,
      severity: classification.severity,
      checked: false,
      checked_at: null,
      created_at: new Date().toISOString(),
    };

    const alertDoc = classification.vibrationAlarm
      ? {
        ...alertDocBase,
        vibration_alarm: true,
        message: classification.body || 'Se detecto vibración en el tracker',
      }
      : {
        ...alertDocBase,
        geofence_alarm: Boolean(classification.geofenceAlarm),
        geofence_enter: Boolean(classification.geofenceEnter),
        geofence_exit: Boolean(classification.geofenceExit),
        geofence_name: classification.geofenceName || null,
        message: classification.body || null,
      };

    const writeResult = await writeAlertDocument({
      firestore,
      config,
      event,
      alertKind,
      alertDoc,
    });

    return {
      alertCreated: writeResult.created,
      dedupeKey: writeResult.id,
      eventKind: alertKind,
      classification,
    };
  }

  return {
    alertCreated: false,
    dedupeKey: null,
    eventKind: null,
    classification,
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