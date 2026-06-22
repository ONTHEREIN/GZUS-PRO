import httpx

from app.cas_auto_login import CasAutoLogin


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
