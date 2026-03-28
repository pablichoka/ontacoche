const http = require('node:http');

function readCrudConfig() {
  const writeBearer = (process.env.APP_WRITE_BEARER || process.env.APP_READ_BEARER || '').trim();
  const flespiToken = (process.env.FLESPI_TOKEN || '').trim();
  const calcIdRaw = (process.env.FLESPI_GEOFENCE_CALC_ID || '').trim();
  const defaultDeviceId = (process.env.DEFAULT_DEVICE_ID || '').trim();
  const baseUrl = (process.env.FLESPI_BASE_URL || 'https://flespi.io').trim().replace(/\/$/, '');

  if (!writeBearer) {
    throw new Error('missing APP_WRITE_BEARER (or APP_READ_BEARER) for geofence CRUD');
  }
  if (!flespiToken) {
    throw new Error('missing FLESPI_TOKEN for geofence CRUD');
  }
  if (!calcIdRaw) {
    throw new Error('missing FLESPI_GEOFENCE_CALC_ID for geofence CRUD');
  }

  const calcId = Number(calcIdRaw);
  if (!Number.isInteger(calcId) || calcId <= 0) {
    throw new Error('FLESPI_GEOFENCE_CALC_ID must be a positive integer');
  }

  return {
    writeBearer,
    flespiToken,
    calcId,
    defaultDeviceId: defaultDeviceId || null,
    baseUrl,
  };
}

function unauthorized(res) {
  return res.status(401).json({ ok: false, error: 'unauthorized' });
}

function validateWriteAccess(req, config) {
  const auth = req.headers.authorization || '';
  return auth === `Bearer ${config.writeBearer}`;
}

function parseJsonBody(req) {
  if (!req.body || typeof req.body !== 'object') {
    return {};
  }
  return req.body;
}

function normalizeDeviceSelector(body, config) {
  const explicitSelector = String(body.device_selector || '').trim();
  if (explicitSelector) {
    if (explicitSelector.includes('=') || explicitSelector.startsWith('{')) {
      return explicitSelector;
    }
    return explicitSelector;
  }

  const rawDeviceId = String(body.device_id || config.defaultDeviceId || '').trim();
  if (!rawDeviceId) {
    return null;
  }

  // device_id is treated as tracker ident in app-facing payloads.
  return `configuration.ident=${rawDeviceId}`;
}

function normalizeCircleGeometry(input) {
  if (!input || typeof input !== 'object') {
    throw createValidationError('geometry is required');
  }

  const type = String(input.type || '').trim().toLowerCase();
  if (type !== 'circle') {
    throw createValidationError('only circle geometry is supported in phase 1');
  }

  const center = input.center && typeof input.center === 'object' ? input.center : {};
  const lat = Number(center.lat);
  const lon = Number(center.lon);
  // input.radius is expected in KILOMETERS from the app; pass through as km
  const radiusKm = Number(input.radius);

  if (!Number.isFinite(lat) || lat < -90 || lat > 90) {
    throw createValidationError('geometry.center.lat is invalid');
  }
  if (!Number.isFinite(lon) || lon < -180 || lon > 180) {
    throw createValidationError('geometry.center.lon is invalid');
  }
  if (!Number.isFinite(radiusKm) || radiusKm < 0.001 || radiusKm > 1000) {
    throw createValidationError('geometry.radius is invalid');
  }

  return {
    type: 'circle',
    center: { lat, lon },
    // Flespi expects radius in kilometers; provide km
    radius: radiusKm,
  };
}

async function computeNextPriority(config) {
  const response = await flespiRequest(
    config,
    'GET',
    '/gw/geofences/all?fields=id,priority',
  );

  const result = Array.isArray(response.result) ? response.result : [];
  const priorities = result
    .map((r) => Number(r.priority))
    .filter((n) => Number.isFinite(n) && Number.isInteger(n) && n >= 0);
  const max = priorities.length > 0 ? Math.max(...priorities) : -1;
  const next = max + 1;
  // priorities assigned by system must be 0..99; 100 reserved for parking
  if (next >= 100) {
    const err = createValidationError('no free priority available', 409);
    throw err;
  }
  return next;
}

