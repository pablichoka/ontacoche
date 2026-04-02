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

function sanitizeEventId(value) {
  if (value == null) {
    return null;
  }

  const normalized = String(value).trim();
  if (!normalized) {
    return null;
  }

  if (normalized.toLowerCase() === 'null') {
    return null;
  }

  if (normalized.toLowerCase().startsWith('null_')) {
    return null;
  }

  return normalized;
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
    eventId: sanitizeEventId(firstDefined(root, ['event_id', 'id', 'event.id']) || firstDefined(payload, ['event_id', 'id']) || null),
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
  const intervalType = String(firstDefined(raw, ['type', 'interval.type']) || '').toLowerCase();
  const eventKind = String(firstDefined(raw, ['event_kind', 'payload.event_kind']) || '').toLowerCase();
  const reasonCode = normalizeNumber(firstDefined(raw, ['reason_code', 'user_properties.reason_code', 'payload.reason_code']));
  const allowedReasons = Array.isArray(config.geofenceAllowedReasonCodes)
    ? config.geofenceAllowedReasonCodes
    : [20, 2, 48];
  const allowedRuntimeReason = reasonCode == null || allowedReasons.includes(Number(reasonCode));

  const enterByKind = eventKind === 'geofence_enter' || eventKind === 'enter';
  const exitByKind = eventKind === 'geofence_exit' || eventKind === 'exit';
  const enterByType = intervalType === 'enter' || intervalType === 'activated' || eventType.includes('geofence_enter');
  const exitByType = intervalType === 'exit' || intervalType === 'deactivated' || eventType.includes('geofence_exit');
  const enterByField = asBoolean(firstDefined(raw, ['geofence_enter', 'enter_geofence', 'payload.geofence_enter', 'payload.enter_geofence']));
  const exitByField = asBoolean(firstDefined(raw, ['geofence_exit', 'exit_geofence', 'payload.geofence_exit', 'payload.exit_geofence']));

  const hasEnter = allowedRuntimeReason && (enterByKind || enterByType || enterByField);
  const hasExit = allowedRuntimeReason && (exitByKind || exitByType || exitByField);
  const geofenceTransitionAmbiguous = hasEnter === hasExit && (hasEnter || hasExit);

  const geofenceEnter = hasEnter && !hasExit;
  const geofenceExit = hasExit && !hasEnter;
  const geofenceAlarm = geofenceEnter || geofenceExit;

  const geofenceNameRaw = firstDefined(raw, [
    'geofence_name',
    'payload.geofence_name',
    'geofence.name',
    'payload.geofence.name',
    'plugin.geofence.name',
    'enter_geofence',
    'exit_geofence',
  ]);
  const geofenceName = geofenceNameRaw == null || typeof geofenceNameRaw === 'boolean'
    ? null
    : String(geofenceNameRaw).trim() || null;

  const communicationActive = event.reportCode === '0200';
  const tripClosed = false;

  const shouldPush =
    vibrationAlarm ||
    geofenceAlarm ||
    (communicationActive && config.pushOnCommunicationActive);

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
    } else if (geofenceEnter) {
      body = 'Entrada en geocerca detectada';
    } else if (geofenceExit) {
      body = 'Salida de geocerca detectada';
    } else {
      body = null;
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
    geofenceConfigChange: false,
    geofenceTransitionAmbiguous,
    transitionDirection,
    reasonCode: reasonCode == null ? null : Number(reasonCode),
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

  // for geofence transitions prefer interval edges; otherwise fallback to event timestamps.
  if (classification && classification.geofenceAlarm) {
    const edgePriority = classification.transitionDirection === 'exit'
      ? ['end', 'interval.end', 'payload.end', 'begin', 'interval.begin', 'payload.begin']
      : ['begin', 'interval.begin', 'payload.begin', 'end', 'interval.end', 'payload.end'];

    return (
      parseTimestampToMs(firstDefined(raw, edgePriority)) ||
      parseTimestampToMs(firstDefined(raw, ['ts', 'payload.ts', 'timestamp', 'payload.timestamp'])) ||
      parseTimestampToMs(event.ts) ||
      parseTimestampToMs(firstDefined(raw, ['server.timestamp'])) ||
      Date.now()
    );
  }

  // for alerts/state snapshots use event time first to avoid stale interval begin values
  return (
    parseTimestampToMs(firstDefined(raw, ['ts', 'payload.ts', 'timestamp', 'payload.timestamp'])) ||
    parseTimestampToMs(event.ts) ||
    parseTimestampToMs(firstDefined(raw, ['server.timestamp'])) ||
    parseTimestampToMs(firstDefined(raw, ['end', 'interval.end', 'payload.end', 'begin', 'interval.begin', 'payload.begin'])) ||
    Date.now()
  );
}

