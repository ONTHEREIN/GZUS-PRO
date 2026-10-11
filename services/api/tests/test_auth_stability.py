import base64
import json
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import quote

import httpx
import pytest

from app.cas_auto_login import CasAutoLogin
from app.database import EcardPowerConsumption
from app.routes.ecard import _monthly_overview


def test_authenticated_jwxt_survives_ehall_delay():
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format, *args):
            pass

        def do_POST(self):
            self.rfile.read(int(self.headers.get('Content-Length', '0')))
            self.send_response(200)
            self.end_headers()
            self.wfile.write(json.dumps({'ticket': 'test-ticket', 'tgt': ''}).encode())

        def do_GET(self):
            if self.path.startswith('/ehall'):
                time.sleep(0.3)
            self.send_response(200)
            self.send_header('Set-Cookie', 'JSESSIONID=local-session; Path=/')
            self.end_headers()
            if 'xsgrxxwh' in self.path:
                self.wfile.write(b'<div id="col_xh">test-account</div>')

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = f'http://127.0.0.1:{server.server_port}'
    cas = CasAutoLogin(
        cas_url=f'{base}/login?service={quote(base + "/sso", safe="")}',
        ehall_url=base + '/ehall', ehall_service_url=base + '/ehall', timeout=0.1,
    )
    try:
        with httpx.Client(timeout=2) as client:
            result = cas._submit_login(client, 'test-account', 'test-password', 'uid', '2')
            assert result is not None
            assert result.error is None
            assert 'JSESSIONID=' in result.cookies
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def test_empty_month_is_explicitly_unavailable():
    row = EcardPowerConsumption(room_id='test-room', month='2026-10', items_json='[]',
                                cached_at=datetime.now(timezone.utc))
    result = _monthly_overview(row)
    assert result['reasonCode'] == 'no_records'
    assert 'totalUsage' not in result


def test_month_data_errors_do_not_fabricate_usage():
    cases = [
        ('[{"date":"2026-10-01","usage":0,"unit":"度"}]', None),
        ('[{"date":"2026-10-01","amount":20,"unit":"度"}]', 'incomplete_data'),
        ('[{"date":"2026-10-01","usage":NaN,"unit":"度"}]', 'invalid_data'),
        ('[{"date":"wrong","usage":1,"unit":"度"}]', 'invalid_data'),
        ('broken', 'corrupt_cache'),
        ('[{"date":"2026-10-01","usage":2,"unit":"度"},{"usage":null}]', 'incomplete_data'),
    ]
    for content, reason in cases:
        row = EcardPowerConsumption(room_id='test-room', month='2026-10', items_json=content,
                                    cached_at=datetime.now(timezone.utc))
        result = _monthly_overview(row)
        if reason is None:
            assert result['totalUsage'] == 0
        else:
            assert result['reasonCode'] == reason
            assert 'totalUsage' not in result


@pytest.mark.parametrize('info_body,info_delay,expected_error', [
    (b'<div id="col_xh">test-account</div>', 0, None),
    (b'<form>login_slogin</form>', 0, 'jwxt_session_unavailable'),
    (b'<div id="col_xh">test-account</div>', 0.4, 'jwxt_session_unavailable'),
])
def test_cas_budget_includes_required_session_validation(
    monkeypatch, info_body, info_delay, expected_error,
):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format, *args):
            pass

        def do_POST(self):
            self.rfile.read(int(self.headers.get('Content-Length', '0')))
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"ticket":"local-ticket","tgt":""}')

        def do_GET(self):
            body = b''
            if 'kaptcha' in self.path:
                body = json.dumps({'uid': 'local', 'content': base64.b64encode(b'image').decode()}).encode()
            elif 'xsgrxxwh' in self.path:
                time.sleep(info_delay)
                body = info_body
            elif self.path.startswith('/ehall'):
                time.sleep(0.4)
            self.send_response(200)
            self.send_header('Set-Cookie', 'JSESSIONID=local-session; Path=/')
            self.end_headers()
            try:
                self.wfile.write(body)
            except BrokenPipeError:
                pass  # 超时客户端已关闭连接，测试服务器仍须完成清理。

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = f'http://127.0.0.1:{server.server_port}'
    cas = CasAutoLogin(
        cas_url=f'{base}/login?service={quote(base + "/sso", safe="")}',
        ehall_url=base + '/ehall', ehall_service_url=base + '/ehall', timeout=0.3,
    )
    monkeypatch.setattr('app.cas_auto_login.captcha_ocr.recognize', lambda image: '1+1')
    started = time.monotonic()
    try:
        result = cas.auto_login('test-account', 'test-password')
        assert time.monotonic() - started < 0.7
        assert result.error_code == expected_error
        if expected_error is None:
            assert result.error is None
            assert result.ehall_error is not None
        else:
            assert result.error_status == 502
        if result.httpx_client is not None:
            result.httpx_client.close()
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
