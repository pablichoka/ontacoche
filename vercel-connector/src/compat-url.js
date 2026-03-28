// compatibility shim: replace deprecated url.parse usages with WHATWG URL
try {
  const url = require('url');
  if (typeof url.parse === 'function') {
    url.parse = function parseUsingWHATWG(input) {
      if (!input) return null;
      try {
        const u = new URL(String(input));
        return {
          href: u.href,
          protocol: u.protocol, // includes ':'
          slashes: true,
          auth: u.username ? `${u.username}:${u.password}` : null,
          host: u.host,
          hostname: u.hostname,
          port: u.port || null,
          pathname: u.pathname,
          search: u.search,
          query: null,
          hash: u.hash,
        };
      } catch (e) {
        return null;
      }
    };
  }
} catch (e) {
  // ignore if url module unavailable for any reason
}
