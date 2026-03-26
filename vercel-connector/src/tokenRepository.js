const TOKEN_INVALID_ERRORS = new Set([
  'messaging/invalid-registration-token',
  'messaging/registration-token-not-registered',
]);

async function getActiveTokens({ firestore, collectionName, deviceId, userId }) {
  const tokenMap = new Map();

  if (deviceId) {
    const byDeviceSnapshot = await firestore
      .collection(collectionName)
      .where('device_id', '==', String(deviceId))
      .where('active', '==', true)
      .get();

    byDeviceSnapshot.forEach((doc) => {
      const data = doc.data();
      const token = data.token || doc.id;
      if (token) {
        tokenMap.set(token, doc.ref);
      }
    });

    const numericDeviceId = Number.parseInt(String(deviceId), 10);
    if (Number.isFinite(numericDeviceId)) {
      const byNumericDeviceSnapshot = await firestore
        .collection(collectionName)
        .where('device_id', '==', numericDeviceId)
        .where('active', '==', true)
        .get();

      byNumericDeviceSnapshot.forEach((doc) => {
        const data = doc.data();
        const token = data.token || doc.id;
        if (token) {
          tokenMap.set(token, doc.ref);
        }
      });
    }
  }

  if (userId) {
    const byUserSnapshot = await firestore
      .collection(collectionName)
      .where('user_id', '==', String(userId))
      .where('active', '==', true)
      .get();

    byUserSnapshot.forEach((doc) => {
      const data = doc.data();
      const token = data.token || doc.id;
      if (token) {
        tokenMap.set(token, doc.ref);
      }
    });
  }

  return tokenMap;
}

async function deactivateInvalidTokens({ tokenRefsByValue, multicastResponse, tokens }) {
  const updates = [];

  multicastResponse.responses.forEach((response, index) => {
    if (response.success) {
      return;
    }

    const code = response.error && response.error.code;
    if (!TOKEN_INVALID_ERRORS.has(code)) {
      return;
    }

    const token = tokens[index];
    const tokenRef = tokenRefsByValue.get(token);
    if (!tokenRef) {
      return;
    }

    updates.push(
      tokenRef.update({
        active: false,
        last_error_code: code,
        updated_at: new Date().toISOString(),
      }),
    );
  });

  await Promise.all(updates);

  return updates.length;
}

module.exports = {
  deactivateInvalidTokens,
  getActiveTokens,
};