function buildSyntheticAlertEventId(event, classification, sourceTsMs) {
  const direction = classification.geofenceEnter ? 'enter' : (classification.geofenceExit ? 'exit' : 'none');
  const geofenceKey = classification.geofenceName || event.geofenceId || 'unknown';
  const normalizedGeofenceKey = String(geofenceKey)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '_')
    .slice(0, 64) || 'unknown';
  const deviceKey = String(event.deviceId || 'unknown').replace(/[^a-zA-Z0-9_-]+/g, '_');
  const bucket = Math.floor((Number(sourceTsMs) || Date.now()) / 1000);
  return `gf_${deviceKey}_${direction}_${normalizedGeofenceKey}_${bucket}`;
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

function normalizeTripPoint(point) {
  if (!point || typeof point !== 'object') {
    return null;
  }

  const lat = normalizeNumber(firstDefined(point, ['lat', 'latitude', 'position.latitude']));
  const lng = normalizeNumber(firstDefined(point, ['lng', 'lon', 'longitude', 'position.longitude']));
  if (lat == null || lng == null) {
    return null;
  }

  const speed = normalizeNumber(firstDefined(point, ['speed', 'spd', 'position.speed']));
  const altitude = normalizeNumber(firstDefined(point, ['altitude', 'alt', 'position.altitude']));
  const ts = parseTimestampToMs(firstDefined(point, ['ts', 'timestamp', 'time', 'server.timestamp']));

  return {
    lat,
    lng,
    speed,
    altitude,
    ts,
  };
}

function downsampleTripPoints(points, maxPoints) {
  if (!Array.isArray(points) || points.length <= maxPoints) {
    return points;
  }

  const sampled = [];
  const step = (points.length - 1) / (maxPoints - 1);
  for (let i = 0; i < maxPoints; i += 1) {
    const index = Math.round(i * step);
    sampled.push(points[Math.min(index, points.length - 1)]);
  }

  return sampled;
}

function parseTripPoints(raw) {
  const rawTripPoints = firstDefined(raw, [
    'tripPoints',
    'trip_points',
    'payload.tripPoints',
    'payload.trip_points',
    'interval.tripPoints',
    'interval.trip_points',
    'dataset.tripPoints',
    'dataset.trip_points',
  ]);

  if (!Array.isArray(rawTripPoints) || rawTripPoints.length === 0) {
    return [];
  }

  return rawTripPoints
    .map(normalizeTripPoint)
    .filter((point) => point != null);
}

function buildTripDocument(event, trip) {
  const doc = {
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

  if (Array.isArray(trip.tripPoints) && trip.tripPoints.length > 0) {
    doc.tripPoints = trip.tripPoints;
    doc.tripPointsCount = trip.tripPointsCount;
    doc.tripPointsSampled = Boolean(trip.tripPointsSampled);
  }

  return doc;
}

function haversineDistanceM(a, b) {
  if (!a || !b) {
    return 0;
  }
  const lat1 = Number(a.lat);
  const lon1 = Number(a.lng);
  const lat2 = Number(b.lat);
  const lon2 = Number(b.lng);
  if (![lat1, lon1, lat2, lon2].every(Number.isFinite)) {
    return 0;
  }

  const toRad = (deg) => (deg * Math.PI) / 180;
  const earth = 6371000;
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const x =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) *
      Math.sin(dLon / 2) * Math.sin(dLon / 2);
  const c = 2 * Math.atan2(Math.sqrt(x), Math.sqrt(1 - x));
  return earth * c;
}

function parsePositionPoint(raw, sourceTsMs) {
  const lat = normalizeNumber(firstDefined(raw, ['position.latitude', 'latitude']));
  const lng = normalizeNumber(firstDefined(raw, ['position.longitude', 'longitude']));
  if (lat == null || lng == null) {
    return null;
  }

  return {
    lat,
    lng,
    speed: normalizeNumber(firstDefined(raw, ['position.speed', 'speed'])) || 0,
    altitude: normalizeNumber(firstDefined(raw, ['position.altitude', 'altitude'])),
    ts: sourceTsMs,
  };
}

function isMovementTelemetry(event, config, point, runtimeState) {
  if (!point || event.reportCode !== '0200') {
    return false;
  }

  const speed = Number(point.speed || 0);
  const minSpeed = Number(config.tripMinSpeedKph || 8);
  if (speed >= minSpeed) {
    return true;
  }

  const minMoveDistance = Number(config.tripMinMoveDistanceM || 50);
  const previous = runtimeState && runtimeState.lastPosition;
  if (!previous) {
    return false;
  }

  return haversineDistanceM(previous, point) >= minMoveDistance;
}

function toRuntimePoint(point) {
  return {
    lat: point.lat,
    lng: point.lng,
    speed: Number(point.speed || 0),
    altitude: point.altitude == null ? null : Number(point.altitude),
    ts: point.ts,
  };
}

