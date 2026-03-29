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
    shouldPush: shouldPush || geofenceConfigChange,
    title,
    body,
    severity,
  };
}

function buildStateSnapshot(event, classification, config) {
  const raw = event.raw || {};
  // Extraemos el end / begin nativo del intervalo para no usar la hora del recálculo de flespi
  const sourceTsMs =
    parseTimestampToMs(firstDefined(raw, ['end', 'begin', 'server.timestamp', 'timestamp'])) ||
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
  const deviceIdStr = String(event.deviceId);
  const stateRef = firestore.collection(config.deviceStateCollection).doc(deviceIdStr);

  const snapshot = buildStateSnapshot(event, classification, config);
  const writeSnapshot = { ...snapshot };
  delete writeSnapshot.source_ts_ms;
  delete writeSnapshot.updated_at;

  // Actualizar ultimo estado conocido siempre
  await stateRef.set(writeSnapshot);

  // TAREA 1: FILTRADO ESTRICTO DE HISTORIAL (Evitar tramas basura)
  const isPeriodicPos = event.reportCode === '0200';
  const hasValidGPS = snapshot.position.latitude != null && snapshot.position.longitude != null;

  if (config.storeStateHistory && isPeriodicPos && hasValidGPS) {
    await firestore.collection(config.stateHistoryCollection).add(writeSnapshot);

    // TAREA 2: MOTOR DE ESTADO DE TRIPS
    try {
      const tripsColl = firestore.collection(config.tripsCollection || 'trips');

      // Paso 2.1: Buscar Trip Activo
      const activeTripQuery = await tripsColl
        .where('device_id', '==', deviceIdStr)
        .where('status', '==', 'in_progress')
        .limit(1)
        .get();

      if (activeTripQuery.empty) {
        // Paso 2.2: Lógica si NO hay Trip Activo (Evaluación de Inicio)
        const historyQuery = await firestore.collection(config.stateHistoryCollection)
          .where('device.id', '==', deviceIdStr)
          .orderBy('source_ts', 'desc')
          .limit(6)
          .get();

        if (historyQuery.size === 6) {
          const points = historyQuery.docs.map(doc => doc.data()).reverse(); // Orden cronologico
          const latestPoint = points[points.length - 1];
          const oldestPoint = points[0];

          // Requisito 6 puntos en 5 mins
          const latestTs = new Date(latestPoint.source_ts).getTime();
          const oldestTs = new Date(oldestPoint.source_ts).getTime();

          // CORRECCIÓN: Validar que existe movimiento real en estos 6 puntos
          const hasMovement = points.some(p => (p.position?.speed || 0) >= 1);

          if (latestTs - oldestTs <= 300000 && hasMovement) {
            await tripsColl.add({
              device_id: deviceIdStr,
              status: 'in_progress',
              start_ts: oldestPoint.source_ts,
              end_ts: null,
              points: points
            });
          }
        }
      } else {
        // Paso 2.3: Lógica si SÍ hay un Trip Activo (Actualización y Evaluación de Cierre)
        const tripDoc = activeTripQuery.docs[0];
        const tripData = tripDoc.data();
        const updatedPoints = [...(tripData.points || []), writeSnapshot];

        // Evaluar condición de cierre (Parada detectada)
        if (updatedPoints.length >= 4) {
          const last4 = updatedPoints.slice(-4);
          const isStopped = last4.every(p => (p.position?.speed || 0) < 1);

          if (isStopped) {
            const finalPoints = updatedPoints.slice(0, -4);
            
            // CORRECCIÓN: Si el viaje resultante es demasiado corto o un falso positivo, borrarlo
            if (finalPoints.length < 5) {
              await tripDoc.ref.delete();
            } else {
              const endTs = finalPoints[finalPoints.length - 1].source_ts;
              await tripDoc.ref.update({
                status: 'completed',
                end_ts: endTs,
                points: finalPoints
              });
            }
          } else {
            // Actualizar añadiendo el nuevo punto si no hay parada
            await tripDoc.ref.update({
              points: admin.firestore.FieldValue.arrayUnion(writeSnapshot)
            });
          }
        } else {
          await tripDoc.ref.update({
            points: admin.firestore.FieldValue.arrayUnion(writeSnapshot)
          });
        }
      }
    } catch (tripError) {
      writeLog('error', 'Error en motor de trips', { 
        deviceId: deviceIdStr, 
        error: tripError.message 
      });
      // Continuamos para no bloquear alertas
    }
  } else if (config.storeStateHistory && (!isPeriodicPos || !hasValidGPS)) {
    // Si no es valido para historial, abortamos evaluacion de trips pero permitimos alertas
    // No hacemos nada aqui, solo evitamos el bloque anterior
  }

  // LOGICA DE ALERTAS Y GEOCERCAS (Se mantiene intacta)
  if (classification.vibrationAlarm || classification.geofenceAlarm) {
    const dedupeBucket = classification.vibrationAlarm
      ? Math.floor(snapshot.source_ts_ms / (VIBRATION_DEDUPE_WINDOW_SECONDS * 1000))
      : Math.floor(snapshot.source_ts_ms / (GEOFENCE_DEDUPE_WINDOW_SECONDS * 1000));

    const alertKind = classification.vibrationAlarm
      ? 'vibration_alert'
      : (classification.geofenceEnter
        ? 'geofence_enter'
        : (classification.geofenceExit ? 'geofence_exit' : 'geofence_alert'));

    const geofenceIntervalId =
      classification.geofenceAlarm && event.eventId != null
        ? String(event.eventId)
        : null;

    const geofenceTopic = String(firstDefined(raw, ['topic', 'event.topic']) || '').toLowerCase();
    const geofenceIntervalEnd = firstDefined(raw, ['end', 'interval.end']);

    const dedupeKey = geofenceIntervalId
      ? makeStableId([
        'gf',
        deviceIdStr,
        geofenceIntervalId,
        alertKind,
        classification.geofenceName || '',
        geofenceTopic.includes('/updated') && geofenceIntervalEnd != null
          ? String(geofenceIntervalEnd)
          : '',
      ].join('|'))
      : makeStableId([
        deviceIdStr,
        alertKind,
        classification.geofenceName || '',
        String(dedupeBucket),
      ].join('|'));
      
    const alertRef = firestore.collection(config.alertsCollection).doc(dedupeKey);
    const existing = await alertRef.get();

    if (existing.exists) {
      writeLog('info', 'Ignorando alerta duplicada/recalculada', { dedupeKey, event_id: event.eventId });
      return {
        alertCreated: false,
        dedupeKey,
        eventKind: alertKind,
        classification,
      };
    }

    const alertDocBase = {
      source_ts: snapshot.source_ts,
      device: { id: deviceIdStr, name: snapshot.device?.name || null },
      dedupe_key: dedupeKey,
      event_id: event.eventId || null,
      event_kind: alertKind,
      severity: classification.severity,
      checked: false, 
      checked_at: null,
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

    await alertRef.set(alertDoc, { merge: true });
    
    try {
      await alertRef.update({
        source_ts_ms: admin.firestore.FieldValue.delete(),
        created_at: admin.firestore.FieldValue.delete(),
        last_seen_at: admin.firestore.FieldValue.delete(),
      });
    } catch (e) {
    }

    return {
      alertCreated: true, 
      dedupeKey,
      eventKind: alertKind,
      classification,
    };
  }

  if (classification.geofenceConfigChange) {
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
      message: classification.body,
      severity: classification.severity,
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