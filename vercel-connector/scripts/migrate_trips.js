/*
  Rebuild `device_trips` from raw points in `device_state_history`.

  Usage:
    FIREBASE_PROJECT_ID=... FIREBASE_CLIENT_EMAIL=... FIREBASE_PRIVATE_KEY="..." \
    STATE_HISTORY_COLLECTION=device_state_history TRIPS_COLLECTION=device_trips \
    DRY_RUN=true PAGE_SIZE=500 BATCH_SIZE=400 \
    node scripts/migrate_trips.js

  Notes:
  - Reads points ordered by `source_ts_ms`, `__name__`.
  - Splits trips when gap between points is > 6 minutes.
  - Filters points by valid position + battery, and accepts the history shape written by the webhook.
*/

const admin = require('firebase-admin');
const { readConfig } = require('../src/config');

const GAP_MS = 360000;
const DEFAULT_PAGE_SIZE = 500;
const DEFAULT_BATCH_SIZE = 400;

function getPrivateKey() {
  const raw = process.env.FIREBASE_PRIVATE_KEY;
  if (!raw) return null;
  return raw.trim().replace(/^"|"$/g, '').replace(/^'|'$/g, '').replace(/\\n/g, '\n');
}

function toNumber(value) {
  if (value == null || value === '') return null;
  const num = Number(value);
  return Number.isFinite(num) ? num : null;
}

function normalizeReportCode(value) {
  if (value == null || value === '') return null;
  const raw = String(value).trim();
  if (/^\d+$/.test(raw)) return raw.padStart(4, '0');
  return raw;
}

function buildPoint(docData) {
  const lat = toNumber((docData.position && docData.position.latitude) ?? docData.latitude);
  const lng = toNumber((docData.position && docData.position.longitude) ?? docData.longitude);
  const speed = toNumber((docData.position && docData.position.speed) ?? docData.speed) || 0;
  const sourceTsMs =
    toNumber(docData.source_ts_ms) ??
    toNumber(Date.parse(docData.source_ts)) ??
    toNumber(Date.parse(docData.updated_at)) ??
    toNumber(docData.timestamp);
  const batteryLevel = toNumber((docData.battery && docData.battery.level) ?? docData.battery_level);
  const reportCode = normalizeReportCode(
    (docData.report && docData.report.code) ?? docData.report_code,
  );

  const isValid =
    sourceTsMs != null &&
    lat != null &&
    lng != null &&
    batteryLevel != null &&
    (reportCode == null || reportCode === '0200');

  if (!isValid) return null;

  return {
    lat,
    lng,
    speed,
    sourceTsMs,
  };
}

function haversineMeters(lat1, lon1, lat2, lon2) {
  const r = 6371000;
  const toRad = (deg) => deg * Math.PI / 180;
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) *
    Math.sin(dLon / 2) * Math.sin(dLon / 2);
  return r * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

function encodeSignedValue(value) {
  let sgnNum = value < 0 ? ~(value << 1) : (value << 1);
  let encoded = '';
  while (sgnNum >= 0x20) {
    encoded += String.fromCharCode((0x20 | (sgnNum & 0x1f)) + 63);
    sgnNum >>= 5;
  }
  encoded += String.fromCharCode(sgnNum + 63);
  return encoded;
}

function encodePolyline(points) {
  let result = '';
  let prevLat = 0;
  let prevLng = 0;

  for (const point of points) {
    const lat = Math.round(point.lat * 1e5);
    const lng = Math.round(point.lng * 1e5);
    result += encodeSignedValue(lat - prevLat);
    result += encodeSignedValue(lng - prevLng);
    prevLat = lat;
    prevLng = lng;
  }

  return result;
}

function buildTripDoc(deviceId, points) {
  if (points.length < 2) return null;

  let distanceM = 0;
  let maxSpeedKph = 0;

  for (let i = 1; i < points.length; i += 1) {
    const prev = points[i - 1];
    const curr = points[i];
    distanceM += haversineMeters(prev.lat, prev.lng, curr.lat, curr.lng);
    if (curr.speed > maxSpeedKph) {
      maxSpeedKph = curr.speed;
    }
  }

  const startedAtMs = points[0].sourceTsMs;
  const endedAtMs = points[points.length - 1].sourceTsMs;

  return {
    deviceId,
    startedAt: new Date(startedAtMs).toISOString(),
    endedAt: new Date(endedAtMs).toISOString(),
    durationSec: Math.max(0, Math.floor((endedAtMs - startedAtMs) / 1000)),
    distanceM: Number(distanceM.toFixed(1)),
    maxSpeedKph: Number(maxSpeedKph.toFixed(1)),
    polylineEncoded: encodePolyline(points),
    source: 'migration_script',
    createdAt: new Date().toISOString(),
  };
}

