require('../../src/compat-url');
const {
  deleteGeofence,
  handleApiError,
  parseJsonBody,
  readCrudConfig,
  unauthorized,
  updateGeofence,
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

  const geofenceId = String(req.query.id || '').trim();
  if (!geofenceId) {
    return res.status(400).json({ ok: false, error: 'geofence id is required' });
  }

  try {
    if (req.method === 'PATCH' || req.method === 'PUT') {
      const body = parseJsonBody(req);
      const updated = await updateGeofence(config, geofenceId, body);
      return res.status(200).json({ ok: true, ...updated });
    }

    if (req.method === 'DELETE') {
      const deleted = await deleteGeofence(config, geofenceId);
      return res.status(200).json({ ok: true, ...deleted });
    }

    return res.status(405).json({ ok: false, error: 'method not allowed' });
  } catch (error) {
    return handleApiError(res, error);
  }
};
