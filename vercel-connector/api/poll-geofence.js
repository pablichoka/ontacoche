const { readConfig } = require('../src/config');
const { getFirestore } = require('../src/firebaseAdmin');

function makeStableId(input) {
  let hash = 0;
  for (let i = 0; i < input.length; i += 1) {
    hash = ((hash << 5) - hash) + input.charCodeAt(i);
    hash |= 0;
  }

  return `k${Math.abs(hash).toString(36)}`;
}

function asIsoFromSeconds(value) {
  if (value == null) {
    return new Date().toISOString();
  }

  return new Date(Number(value) * 1000).toISOString();
}

async function fetchJson(url, token) {
  const response = await fetch(url, {
    method: 'GET',
    headers: {
      Authorization: `FlespiToken ${token}`,
    },
  });

  if (!response.ok) {
    throw new Error(`flespi request failed (${response.status}) for ${url}`);
  }

  return response.json();
}

async function listAssignedDevices(config) {
  const url = `https://flespi.io/gw/calcs/${config.geofenceCalcId}/devices/all?fields=device_id`;
  const payload = await fetchJson(url, config.flespiToken);
  const result = Array.isArray(payload?.result) ? payload.result : [];

  return result
    .map((item) => Number.parseInt(String(item.device_id || ''), 10))
    .filter((value) => Number.isInteger(value) && value > 0);
}

async function fetchLastInterval(config, deviceId) {
  const url = new URL(
    `https://flespi.io/gw/calcs/${config.geofenceCalcId}/devices/${deviceId}/intervals/last`,
  );
  url.searchParams.set('data', JSON.stringify({
    fields: 'id,type,geofence,begin,end,timestamp',
  }));

  const payload = await fetchJson(url.toString(), config.flespiToken);
  const interval = Array.isArray(payload?.result) ? payload.result[0] : null;
  if (!interval || interval.id == null) {
    return null;
  }

  const type = String(interval.type || '').toLowerCase();
  if (type !== 'enter' && type !== 'exit' && type !== 'activated' && type !== 'deactivated') {
    return null;
  }

  return {
    id: String(interval.id),
    type,
    geofence: interval.geofence == null ? null : String(interval.geofence),
    begin: interval.begin ?? null,
    end: interval.end ?? null,
    timestamp: interval.timestamp ?? null,
  };
}

function authOk(req, config) {
  if (!config.pollGeofenceBearer) {
    return true;
  }

  const authHeader = req.headers.authorization || '';
  return authHeader === `Bearer ${config.pollGeofenceBearer}`;
}

module.exports = async function handler(req, res) {
  if (req.method !== 'POST') {
    return res.status(405).json({ ok: false, error: 'method not allowed' });
  }

  let config;
  try {
    config = readConfig();
  } catch (error) {
    return res.status(500).json({ ok: false, error: error.message });
  }

  if (!authOk(req, config)) {
    return res.status(401).json({ ok: false, error: 'unauthorized' });
  }

  if (!config.flespiToken || !config.geofenceCalcId) {
    return res.status(400).json({
      ok: false,
      error: 'FLESPI_TOKEN and GEOFENCE_CALC_ID are required',
    });
  }

  try {
    const firestore = getFirestore(config);
    const deviceIds = await listAssignedDevices(config);
    let created = 0;

    for (const deviceId of deviceIds) {
      const last = await fetchLastInterval(config, deviceId);
      if (!last) {
        continue;
      }

      const stateRef = firestore.collection(config.deviceStateCollection).doc(String(deviceId));
      const stateSnap = await stateRef.get();
      const state = stateSnap.exists ? (stateSnap.data() || {}) : {};
      if (String(state.last_calc_interval_id || '') === last.id) {
        continue;
      }

      const isEnter = last.type === 'enter' || last.type === 'activated';
      const eventKind = isEnter ? 'geofence_enter' : 'geofence_exit';
      const geofenceName = last.geofence || 'Geofence';
      const sourceTs = asIsoFromSeconds(last.end || last.begin || last.timestamp);
      const dedupeSource = `${deviceId}|${eventKind}|${geofenceName}|${last.id}`;
      const dedupeKey = makeStableId(dedupeSource);

      const alertRef = firestore.collection(config.alertsCollection).doc(dedupeKey);
      await alertRef.set({
        device_id: String(deviceId),
        event_kind: eventKind,
        geofence_name: geofenceName,
        geofence_enter: isEnter,
        geofence_exit: !isEnter,
        geofence_alarm: true,
        message: isEnter
          ? `Entrada en geocerca: ${geofenceName}`
          : `Salida de geocerca: ${geofenceName}`,
        severity: 'high',
        checked: false,
        dedupe_key: dedupeKey,
        source_ts: sourceTs,
        source_ts_ms: Date.parse(sourceTs),
        created_at: new Date().toISOString(),
        last_seen_at: new Date().toISOString(),
      }, { merge: true });

      await stateRef.set({
        last_calc_interval_id: last.id,
        last_calc_interval_type: last.type,
        last_calc_geofence: geofenceName,
        source_ts: sourceTs,
        updated_at: new Date().toISOString(),
      }, { merge: true });

      created += 1;
    }

    return res.status(200).json({
      ok: true,
      devices_checked: deviceIds.length,
      alerts_created: created,
    });
  } catch (error) {
    return res.status(500).json({ ok: false, error: error.message });
  }
};
