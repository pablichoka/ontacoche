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

  return {
    webhookBearerSecret: process.env.WEBHOOK_BEARER_SECRET,
    firebaseProjectId: process.env.FIREBASE_PROJECT_ID,
    firebaseClientEmail: process.env.FIREBASE_CLIENT_EMAIL,
    firebasePrivateKey: process.env.FIREBASE_PRIVATE_KEY.replace(/\\n/g, '\n'),
    logLevel: process.env.LOG_LEVEL || 'info',
    tokenCollection: process.env.FCM_TOKEN_COLLECTION || 'fcm_tokens',
  };
}

module.exports = {
  readConfig,
};