function normalizePolygonGeometry(input) {
  if (!input || typeof input !== 'object') {
    throw createValidationError('geometry is required');
  }

  const type = String(input.type || '').trim().toLowerCase();
  if (type !== 'polygon') {
    throw createValidationError('geometry.type must be polygon');
  }

  const rawPath = Array.isArray(input.path) ? input.path : Array.isArray(input.points) ? input.points : null;
  if (!rawPath || rawPath.length < 3) {
    throw createValidationError('polygon must have at least 3 points');
  }

  const path = rawPath.map((p) => {
    const lat = Number(p.lat);
    const lon = Number(p.lon);
    if (!Number.isFinite(lat) || lat < -90 || lat > 90) {
      throw createValidationError('geometry.path.lat is invalid');
    }
    if (!Number.isFinite(lon) || lon < -180 || lon > 180) {
      throw createValidationError('geometry.path.lon is invalid');
    }
    return { lat, lon };
  });

  return {
    type: 'polygon',
    path,
  };
}

function normalizePriority(value) {
  const priority = Number(value);
  if (!Number.isInteger(priority) || priority < 0 || priority > 100) {
    throw createValidationError('priority must be an integer between 0 and 100');
  }
  return priority;
}

function createValidationError(message, statusCode = 400) {
  const error = new Error(message);
  error.statusCode = statusCode;
  return error;
}

async function flespiRequest(config, method, path, body) {
  const url = `${config.baseUrl}${path}`;
  const payload = body == null ? undefined : JSON.stringify(body);

  const response = await fetch(url, {
    method,
    headers: {
      Authorization: `FlespiToken ${config.flespiToken}`,
      'Content-Type': 'application/json',
    },
    body: payload,
  });

  const text = await response.text();
  let parsed = null;
  if (text) {
    try {
      parsed = JSON.parse(text);
    } catch (_) {
      parsed = null;
    }
  }

  if (!response.ok) {
    const reason = parsed && Array.isArray(parsed.errors) && parsed.errors.length > 0
      ? parsed.errors.map((item) => item.reason || item.code).join('; ')
      : text || response.statusText;
    const error = new Error(`flespi request failed ${response.status}: ${reason}`);
    error.statusCode = response.status;
    error.details = parsed || text;
    throw error;
  }

  if (parsed && typeof parsed === 'object') {
    return parsed;
  }

  return { result: [] };
}

async function ensureUniquePriority(config, priority, excludeGeofenceId = null) {
  const response = await flespiRequest(
    config,
    'GET',
    '/gw/geofences/all?fields=id,priority,name',
  );

  const result = Array.isArray(response.result) ? response.result : [];
  const duplicate = result.find((item) => {
    const id = Number(item.id);
    if (excludeGeofenceId != null && id === excludeGeofenceId) {
      return false;
    }
    return Number(item.priority) === priority;
  });

  if (duplicate) {
    throw createValidationError(
      `priority ${priority} is already used by geofence ${duplicate.id} (${duplicate.name || 'unnamed'})`,
      409,
    );
  }
}

async function ensureCalcAssignment(config, geofenceId) {
  await flespiRequest(
    config,
    'POST',
    `/gw/calcs/${config.calcId}/geofences/${geofenceId}`,
  );
}

async function ensureDeviceAssignment(config, geofenceId, deviceSelector) {
  if (!deviceSelector) {
    return;
  }

  await flespiRequest(
    config,
    'POST',
    `/gw/devices/${deviceSelector}/geofences/${geofenceId}`,
  );
}

