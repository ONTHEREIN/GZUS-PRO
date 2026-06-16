const FILEAUTH = '202606131542511zb9aeiv4g8c72mwhaw92y12mj11ahxhyvc6b56ciin7km14c0';

export function onRequestGet() {
  return new Response(FILEAUTH, {
    headers: {
      'Content-Type': 'text/plain; charset=utf-8',
      'Cache-Control': 'no-store',
    },
  });
}
