import httpx

from app.cas_auto_login import CasAutoLogin, _sanitize_response_body


def test_sanitize_response_body_redacts_credentials():
    """日志脱敏：ticket/TGT 等凭证不得出现在日志文本中。"""
    text = '{"ticket": "ST-12345", "tgt": "TGT-67890", "msg": "登录成功"} ticket=ST-999'
    out = _sanitize_response_body(text)

    assert "ST-12345" not in out
    assert "TGT-67890" not in out
    assert "ST-999" not in out
    assert "[REDACTED]" in out


def test_sanitize_response_body_respects_limit_and_keeps_plain_text():
    out = _sanitize_response_body("x" * 1000)
    assert len(out) == 500
    assert "msg=ok" in _sanitize_response_body("ticket=x&msg=ok")


def test_extract_cookies_for_service_host_includes_parent_domain_cookie():
    client = httpx.Client()
    client.cookies.set("JSESSIONID", "abc", domain=".seig.edu.cn", path="/")
    client.cookies.set("sid", "ehall", domain="ehall.gzus.edu.cn", path="/")

    cookies = CasAutoLogin._extract_cookies_for_hosts(
        client,
        ["jwxt.seig.edu.cn"],
    )

    assert cookies == "JSESSIONID=abc"


def test_extract_ehall_session_reads_customsid_and_authorization():
    client = httpx.Client()
    client.cookies.set("customsid", "custom-1", domain="ehall.gzus.edu.cn", path="/")
    client.cookies.set("Authorization", "token-1", domain="ehall.gzus.edu.cn", path="/")
    client.cookies.set("rememberMe", "deleteMe", domain="ehall.gzus.edu.cn", path="/")

    cookies, token = CasAutoLogin._extract_ehall_session(client)

    assert cookies == "customsid=custom-1; Authorization=token-1"
    assert token == "token-1"
