const REQUIRED_ENV_VARS = [
  'WEBHOOK_BEARER_SECRET',
  'FIREBASE_PROJECT_ID',
  'FIREBASE_CLIENT_EMAIL',
  'FIREBASE_PRIVATE_KEY',
];

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
    logLevel: process.env.LOG_LEVEL || 'info',
    tokenCollection: process.env.FCM_TOKEN_COLLECTION || 'fcm_tokens',
  };
}

module.exports = {
  readConfig,
};
