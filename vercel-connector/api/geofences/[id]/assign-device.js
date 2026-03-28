require('../../../src/compat-url');
const {
  assignGeofenceToDevice,
  handleApiError,
  parseJsonBody,
  readCrudConfig,
  unauthorized,
  validateWriteAccess,
} = require('../../../src/geofenceCrudService');

module.exports = async function handler(req, res) {
  if (req.method !== 'POST') {
    return res.status(405).json({ ok: false, error: 'method not allowed' });
  }

  let config;
  try {
    config = readCrudConfig();
  } catch (error) {
    return res.status(500).json({ ok: false, error: error.message });
  }

  if (!validateWriteAccess(req, config)) {
    return unauthorized(res);
  }

  const geofenceId = String(req.query.id || '').trim();
  if (!geofenceId) {
    return res.status(400).json({ ok: false, error: 'geofence id is required' });
  }

  try {
    const body = parseJsonBody(req);
    const result = await assignGeofenceToDevice(config, geofenceId, body);
    return res.status(200).json({ ok: true, ...result });
  } catch (error) {
    return handleApiError(res, error);
  }
};