function makeTripId(deviceId, startIso, endIso) {
  return `${deviceId}_${startIso.replace(/[:.]/g, '-')}_${endIso.replace(/[:.]/g, '-')}`;
}

async function commitBatchIfNeeded({ firestore, writes, dryRun }) {
  if (writes.length === 0) return 0;
  if (dryRun) {
    writes.length = 0;
    return 0;
  }

  let batch = firestore.batch();
  let ops = 0;
  let committed = 0;

  for (const item of writes) {
    batch.set(item.ref, item.data, { merge: true });
    ops += 1;
    if (ops >= DEFAULT_BATCH_SIZE) {
      await batch.commit();
      committed += ops;
      batch = firestore.batch();
      ops = 0;
    }
  }

  if (ops > 0) {
    await batch.commit();
    committed += ops;
  }

  writes.length = 0;
  return committed;
}

async function main() {
  const config = readConfig();
  const projectId = config.firebaseProjectId;
  const clientEmail = config.firebaseClientEmail;
  const privateKey = getPrivateKey();

  if (!projectId || !clientEmail || !privateKey) {
    console.error('missing firebase credentials in env');
    process.exit(1);
  }

  const pageSize = Math.max(50, Number(process.env.PAGE_SIZE || DEFAULT_PAGE_SIZE));
  const dryRun = String(process.env.DRY_RUN || 'true').toLowerCase() !== 'false';

  const app = admin.initializeApp({
    credential: admin.credential.cert({ projectId, clientEmail, privateKey }),
  }, 'migrate-trips');

  const firestore = app.firestore();
  const historyCol = firestore.collection(config.stateHistoryCollection || 'device_state_history');
  const tripsCol = firestore.collection(config.tripsCollection || 'device_trips');

  let lastDoc = null;
  let scanned = 0;
  let accepted = 0;
  let tripsPrepared = 0;
  let writesCommitted = 0;
  const writes = [];

  const activeTrips = new Map();

  const flushTripForDevice = (deviceId) => {
    const state = activeTrips.get(deviceId);
    if (!state || state.points.length < 2) {
      activeTrips.delete(deviceId);
      return;
    }

    const tripDoc = buildTripDoc(deviceId, state.points);
    activeTrips.delete(deviceId);
    if (!tripDoc) return;

    const tripId = makeTripId(deviceId, tripDoc.startedAt, tripDoc.endedAt);
    writes.push({ ref: tripsCol.doc(tripId), data: tripDoc });
    tripsPrepared += 1;
  };

  console.log(`starting trip migration. dry_run=${dryRun} page_size=${pageSize}`);

  while (true) {
    let query = historyCol
      .orderBy('source_ts', 'asc')
      .orderBy('__name__', 'asc')
      .limit(pageSize);

    if (lastDoc) {
      query = query.startAfter(lastDoc);
    }

    const snap = await query.get();
    if (snap.empty) break;

    for (const doc of snap.docs) {
      scanned += 1;
      const data = doc.data();
      const deviceId = String((data.device && data.device.id) || '').trim();
      if (!deviceId) continue;

      const point = buildPoint(data);
      if (!point) continue;
      accepted += 1;

      const state = activeTrips.get(deviceId);
      if (!state) {
        activeTrips.set(deviceId, { points: [point] });
      } else {
        const prev = state.points[state.points.length - 1];
        if ((point.sourceTsMs - prev.sourceTsMs) > GAP_MS) {
          flushTripForDevice(deviceId);
          activeTrips.set(deviceId, { points: [point] });
        } else {
          state.points.push(point);
        }
      }

      if (writes.length >= DEFAULT_BATCH_SIZE) {
        writesCommitted += await commitBatchIfNeeded({ firestore, writes, dryRun });
      }
    }

    lastDoc = snap.docs[snap.docs.length - 1];

    if (scanned % 5000 === 0) {
      console.log(`progress scanned=${scanned} accepted=${accepted} trips_prepared=${tripsPrepared}`);
    }

    if (snap.size < pageSize) break;
  }

  for (const deviceId of Array.from(activeTrips.keys())) {
    flushTripForDevice(deviceId);
  }
  writesCommitted += await commitBatchIfNeeded({ firestore, writes, dryRun });

  console.log('migration finished', {
    scanned,
    accepted,
    tripsPrepared,
    writesCommitted,
    dryRun,
  });

  process.exit(0);
}

main().catch((error) => {
  console.error('migration failed', error);
  process.exit(1);
});
