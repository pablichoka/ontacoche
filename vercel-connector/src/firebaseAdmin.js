const admin = require('firebase-admin');

let app;

function getFirebaseApp(config) {
  if (!app) {
    app = admin.initializeApp({
      credential: admin.credential.cert({
        projectId: config.firebaseProjectId,
        clientEmail: config.firebaseClientEmail,
        privateKey: config.firebasePrivateKey,
      }),
    });
  }

  return app;
}

function getFirestore(config) {
  return getFirebaseApp(config).firestore();
}

function getMessaging(config) {
  return getFirebaseApp(config).messaging();
}

module.exports = {
  getFirestore,
  getMessaging,
};
