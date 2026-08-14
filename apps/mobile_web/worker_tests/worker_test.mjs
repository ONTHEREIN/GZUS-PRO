import assert from 'node:assert/strict';
import test from 'node:test';

import worker from '../web/_worker.js';


test('health endpoint reports edge availability', async () => {
  const request = new Request('https://onegzus.example/api/health', {
    headers: { Origin: 'https://app.example.test' },
  });

  const response = await worker.fetch(request, {}, {});

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { status: 'ok', edge: true });
  assert.equal(
    response.headers.get('access-control-allow-origin'),
    'https://app.example.test',
  );
});


test('CORS preflight is handled without reaching an upstream service', async () => {
  const request = new Request('https://onegzus.example/api/grades', {
    method: 'OPTIONS',
    headers: { Origin: 'https://app.example.test' },
  });

  const response = await worker.fetch(request, {}, {});

  assert.equal(response.status, 204);
  assert.equal(
    response.headers.get('access-control-allow-methods'),
    'GET,POST,PUT,PATCH,OPTIONS',
  );
});


test('ecard proxy rejects unsupported targets', async () => {
  const request = new Request('https://onegzus.example/api/_proxy', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      url: 'https://evil.example/private',
      method: 'GET',
    }),
  });

  const response = await worker.fetch(request, {}, {});

  assert.equal(response.status, 403);
  assert.deepEqual(await response.json(), { detail: 'Unsupported proxy target' });
});


test('JWXT proxy fails clearly when the edge session is missing', async () => {
  const request = new Request(
    'https://onegzus.example/jwglxt/xtgl/index_initMenu.html',
    { headers: { 'X-Jwxt-Session-Id': 'missing-session' } },
  );

  const response = await worker.fetch(request, {}, {});

  assert.equal(response.status, 502);
  assert.equal(await response.text(), 'JWXT session not found');
});


test('API proxy restores a KV session and injects edge cookies', { concurrency: false }, async () => {
  const originalFetch = globalThis.fetch;
  let upstreamRequest = null;
  const sessionId = 'kv-session';
  const session = {
    account: '20240001',
    cookies: 'JSESSIONID=edge-session',
    ehallCookies: 'customsid=ehall-session',
    expiresAt: Date.now() + 60_000,
  };
  const kv = {
    async get(key) {
      if (key === `session:${sessionId}`) return JSON.stringify(session);
      if (key.startsWith('account-session:')) return sessionId;
      return null;
    },
  };
  globalThis.fetch = async (request) => {
    upstreamRequest = request;
    return new Response(JSON.stringify({ source: 'backend' }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  };

  try {
    const request = new Request('https://onegzus.example/api/me?include=profile', {
      headers: {
        Origin: 'https://app.example.test',
        'CF-Connecting-IP': '203.0.113.8',
        'X-Session-Id': sessionId,
      },
    });
    const response = await worker.fetch(
      request,
      { API_ORIGIN: 'https://api.example.test', SESSIONS_KV: kv },
      {},
    );

    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { source: 'backend' });
    assert.equal(upstreamRequest.url, 'https://api.example.test/me?include=profile');
    assert.equal(upstreamRequest.headers.get('cookie'), 'JSESSIONID=edge-session');
    assert.equal(upstreamRequest.headers.get('x-ehall-cookies'), 'customsid=ehall-session');
    assert.equal(upstreamRequest.headers.get('x-student-account'), '20240001');
    assert.equal(upstreamRequest.headers.get('x-worker-auth'), '1');
    assert.equal(upstreamRequest.headers.get('x-forwarded-for'), '203.0.113.8');
    assert.equal(upstreamRequest.headers.get('cf-connecting-ip'), null);
    assert.equal(
      response.headers.get('access-control-allow-origin'),
      'https://app.example.test',
    );
  } finally {
    globalThis.fetch = originalFetch;
  }
});


test('API proxy retries a transient backend failure', { concurrency: false }, async () => {
  const originalFetch = globalThis.fetch;
  let attempts = 0;
  globalThis.fetch = async () => {
    attempts += 1;
    if (attempts === 1) {
      return new Response('temporary failure', { status: 503 });
    }
    return new Response(JSON.stringify({ status: 'ok' }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  };

  try {
    const response = await worker.fetch(
      new Request('https://onegzus.example/api/me'),
      { API_ORIGIN: 'https://api.example.test' },
      {},
    );

    assert.equal(attempts, 2);
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { status: 'ok' });
  } finally {
    globalThis.fetch = originalFetch;
  }
});
