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
