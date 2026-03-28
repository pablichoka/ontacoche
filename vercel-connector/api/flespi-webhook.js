require('../src/compat-url');
const { readConfig } = require('../src/config');
const { getFirestore, getMessaging } = require('../src/firebaseAdmin');
const admin = require('firebase-admin');
const {
  deactivateInvalidTokens,
  getActiveTokens,
} = require('../src/tokenRepository');

const { DateTime } = require('luxon');

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
  }
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
  const messageText = String(firstDefined(raw, ['message', 'body']) || event.body || '').toLowerCase();
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

  const geofenceConfigChange =
    eventType.includes('geofence_update') ||
    event.logCode === '0002' ||
    event.logCode === '2' ||
    event.geofenceId != null ||
    topic.includes('/geofences/') ||
    topic.includes('flespi/log/gw/geofences');

  const hasExplicitIntervalDirection =
    intervalType === 'enter' || intervalType === 'exit';

  const geofenceEnterByField = explicitEnterGeofence != null && explicitEnterGeofence !== 'null';
  const geofenceExitByField = explicitExitGeofence != null && explicitExitGeofence !== 'null';

  const geofenceEnter =
    geofenceEnterByField ||
    (!geofenceExitByField && intervalType === 'enter') ||
    (!hasExplicitIntervalDirection && (
      intervalType === 'activated' ||
      eventType.includes('geofence_enter') ||
      (geofenceSignal && (messageText.includes('entrada') || messageText.includes(' enter'))) ||
      eventActivated ||
      topicActivated
    ));

  const geofenceExit =
    geofenceExitByField ||
    (!geofenceEnterByField && intervalType === 'exit') ||
    (!hasExplicitIntervalDirection && (
      intervalType === 'deactivated' ||
      eventType.includes('geofence_exit') ||
      (geofenceSignal && (messageText.includes('salida') || messageText.includes(' exit'))) ||
      eventDeactivated ||
      topicDeactivated
    ));

  const geofenceAlarm = geofenceAlarmFlag || geofenceEnter || geofenceExit;

  const communicationActive = event.reportCode === '0200';
  const shouldPush =
    vibrationAlarm || geofenceAlarm || (communicationActive && config.pushOnCommunicationActive);

  let title = event.title;
  let body = event.body;
  let severity = 'info';

  if (vibrationAlarm) {
    title = 'Alerta de vibración';
    body = 'Se detectó vibración en el tracker';
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
    shouldPush: shouldPush || geofenceConfigChange,
    title,
    body,
    severity,
  };
}

