require('../src/compat-url');

function maybeAuthorize(req) {
  const expectedBearer = (process.env.VERCEL_CONNECTOR_WRITE_BEARER || process.env.APP_WRITE_BEARER || '').trim();
  if (!expectedBearer) {
    return true;
  }

  const auth = req.headers.authorization || '';
  return auth === `Bearer ${expectedBearer}`;
}

module.exports = async function handler(req, res) {
  if (req.method !== 'POST') {
    return res.status(405).json({ ok: false, error: 'method not allowed' });
  }

  if (!maybeAuthorize(req)) {
    return res.status(401).json({ ok: false, error: 'unauthorized' });
  }

  const flespiToken = (process.env.FLESPI_TOKEN || '').trim();
  if (!flespiToken) {
    return res.status(500).json({ ok: false, error: 'flespi token not configured in backend' });
  }

  const body = req.body || {};
  const selector = body.selector;
  if (!selector) {
    return res.status(400).json({ ok: false, error: 'selector is required' });
  }

  const {
    name,
    properties,
    queue,
    timeout,
    ttl,
    priority,
    maxAttempts,
    condition
  } = body;

  if (!name || !properties) {
    return res.status(400).json({ ok: false, error: 'name and properties are required' });
  }

  const endpoint = queue ? 'commands-queue' : 'commands';
  const url = `https://flespi.io/gw/devices/${encodeURIComponent(selector)}/${endpoint}`;

  const flespiBody = [{
    name,
    properties,
    ...(timeout != null && { timeout }),
    ...(ttl != null && { ttl }),
    ...(priority != null && { priority }),
    ...(maxAttempts != null && { max_attempts: maxAttempts }),
    ...(condition && { condition })
  }];

  try {
    const response = await fetch(url, {
      method: 'POST',
      headers: {
        'Authorization': `FlespiToken ${flespiToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(flespiBody),
    });

    const responseText = await response.text();
    let responseData = {};
    try {
      if (responseText) {
        responseData = JSON.parse(responseText);
      }
    } catch(e) {}

    if (!response.ok) {
      return res.status(response.status).json({
        ok: false,
        error: responseData.error || responseText
      });
    }

    return res.status(200).json(responseData);
  } catch (error) {
    console.error(JSON.stringify({
      level: 'error',
      message: 'flespi command failed',
      error: error.message,
      ts: new Date().toISOString(),
    }));

    return res.status(500).json({ ok: false, error: 'internal server error' });
  }
};