async function listDeviceGeofences(config, deviceSelector) {
  if (!deviceSelector) {
    throw createValidationError('device_id or device_selector is required');
  }

  const assignments = await flespiRequest(
    config,
    'GET',
    `/gw/devices/${deviceSelector}/geofences/all?fields=geofence_id,name`,
  );

  const ids = (Array.isArray(assignments.result) ? assignments.result : [])
    .map((item) => item.geofence_id)
    .filter((value) => Number.isInteger(value) || /^\d+$/.test(String(value)))
    .map((value) => Number(value));

  if (ids.length === 0) {
    return [];
  }

  const geofences = await flespiRequest(
    config,
    'GET',
    `/gw/geofences/${ids.join(',')}?fields=id,name,enabled,priority,geometry`,
  );

  return Array.isArray(geofences.result) ? geofences.result : [];
}

async function createCircleGeofence(config, input) {
  const name = String(input.name || '').trim();
  if (!name) {
    throw createValidationError('name is required');
  }
  let priority;
  if (input.priority != null) {
    priority = normalizePriority(input.priority);
    await ensureUniquePriority(config, priority);
  } else {
    priority = await computeNextPriority(config);
  }

  const geometry = normalizeCircleGeometry(input.geometry);
  const deviceSelector = normalizeDeviceSelector(input, config);

  const body = { name, enabled: true, geometry };
  if (priority != null) body.priority = priority;

  const created = await flespiRequest(
    config,
    'POST',
    '/gw/geofences?fields=id,name,enabled,priority,geometry',
    [body],
  );

  const geofence = Array.isArray(created.result) && created.result.length > 0
    ? created.result[0]
    : null;

  if (!geofence || !Number.isInteger(Number(geofence.id))) {
    throw new Error('flespi did not return created geofence id');
  }

  const geofenceId = Number(geofence.id);
  await ensureCalcAssignment(config, geofenceId);
  await ensureDeviceAssignment(config, geofenceId, deviceSelector);

  return {
    geofence,
    calc_id: config.calcId,
    device_selector: deviceSelector,
  };
}

async function createGeofence(config, input) {
  const name = String(input.name || '').trim();
  if (!name) {
    throw createValidationError('name is required');
  }
  let geometry;
  if (!input.geometry || typeof input.geometry !== 'object') {
    throw createValidationError('geometry is required');
  }

  const gtype = String(input.geometry.type || '').trim().toLowerCase();
  if (gtype === 'circle') {
    geometry = normalizeCircleGeometry(input.geometry);
  } else if (gtype === 'polygon') {
    geometry = normalizePolygonGeometry(input.geometry);
  } else {
    throw createValidationError('unsupported geometry type');
  }

  const deviceSelector = normalizeDeviceSelector(input, config);

  let priority;
  if (input.priority != null) {
    priority = normalizePriority(input.priority);
    await ensureUniquePriority(config, priority);
  } else {
    priority = await computeNextPriority(config);
  }

  const body = { name, enabled: true, geometry };
  if (priority != null) body.priority = priority;

  const created = await flespiRequest(
    config,
    'POST',
    '/gw/geofences?fields=id,name,enabled,priority,geometry',
    [body],
  );

  const geofence = Array.isArray(created.result) && created.result.length > 0
    ? created.result[0]
    : null;

  if (!geofence || !Number.isInteger(Number(geofence.id))) {
    throw new Error('flespi did not return created geofence id');
  }

  const geofenceId = Number(geofence.id);
  await ensureCalcAssignment(config, geofenceId);
  await ensureDeviceAssignment(config, geofenceId, deviceSelector);

  return {
    geofence,
    calc_id: config.calcId,
    device_selector: deviceSelector,
  };
}