function normalizeRuntimeState(data) {
  if (!data || typeof data !== 'object') {
    return {
      active: false,
      beginMs: null,
      lastMovementMs: null,
      lastSeenMs: null,
      distanceM: 0,
      maxSpeedKph: 0,
      tripPoints: [],
      lastPosition: null,
    };
  }

  return {
    active: data.active === true,
    beginMs: normalizeNumber(data.begin_ms),
    lastMovementMs: normalizeNumber(data.last_movement_ms),
    lastSeenMs: normalizeNumber(data.last_seen_ms),
    distanceM: normalizeNumber(data.distance_m) || 0,
    maxSpeedKph: normalizeNumber(data.max_speed_kph) || 0,
    tripPoints: Array.isArray(data.trip_points) ? data.trip_points : [],
    lastPosition: data.last_position && typeof data.last_position === 'object'
      ? {
        lat: normalizeNumber(data.last_position.lat),
        lng: normalizeNumber(data.last_position.lng),
      }
      : null,
  };
}

async function writeTripFromRuntime({ firestore, config, event, runtimeState, endMs }) {
  if (!runtimeState.beginMs || !endMs || endMs <= runtimeState.beginMs) {
    return null;
  }

  const minDistance = Number(config.tripMinDistanceM || 200);
  if ((runtimeState.distanceM || 0) < minDistance) {
    return null;
  }

  const maxTripPoints = 1200;
  const tripPoints = downsampleTripPoints(runtimeState.tripPoints || [], maxTripPoints);
  const trip = {
    beginMs: runtimeState.beginMs,
    endMs,
    distanceM: Number(runtimeState.distanceM || 0),
    maxSpeedKph: Number(runtimeState.maxSpeedKph || 0),
    polylineEncoded: null,
    tripPoints,
    tripPointsCount: (runtimeState.tripPoints || []).length,
    tripPointsSampled: (runtimeState.tripPoints || []).length > tripPoints.length,
  };

  const tripDoc = buildTripDocument(event, trip);
  const tripId = `mv_${String(event.deviceId)}_${runtimeState.beginMs}_${endMs}`;
  const tripsCollection = config.tripsCollection || 'device_trips';
  await firestore.collection(tripsCollection).doc(tripId).set(tripDoc, { merge: true });
  return tripId;
}

async function processMovementTrip({ firestore, config, event, sourceTsMs }) {
  if (!event.deviceId) {
    return null;
  }

  const raw = event.raw || {};
  const point = parsePositionPoint(raw, sourceTsMs);
  const runtimeCollection = config.tripRuntimeCollection || 'device_trip_runtime';
  const runtimeRef = firestore.collection(runtimeCollection).doc(String(event.deviceId));
  const snap = await runtimeRef.get();
  const runtime = normalizeRuntimeState(snap.exists ? (snap.data() || {}) : null);
  const moving = isMovementTelemetry(event, config, point, runtime);
  const inactivityMs = Math.max(60, Number(config.tripInactivitySec || 600)) * 1000;
  const lastMovementMs = runtime.lastMovementMs || runtime.beginMs || null;

  if (!runtime.active && !moving) {
    await runtimeRef.set({
      active: false,
      last_seen_ms: sourceTsMs,
      last_position: point ? { lat: point.lat, lng: point.lng } : runtime.lastPosition,
      updated_at: new Date().toISOString(),
    }, { merge: true });
    return null;
  }

  if (runtime.active && lastMovementMs && sourceTsMs - lastMovementMs >= inactivityMs) {
    await writeTripFromRuntime({
      firestore,
      config,
      event,
      runtimeState: runtime,
      endMs: lastMovementMs,
    });

    runtime.active = false;
    runtime.beginMs = null;
    runtime.lastMovementMs = null;
    runtime.distanceM = 0;
    runtime.maxSpeedKph = 0;
    runtime.tripPoints = [];
  }

  if (!moving) {
    await runtimeRef.set({
      active: runtime.active,
      begin_ms: runtime.beginMs,
      last_movement_ms: runtime.lastMovementMs,
      last_seen_ms: sourceTsMs,
      distance_m: runtime.distanceM,
      max_speed_kph: runtime.maxSpeedKph,
      trip_points: runtime.tripPoints,
      last_position: point ? { lat: point.lat, lng: point.lng } : runtime.lastPosition,
      updated_at: new Date().toISOString(),
    }, { merge: true });
    return null;
  }

  const nextRuntime = {
    active: true,
    beginMs: runtime.beginMs || sourceTsMs,
    lastMovementMs: sourceTsMs,
    lastSeenMs: sourceTsMs,
    distanceM: runtime.distanceM || 0,
    maxSpeedKph: Math.max(runtime.maxSpeedKph || 0, Number(point.speed || 0)),
    tripPoints: Array.isArray(runtime.tripPoints) ? [...runtime.tripPoints] : [],
    lastPosition: runtime.lastPosition,
  };

  if (nextRuntime.lastPosition && point) {
    nextRuntime.distanceM += haversineDistanceM(nextRuntime.lastPosition, point);
  }
  if (point) {
    nextRuntime.tripPoints.push(toRuntimePoint(point));
    if (nextRuntime.tripPoints.length > 1800) {
      nextRuntime.tripPoints = downsampleTripPoints(nextRuntime.tripPoints, 1200);
    }
    nextRuntime.lastPosition = { lat: point.lat, lng: point.lng };
  }

  await runtimeRef.set({
    active: true,
    begin_ms: nextRuntime.beginMs,
    last_movement_ms: nextRuntime.lastMovementMs,
    last_seen_ms: nextRuntime.lastSeenMs,
    distance_m: Number(nextRuntime.distanceM || 0),
    max_speed_kph: Number(nextRuntime.maxSpeedKph || 0),
    trip_points: nextRuntime.tripPoints,
    last_position: nextRuntime.lastPosition,
    updated_at: new Date().toISOString(),
  }, { merge: true });

  return null;
}

