const {
  createGeofence,
  handleApiError,
  listDeviceGeofences,
  parseJsonBody,
  readCrudConfig,
  unauthorized,
  validateWriteAccess,
} = require('../../src/geofenceCrudService');

module.exports = async function handler(req, res) {
  let config;
  try {
    config = readCrudConfig();
  } catch (error) {
    return res.status(500).json({ ok: false, error: error.message });
  }

  if (!validateWriteAccess(req, config)) {
    return unauthorized(res);
  }

  try {
    if (req.method === 'GET') {
      const deviceSelector = String(req.query.device_selector || '').trim();
      const deviceId = String(req.query.device_id || config.defaultDeviceId || '').trim();
      const selector = deviceSelector || (deviceId ? `configuration.ident=${deviceId}` : '');
      const geofences = await listDeviceGeofences(config, selector);
      return res.status(200).json({
        ok: true,
        device_selector: selector,
        geofences,
      });
    }

    if (req.method === 'POST') {
      const body = parseJsonBody(req);
      const created = await createGeofence(config, body);
      return res.status(201).json({ ok: true, ...created });
    }

    return res.status(405).json({ ok: false, error: 'method not allowed' });
  } catch (error) {
    return handleApiError(res, error);
  }
};
