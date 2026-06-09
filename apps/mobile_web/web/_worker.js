const API_ORIGIN = 'https://api-one-zeta-dc0jrazxzq.vercel.app';

function corsHeaders(request) {
  return {
    'Access-Control-Allow-Origin': request.headers.get('Origin') || '*',
    'Access-Control-Allow-Methods': 'GET,POST,PATCH,OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type,X-Session-Id,User-Agent',
    'Access-Control-Max-Age': '86400',
  };
}

export default {
  async fetch(request, env, context) {
    const url = new URL(request.url);
    if (!url.pathname.startsWith('/api/')) {
      return env.ASSETS.fetch(request);
    }

    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: corsHeaders(request) });
    }

    const origin = (env.API_ORIGIN || API_ORIGIN).replace(/\/$/, '');
    const upstreamUrl = new URL(url.pathname.slice(4) + url.search, origin);
    const upstreamRequest = new Request(upstreamUrl, request);
    const response = await fetch(upstreamRequest);
    const headers = new Headers(response.headers);
    for (const [key, value] of Object.entries(corsHeaders(request))) {
      headers.set(key, value);
    }
    return new Response(response.body, {
      status: response.status,
      statusText: response.statusText,
      headers,
    });
  },
};
