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
  if (req.method !== 'PUT' && req.method !== 'PATCH') {
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
  const selector = body.selector || body.deviceId;
  if (!selector) {
    return res.status(400).json({ ok: false, error: 'selector or deviceId is required' });
  }

  const name = body.name;
  if (name === undefined) {
    return res.status(400).json({ ok: false, error: 'name is required' });
  }

  const url = `https://flespi.io/gw/devices/${selector}`;

  try {
    const response = await fetch(url, {
      method: 'PUT',
      headers: {
        'Authorization': `FlespiToken ${flespiToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ name }),
    });

    const responseText = await response.text();
    let responseData = {};
    try {
      if (responseText) {
        responseData = JSON.parse(responseText);
      }
    } catch(e) {}

    if (!response.ok) {
      console.error(JSON.stringify({
        level: 'error',
        message: 'flespi update device responded with error',
        selector,
        requestBody: { name },
        status: response.status,
        responseText: responseText,
        parsed: responseData,
        ts: new Date().toISOString(),
      }));

      return res.status(response.status).json({
        ok: false,
        error: responseData.error || responseText
      });
    }

    // log success for auditing
    console.info(JSON.stringify({
      level: 'info',
      message: 'flespi update device succeeded',
      selector,
      requestBody: { name },
      response: responseData,
      ts: new Date().toISOString(),
    }));

    return res.status(200).json(responseData);
  } catch (error) {
    console.error(JSON.stringify({
      level: 'error',
      message: 'flespi update device failed',
      error: error.message,
      ts: new Date().toISOString(),
    }));

    return res.status(500).json({ ok: false, error: 'internal server error' });
  }
};