async function writeAlertDocument({ firestore, config, eventId, alertKind, alertDoc }) {
  const collection = firestore.collection(config.alertsCollection);

  if (eventId) {
    const docId = `${String(eventId)}:${alertKind}`;
    try {
      await collection.doc(docId).create(alertDoc);
      writeLog('info', 'alert document created', { dedupe_key: docId, event_kind: alertKind });
      return { created: true, id: docId };
    } catch (error) {
      if (error && error.code === 6) {
        writeLog('info', 'alert document deduplicated', { dedupe_key: docId, event_kind: alertKind });
        return { created: false, id: docId };
      }
      throw error;
    }
  }

  const docRef = await collection.add(alertDoc);
  writeLog('info', 'alert document created', { dedupe_key: docRef.id, event_kind: alertKind, synthetic_id: false });
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
  let effectiveClassification = classification;
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

  await processMovementTrip({
    firestore,
    config,
    event,
    sourceTsMs: snapshot.source_ts_ms,
  });

  if (effectiveClassification.geofenceTransitionAmbiguous) {
    writeLog('warn', 'ambiguous geofence transition discarded', {
      device_id: deviceIdStr,
      event_id: event.eventId || null,
      geofence_name: effectiveClassification.geofenceName || null,
      event_type: event.eventType,
    });
  }

  const recalcMaxAgeMs = Math.max(0, Number(config.geofenceMaxRecalcAgeSec || 900)) * 1000;
  const isRecalcTransition =
    effectiveClassification.geofenceAlarm &&
    Number(effectiveClassification.reasonCode) === 48;
  const isTooOldRecalc =
    isRecalcTransition &&
    recalcMaxAgeMs > 0 &&
    (Date.now() - Number(snapshot.source_ts_ms || 0)) > recalcMaxAgeMs;

  if (isTooOldRecalc) {
    writeLog('warn', 'stale recalculated geofence transition discarded', {
      device_id: deviceIdStr,
      event_id: event.eventId || null,
      reason_code: effectiveClassification.reasonCode,
      source_ts_ms: snapshot.source_ts_ms,
      max_age_ms: recalcMaxAgeMs,
    });

    effectiveClassification = {
      ...effectiveClassification,
      geofenceAlarm: false,
      geofenceEnter: false,
      geofenceExit: false,
      shouldPush: false,
    };
  }

  if (effectiveClassification.vibrationAlarm || effectiveClassification.geofenceAlarm) {
    const alertKind = effectiveClassification.vibrationAlarm
      ? 'vibration_alert'
      : (effectiveClassification.geofenceEnter
        ? 'geofence_enter'
        : 'geofence_exit');

    const persistedEventId = event.eventId || buildSyntheticAlertEventId(event, effectiveClassification, snapshot.source_ts_ms);

    const alertDocBase = {
      source_ts: snapshot.source_ts,
      device: { id: deviceIdStr, name: snapshot.device?.name || null },
      event_id: persistedEventId,
      event_kind: alertKind,
      severity: effectiveClassification.severity,
      checked: false,
      checked_at: null,
      created_at: new Date().toISOString(),
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

    const writeResult = await writeAlertDocument({
      firestore,
      config,
      eventId: persistedEventId,
      alertKind,
      alertDoc,
    });

    return {
      alertCreated: writeResult.created,
      dedupeKey: writeResult.id,
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
      payload.data.geofence_name = String(effectiveClassification.geofenceName || '');
      payload.data.geofence_enter = effectiveClassification.geofenceEnter ? 'true' : 'false';
      payload.data.geofence_exit = effectiveClassification.geofenceExit ? 'true' : 'false';
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