async function updateCircleGeofence(config, geofenceId, input) {
  const id = Number(geofenceId);
  if (!Number.isInteger(id) || id <= 0) {
    throw createValidationError('invalid geofence id');
  }

  const patch = {};
  if (input.name != null) {
    const name = String(input.name || '').trim();
    if (!name) {
      throw createValidationError('name cannot be empty');
    }
    patch.name = name;
  }

  // Do not allow editing priority via this endpoint; priority is managed by the system

  if (input.geometry != null) {
    patch.geometry = normalizeCircleGeometry(input.geometry);
  }

  if (Object.keys(patch).length === 0) {
    throw createValidationError('nothing to update');
  }

  const updated = await flespiRequest(
    config,
    'PUT',
    `/gw/geofences/${id}?fields=id,name,enabled,priority,geometry`,
    patch,
  );

  await ensureCalcAssignment(config, id);

  const geofence = Array.isArray(updated.result) && updated.result.length > 0
    ? updated.result[0]
    : null;

  return {
    geofence,
    calc_id: config.calcId,
  };
}

async function updateGeofence(config, geofenceId, input) {
  const id = Number(geofenceId);
  if (!Number.isInteger(id) || id <= 0) {
    throw createValidationError('invalid geofence id');
  }

  const patch = {};
  if (input.name != null) {
    const name = String(input.name || '').trim();
    if (!name) {
      throw createValidationError('name cannot be empty');
    }
    patch.name = name;
  }

  // Do not allow editing priority via this endpoint; priority is managed by the system

  if (input.geometry != null) {
    const gtype = String(input.geometry.type || '').trim().toLowerCase();
    if (gtype === 'circle') {
      patch.geometry = normalizeCircleGeometry(input.geometry);
    } else if (gtype === 'polygon') {
      patch.geometry = normalizePolygonGeometry(input.geometry);
    } else {
      throw createValidationError('unsupported geometry type');
    }
  }

  if (Object.keys(patch).length === 0) {
    throw createValidationError('nothing to update');
  }

  const updated = await flespiRequest(
    config,
    'PUT',
    `/gw/geofences/${id}?fields=id,name,enabled,priority,geometry`,
    patch,
  );

  await ensureCalcAssignment(config, id);

  const geofence = Array.isArray(updated.result) && updated.result.length > 0
    ? updated.result[0]
    : null;

  return {
    geofence,
    calc_id: config.calcId,
  };
}

async function deleteGeofence(config, geofenceId) {
  const id = Number(geofenceId);
  if (!Number.isInteger(id) || id <= 0) {
    throw createValidationError('invalid geofence id');
  }

  await flespiRequest(config, 'DELETE', `/gw/geofences/${id}`);
  return { id };
}

async function assignGeofenceToDevice(config, geofenceId, input) {
  const id = Number(geofenceId);
  if (!Number.isInteger(id) || id <= 0) {
    throw createValidationError('invalid geofence id');
  }

  const deviceSelector = normalizeDeviceSelector(input, config);
  if (!deviceSelector) {
    throw createValidationError('device_id or device_selector is required');
  }

  await ensureCalcAssignment(config, id);
  await ensureDeviceAssignment(config, id, deviceSelector);

  return {
    geofence_id: id,
    calc_id: config.calcId,
    device_selector: deviceSelector,
  };
}

function handleApiError(res, error) {
  const statusCode = Number(error.statusCode) || 500;
  const message = error.message || http.STATUS_CODES[statusCode] || 'internal server error';

  console.error(JSON.stringify({
    level: 'error',
    message: 'geofence crud failed',
    status_code: statusCode,
    error: message,
    details: error.details || null,
    ts: new Date().toISOString(),
  }));

  return res.status(statusCode).json({
    ok: false,
    error: message,
    details: error.details || null,
  });
}

module.exports = {
  assignGeofenceToDevice,
  createCircleGeofence,
  createGeofence,
  deleteGeofence,
  handleApiError,
  listDeviceGeofences,
  parseJsonBody,
  readCrudConfig,
  unauthorized,
  updateCircleGeofence,
  updateGeofence,
  validateWriteAccess,
};