function buildStateSnapshot(event, classification, config) {
  const raw = event.raw || {};
  const sourceTsMs =
    parseTimestampToMs(firstDefined(raw, ['server.timestamp', 'timestamp', 'end', 'begin'])) ||
    parseTimestampToMs(event.ts) ||
    Date.now();
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

async function persistEvent({ firestore, config, event, classification }) {
  if (!event.deviceId) {
    return { alertCreated: false, dedupeKey: null };
  }

  const raw = event.raw || {};
  const stateRef = firestore
    .collection(config.deviceStateCollection)
    .doc(String(event.deviceId));

  let currentGeofenceStatus = null;

  const currentRaw = firstDefined(raw, ['plugin.geofence.status', 'geofence.status']);
  currentGeofenceStatus = currentRaw == null ? null : asBoolean(currentRaw);

  let effectiveClassification = classification;

  const snapshot = buildStateSnapshot(event, effectiveClassification, config);
  // create a write-safe copy that strips internal timestamp fields
  const writeSnapshot = { ...snapshot };
  delete writeSnapshot.source_ts_ms;
  delete writeSnapshot.updated_at;

  // Only persist state when the event is a flespi-origin '0200' report.
  // Detect flespi-origin by presence of server.timestamp, channel.id or a topic containing 'flespi'.
  const serverTs = firstDefined(raw, ['server.timestamp', 'server_ts', 'timestamp']);
  const rawTopic = firstDefined(raw, ['topic', 'event.topic', 'payload.topic']) || '';
  const channelId = firstDefined(raw, ['channel.id', 'payload.channel.id']);
  const isFromFlespi = serverTs != null || channelId != null || (typeof rawTopic === 'string' && rawTopic.toLowerCase().includes('flespi'));

  if (String(event.reportCode || '') !== '0200' || !isFromFlespi) {
    // Do not write any state/history for non-0200 or non-flespi messages.
    return { alertCreated: false, dedupeKey: null, classification: effectiveClassification, skippedStateWrite: true };
  }

  // if payload didn't include a device.name, try to preserve an existing one
  let existingStateDoc = null;
  try {
    existingStateDoc = await stateRef.get();
  } catch (e) {
    existingStateDoc = null;
  }

  if ((!writeSnapshot.device || writeSnapshot.device.name == null) && existingStateDoc && existingStateDoc.exists) {
    try {
      const existingData = existingStateDoc.data();
      if (existingData && existingData.device && existingData.device.name) {
        writeSnapshot.device = writeSnapshot.device || {};
        writeSnapshot.device.name = existingData.device.name;
      }
    } catch (e) {
      // ignore and continue
    }
  }

  let skipStateWrite = false;
  if (existingStateDoc && existingStateDoc.exists) {
    try {
      const existingData = existingStateDoc.data() || {};
      const existingPos = existingData.position || {};
      const newPos = writeSnapshot.position || {};
      
      if (newPos.latitude == null || newPos.longitude == null) {
        writeSnapshot.position = existingPos;
        Object.assign(newPos, existingPos);
      }
      
      const isStationary = existingPos.speed === 0 && newPos.speed === 0;
      
      const identicalPos = isStationary || (
        existingPos.latitude === newPos.latitude && 
        existingPos.longitude === newPos.longitude &&
        existingPos.speed === newPos.speed &&
        existingPos.direction === newPos.direction
      );
        
      const existingActive = Boolean(existingData.communication_active);
      const newActive = Boolean(writeSnapshot.communication_active);
        
      const tsDiffMs = writeSnapshot.source_ts_ms - (existingData.source_ts_ms || 0);

      const isAlert = effectiveClassification.vibrationAlarm || effectiveClassification.geofenceAlarm || effectiveClassification.geofenceConfigChange;

      // When tracker is active, limit state writes to 1 per minute. Otherwise use 2 minutes
      const ACTIVE_DEDUPE_MS = 60 * 1000; // 1 minute
      const INACTIVE_DEDUPE_MS = 2 * 60 * 1000; // 2 minutes
      const dedupeThresholdMs = (existingActive && newActive) ? ACTIVE_DEDUPE_MS : INACTIVE_DEDUPE_MS;

      if (!isAlert && identicalPos && existingActive === newActive && tsDiffMs >= 0 && tsDiffMs < dedupeThresholdMs) {
        skipStateWrite = true;
      }

      // Additionally, enforce 1/min throttle while active regardless of identical position
      if (!isAlert && existingActive && newActive && tsDiffMs >= 0 && tsDiffMs < ACTIVE_DEDUPE_MS) {
        skipStateWrite = true;
      }
    } catch (e) {
      // ignore
    }
  }

  const writeOps = [];
  if (!skipStateWrite) {
    // Ensure no null fields in the document we persist
    writeSnapshot.device = writeSnapshot.device || {};
    writeSnapshot.device.id = writeSnapshot.device.id != null ? String(writeSnapshot.device.id) : (event.deviceId ? String(event.deviceId) : '');
    writeSnapshot.device.name = writeSnapshot.device.name != null ? String(writeSnapshot.device.name) : '';

    const pos = writeSnapshot.position || {};
    writeSnapshot.position = {
      latitude: pos.latitude != null ? Number(pos.latitude) : 0,
      longitude: pos.longitude != null ? Number(pos.longitude) : 0,
      altitude: pos.altitude != null ? Number(pos.altitude) : 0,
      direction: pos.direction != null ? Number(pos.direction) : 0,
      satellites: pos.satellites != null ? Number(pos.satellites) : 0,
      speed: pos.speed != null ? Number(pos.speed) : 0,
    };

    writeSnapshot.battery = writeSnapshot.battery || {};
    writeSnapshot.battery.level = writeSnapshot.battery.level != null ? Number(writeSnapshot.battery.level) : 0;
    writeSnapshot.battery.voltage = writeSnapshot.battery.voltage != null ? Number(writeSnapshot.battery.voltage) : 0;

    writeSnapshot.source_ts = writeSnapshot.source_ts || new Date().toISOString();
    writeSnapshot.source_ts_ms = Number(writeSnapshot.source_ts_ms) || Date.parse(writeSnapshot.source_ts) || Date.now();
    writeSnapshot.updated_at = writeSnapshot.updated_at || new Date().toISOString();

    writeOps.push(stateRef.set(writeSnapshot, { merge: true }));

    // Only persist in the state history if the event appears to have originated from flespi
    const serverTs = firstDefined(raw, ['server.timestamp', 'server_ts', 'timestamp']);
    const rawTopic = firstDefined(raw, ['topic', 'event.topic']) || '';
    const isFromFlespi = serverTs != null || (typeof rawTopic === 'string' && rawTopic.toLowerCase().includes('flespi'));

    if (config.storeStateHistory && isFromFlespi) {
      writeOps.push(firestore.collection(config.stateHistoryCollection).add(writeSnapshot));
    }
  }
  
  if (writeOps.length > 0) {
    await Promise.all(writeOps);
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

    const geofenceIntervalId =
      effectiveClassification.geofenceAlarm && event.eventId != null
        ? String(event.eventId)
        : null;

    const geofenceTopic = String(firstDefined(raw, ['topic', 'event.topic']) || '').toLowerCase();
    const geofenceIntervalEnd = firstDefined(raw, ['end', 'interval.end']);

    const dedupeKey = geofenceIntervalId
      ? makeStableId([
        'gf',
        String(event.deviceId),
        geofenceIntervalId,
        alertKind,
        effectiveClassification.geofenceName || '',
        // allows updated interval transitions to be persisted when end changes due to geofence resize/recalc
        geofenceTopic.includes('/updated') && geofenceIntervalEnd != null
          ? String(geofenceIntervalEnd)
          : '',
      ].join('|'))
      : makeStableId([
        String(event.deviceId),
        alertKind,
        effectiveClassification.geofenceName || '',
        String(dedupeBucket),
      ].join('|'));
    const alertRef = firestore.collection(config.alertsCollection).doc(dedupeKey);

    // Build a compact alert document to store only essential fields
    const resolvedDeviceName = (writeSnapshot.device && writeSnapshot.device.name) ? writeSnapshot.device.name : (snapshot.device?.name || null);

    const alertDocBase = {
      source_ts: snapshot.source_ts,
      device: { id: String(event.deviceId), name: resolvedDeviceName || null },
      dedupe_key: dedupeKey,
      event_id: event.eventId || null,
      event_kind: alertKind,
      severity: effectiveClassification.severity,
    };

    const alertDoc = effectiveClassification.vibrationAlarm
      ? {
        ...alertDocBase,
        vibration_alarm: true,
        message: effectiveClassification.body || 'Se detecto vibración en el tracker',
      }
      : {
        ...alertDocBase,
        geofence_alarm: Boolean(effectiveClassification.geofenceAlarm),
        geofence_enter: Boolean(effectiveClassification.geofenceEnter),
        geofence_exit: Boolean(effectiveClassification.geofenceExit),
        geofence_name: effectiveClassification.geofenceName || null,
        message: effectiveClassification.body || null,
      };

    // Use a transaction to avoid race conditions that can create duplicate alerts
    const txResult = await firestore.runTransaction(async (tx) => {
      const doc = await tx.get(alertRef);
      const exists = doc.exists;
      const checked = exists ? Boolean(doc.data()?.checked) : false;
      const checked_at = exists ? (doc.data()?.checked_at || null) : null;

      const toSet = {
        ...alertDoc,
        checked,
        checked_at,
        last_seen_at: new Date().toISOString(),
        created_at: exists ? (doc.data()?.created_at || new Date().toISOString()) : new Date().toISOString(),
      };

      tx.set(alertRef, toSet, { merge: true });
      return { created: !exists };
    });

    // remove forbidden legacy fields if present (best-effort)
    try {
      await alertRef.update({
        source_ts_ms: admin.firestore.FieldValue.delete(),
        created_at: admin.firestore.FieldValue.delete(),
        last_seen_at: admin.firestore.FieldValue.delete(),
      });
    } catch (e) {
      // ignore if update fails (e.g., no-op)
    }

    return {
      alertCreated: Boolean(txResult && txResult.created),
      dedupeKey,
      eventKind: alertKind,
      classification: effectiveClassification,
      skippedStateWrite: skipStateWrite,
    };
  }

  if (effectiveClassification.geofenceConfigChange) {
    const geofenceChangeId = makeStableId([
      'gfcfg',
      String(event.geofenceId || event.eventId || event.deviceId || 'unknown'),
      String(event.eventType || ''),
      String(firstDefined(raw, ['timestamp', 'server.timestamp']) || event.ts || ''),
    ].join('|'));

    const alertRef = firestore.collection(config.alertsCollection).doc(geofenceChangeId);
    const existing = await alertRef.get();

    await alertRef.set({
      ...snapshot,
      geofence_id: event.geofenceId || null,
      dedupe_key: geofenceChangeId,
      event_id: event.eventId || null,
      event_kind: 'geofence_config_change',
      message: effectiveClassification.body,
      severity: effectiveClassification.severity,
      checked: existing.exists ? Boolean(existing.data()?.checked) : true,
      checked_at: existing.exists ? (existing.data()?.checked_at || null) : new Date().toISOString(),
      created_at: existing.exists
        ? (existing.data()?.created_at || new Date().toISOString())
        : new Date().toISOString(),
      ...(existing.exists ? {} : { last_seen_at: new Date().toISOString() }),
    }, { merge: true });

    return {
      alertCreated: !existing.exists,
      dedupeKey: geofenceChangeId,
      eventKind: 'geofence_config_change',
      classification: effectiveClassification,
      skippedStateWrite: skipStateWrite,
    };
  }

  return {
    alertCreated: false,
    dedupeKey: null,
    eventKind: null,
    classification: effectiveClassification,
    skippedStateWrite: skipStateWrite,
  };
}

const TRIP_GAP_THRESHOLD_MS = 5 * 60 * 1000;

async function processTripPoint({ firestore, config, deviceId, snapshot }) {
  const lat = snapshot.position?.latitude;
  const lng = snapshot.position?.longitude;
  if (lat == null || lng == null) return;

  const speed = snapshot.position?.speed ?? 0;
  const pointTs = snapshot.source_ts_ms ?? Date.now();
  const stateRef = firestore.collection(config.deviceStateCollection).doc(String(deviceId));

  try {
    const stateDoc = await stateRef.get();
    const stateData = stateDoc.exists ? stateDoc.data() : {};
    const currentTripId = stateData.currentTripId || null;
    const lastPointTs = stateData.lastPointTimestamp || null;
    const gap = lastPointTs != null ? pointTs - lastPointTs : Infinity;

    const routePoint = { lat, lng, speed, timestamp: pointTs };

    if (currentTripId && gap <= TRIP_GAP_THRESHOLD_MS) {
      const tripRef = firestore.collection(config.tripsCollection).doc(currentTripId);
      await tripRef.update({
        routePoints: admin.firestore.FieldValue.arrayUnion(routePoint),
        endTime: pointTs,
      });
      await stateRef.update({ lastPointTimestamp: pointTs });
      return;
    }

    if (currentTripId && gap > TRIP_GAP_THRESHOLD_MS) {
      try {
        const oldTripRef = firestore.collection(config.tripsCollection).doc(currentTripId);
        const oldTripDoc = await oldTripRef.get();
        if (oldTripDoc.exists) {
          const data = oldTripDoc.data();
          const pts = data.routePoints || [];
          let trailingStatic = 0;
          for (let i = pts.length - 1; i >= 0 && trailingStatic < 5; i--) {
            if ((pts[i].speed || 0) === 0) {
              trailingStatic++;
            } else {
              break;
            }
          }
          const activeEnd = pts.length - trailingStatic;
          const startMs = data.startTime || (pts.length > 0 ? pts[0].timestamp : pointTs);
          const endMs = activeEnd > 0 ? pts[activeEnd - 1].timestamp : startMs;
          const activeDuration = Math.max(0, Math.round((endMs - startMs) / 60000));
          await oldTripRef.update({ activeDurationMinutes: activeDuration });
        }
      } catch (e) {
        writeLog('warn', 'failed to close previous trip', { deviceId, error: e.message });
      }
    }

    const newTripRef = firestore.collection(config.tripsCollection).doc();
    await newTripRef.set({
      deviceIdent: String(deviceId),
      startTime: pointTs,
      endTime: pointTs,
      activeDurationMinutes: null,
      routePoints: [routePoint],
    });
    await stateRef.update({
      currentTripId: newTripRef.id,
      lastPointTimestamp: pointTs,
    });
  } catch (e) {
    writeLog('error', 'trip processing failed', { deviceId, error: e.message });
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

  function consolidateEvents(eventsList) {
    const byDevice = new Map();
    const nonDeviceEvents = [];

    for (const event of eventsList) {
      const key = event.deviceId || event.userId;
      if (!key) {
        nonDeviceEvents.push(event);
        continue;
      }

      if (!byDevice.has(key)) {
        byDevice.set(key, { ...event });
      } else {
        const existing = byDevice.get(key);
        existing.raw = { ...existing.raw, ...event.raw };
        
        const newTs = parseTimestampToMs(event.ts);
        const oldTs = parseTimestampToMs(existing.ts);
        if (newTs && oldTs && newTs > oldTs) {
          existing.ts = event.ts;
        } else if (newTs && !oldTs) {
          existing.ts = event.ts;
        }
        
        if (event.eventId && !existing.eventId) existing.eventId = event.eventId;
        if (event.reportCode) existing.reportCode = event.reportCode;
        if (event.logCode) existing.logCode = event.logCode;
        if (event.geofenceId) existing.geofenceId = event.geofenceId;
        
        if (event.eventType && event.eventType !== 'flespi_event') existing.eventType = event.eventType;
        if (event.title && event.title !== 'Alerta OntaCoche') existing.title = event.title;
        if (event.body && event.body !== 'Se detecto una alerta en el tracker') existing.body = event.body;
        if (event.severity && event.severity !== 'info') existing.severity = event.severity;
      }
    }

    return [...byDevice.values(), ...nonDeviceEvents];
  }

  const events = consolidateEvents(rawEvents.map(normalizeEvent));

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
        const tripSnapshot = buildStateSnapshot(event, classification, config);

        const persistedRes = await persistEvent({
          firestore,
          config,
          event,
          classification,
        });

        // Add to trip only if a state write actually happened AND coords are valid.
        if (!persistedRes.skippedStateWrite && tripSnapshot.position?.latitude != null && tripSnapshot.position?.longitude != null) {
          await processTripPoint({ firestore, config, deviceId: event.deviceId, snapshot: tripSnapshot });
        }
        
        persistenceResult = persistedRes;
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
