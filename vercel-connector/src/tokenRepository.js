const TOKEN_INVALID_ERRORS = new Set([
  'messaging/invalid-registration-token',
  'messaging/registration-token-not-registered',
]);

async function getActiveTokens({ firestore, collectionName, deviceId, userId }) {
  const tokenMap = new Map();
  const collection = firestore.collection(collectionName);

  async function safeQuery(buildQuery, label) {
    try {
      return await buildQuery().get();
    } catch (error) {
      console.error(JSON.stringify({
        level: 'warn',
        message: 'token query failed',
        query: label,
        error: error.message,
        code: error.code || null,
        ts: new Date().toISOString(),
      }));
      return null;
    }
  }

  if (deviceId) {
    const byDeviceSnapshot = await safeQuery(
      () => collection
        .where('device_id', '==', String(deviceId))
        .where('active', '==', true),
      'device_id:string+active',
    );

    if (byDeviceSnapshot) {
      byDeviceSnapshot.forEach((doc) => {
        const data = doc.data();
        const token = data.token || doc.id;
        if (token) {
          tokenMap.set(token, doc.ref);
        }
      });
    }

    const numericDeviceId = Number.parseInt(String(deviceId), 10);
    if (Number.isFinite(numericDeviceId)) {
      const byNumericDeviceSnapshot = await safeQuery(
        () => collection
          .where('device_id', '==', numericDeviceId)
          .where('active', '==', true),
        'device_id:number+active',
      );

      if (byNumericDeviceSnapshot) {
        byNumericDeviceSnapshot.forEach((doc) => {
          const data = doc.data();
          const token = data.token || doc.id;
          if (token) {
            tokenMap.set(token, doc.ref);
          }
        });
      }
    }
  }

  if (userId) {
    const byUserSnapshot = await safeQuery(
      () => collection
        .where('user_id', '==', String(userId))
        .where('active', '==', true),
      'user_id+active',
    );

    if (byUserSnapshot) {
      byUserSnapshot.forEach((doc) => {
        const data = doc.data();
        const token = data.token || doc.id;
        if (token) {
          tokenMap.set(token, doc.ref);
        }
      });
    }
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
  
