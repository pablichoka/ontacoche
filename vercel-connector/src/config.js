const REQUIRED_ENV_VARS = [
  'WEBHOOK_BEARER_SECRET',
  'FIREBASE_PROJECT_ID',
  'FIREBASE_CLIENT_EMAIL',
  'FIREBASE_PRIVATE_KEY',
];

function envAsBoolean(value, fallback) {
  if (value == null) {
    return fallback;
  }

  const normalized = String(value).trim().toLowerCase();
  if (normalized === 'true' || normalized === '1' || normalized === 'yes') {
    return true;
  }
  if (normalized === 'false' || normalized === '0' || normalized === 'no') {
    return false;
  }

  return fallback;
}

function envAsNumberList(value, fallback) {
  if (value == null || String(value).trim() === '') {
    return fallback;
  }

  const parsed = String(value)
    .split(',')
    .map((item) => Number(item.trim()))
    .filter((item) => Number.isFinite(item));

  return parsed.length > 0 ? parsed : fallback;
}

function readConfig() {
  const missing = REQUIRED_ENV_VARS.filter((key) => !process.env[key]);
  if (missing.length > 0) {
    throw new Error(`missing required env vars: ${missing.join(', ')}`);
  }

  const normalizedPrivateKey = process.env.FIREBASE_PRIVATE_KEY
    .trim()
    .replace(/^"|"$/g, '')
    .replace(/^'|'$/g, '')
    .replace(/\\n/g, '\n');

  return {
    webhookBearerSecret: process.env.WEBHOOK_BEARER_SECRET,
    firebaseProjectId: process.env.FIREBASE_PROJECT_ID,
    firebaseClientEmail: process.env.FIREBASE_CLIENT_EMAIL,
    firebasePrivateKey: normalizedPrivateKey,
    defaultDeviceId: (process.env.DEFAULT_DEVICE_ID || '').trim() || null,
    logLevel: process.env.LOG_LEVEL || 'info',
    tokenCollection: process.env.FCM_TOKEN_COLLECTION || 'fcm_tokens',
    deviceStateCollection: process.env.DEVICE_STATE_COLLECTION || 'device_last_state',
    stateHistoryCollection: process.env.STATE_HISTORY_COLLECTION || 'device_state_history',
    alertsCollection: process.env.ALERTS_COLLECTION || 'device_alerts',
    storeStateHistory: envAsBoolean(process.env.STORE_STATE_HISTORY, true),
    pushOnCommunicationActive: envAsBoolean(process.env.PUSH_ON_COMMUNICATION_ACTIVE, false),
    tripsCollection: process.env.TRIPS_COLLECTION || 'device_trips',
    tripRuntimeCollection: process.env.TRIP_RUNTIME_COLLECTION || 'device_trip_runtime',
    tripInactivitySec: Number(process.env.TRIP_INACTIVITY_SEC || 600),
    tripMinDistanceM: Number(process.env.TRIP_MIN_DISTANCE_M || 200),
    tripMinSpeedKph: Number(process.env.TRIP_MIN_SPEED_KPH || 8),
    tripMinMoveDistanceM: Number(process.env.TRIP_MIN_MOVE_DISTANCE_M || 50),
    geofenceAllowedReasonCodes: envAsNumberList(process.env.GEOFENCE_ALLOWED_REASON_CODES, [20, 2, 48]),
    geofenceMaxRecalcAgeSec: Number(process.env.GEOFENCE_MAX_RECALC_AGE_SEC || 0),
    timezone: process.env.TIMEZONE || 'Europe/Madrid',
    deviceConfigCollection: process.env.DEVICE_CONFIG_COLLECTION || 'device_config_state',
    geofenceConfigChangeSuppressSec: Number(process.env.GEOFENCE_CONFIG_CHANGE_SUPPRESS_SEC || 90),
    pushOnGeofenceConfigChange: envAsBoolean(process.env.PUSH_ON_GEOFENCE_CONFIG_CHANGE, true),
    flespiToken: process.env.FLESPI_TOKEN || null,
    flespiCalcId: process.env.FLESPI_GEOFENCE_CALC_ID || null,
    flespiBaseUrl: process.env.FLESPI_BASE_URL || 'https://flespi.io',
  };
}

module.exports = {
  readConfig,
};
