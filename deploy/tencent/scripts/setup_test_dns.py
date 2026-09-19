#!/usr/bin/env python3
"""为测试环境添加/更新 DNS A 记录（DNSPod）。

凭据**只从环境文件读取**，绝不通过命令行参数传入——命令行参数会进入 shell 历史、
也会出现在 `ps` 输出里。默认读取 `~/.dnspod.env`，可用 --env-file 覆盖。

支持的凭据二选一：

1) DNSPod 老版 API Token（推荐，最简单）
       DNSPOD_LOGIN_TOKEN=123456,abcdef0123456789abcdef0123456789
   获取：DNSPod 控制台 → 用户中心 → 安全设置 → API Token
   （注意是「ID,Token」这种逗号分隔形式，不是新版密钥）

2) 腾讯云 API 密钥（需具备 DNSPod 权限）
       TENCENTCLOUD_SECRET_ID=AKID...
       TENCENTCLOUD_SECRET_KEY=...

用法：
    python3 setup_test_dns.py --check                 # 只读：验证凭据并列出相关记录
    python3 setup_test_dns.py                         # 创建/更新 A 记录
    python3 setup_test_dns.py --domain onrein.top --sub-domain test-api --ip 1.2.3.4

退出码：0 成功；1 失败。
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

DNSPOD_LEGACY_ENDPOINT = "https://dnsapi.cn"
TENCENT_ENDPOINT = "https://dnspod.tencentcloudapi.com"
TENCENT_HOST = "dnspod.tencentcloudapi.com"
TENCENT_SERVICE = "dnspod"
TENCENT_VERSION = "2021-03-23"


# ─── 凭据加载 ────────────────────────────────────────────────────────

def load_env_file(path: Path) -> dict[str, str]:
    """读取 KEY=VALUE 形式的环境文件；文件不存在时返回空。"""
    values: dict[str, str] = {}
    if not path.is_file():
        return values
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        value = value.strip().strip('"').strip("'")
        values[key.strip()] = value
    return values


def resolve_credentials(env_file: Path) -> tuple[str, dict[str, str]]:
    """返回 (模式, 凭据)。环境变量优先于文件。"""
    file_values = load_env_file(env_file)

    def get(key: str) -> str:
        return os.environ.get(key) or file_values.get(key, "")

    token = get("DNSPOD_LOGIN_TOKEN")
    if token:
        if "," not in token:
            raise SystemExit(
                "DNSPOD_LOGIN_TOKEN 格式不对：应为 `<ID>,<Token>`（逗号分隔）。"
            )
        return "legacy", {"login_token": token}

    secret_id = get("TENCENTCLOUD_SECRET_ID")
    secret_key = get("TENCENTCLOUD_SECRET_KEY")
    if secret_id and secret_key:
        return "tencent", {"secret_id": secret_id, "secret_key": secret_key}

    raise SystemExit(
        f"未找到可用凭据。请在 {env_file} 中写入以下二者之一：\n"
        "  DNSPOD_LOGIN_TOKEN=<ID>,<Token>\n"
        "  TENCENTCLOUD_SECRET_ID=... 且 TENCENTCLOUD_SECRET_KEY=..."
    )


# ─── HTTP ───────────────────────────────────────────────────────────

def post_form(url: str, fields: dict[str, str]) -> dict:
    body = urllib.parse.urlencode(fields).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.loads(response.read().decode("utf-8"))


def _sha256_hex(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _hmac(key: bytes, message: str) -> bytes:
    return hmac.new(key, message.encode("utf-8"), hashlib.sha256).digest()


def post_tencent(action: str, payload: dict, creds: dict[str, str]) -> dict:
    """调用腾讯云 DNSPod API（TC3-HMAC-SHA256 签名，不依赖 SDK）。"""
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    timestamp = int(datetime.now(timezone.utc).timestamp())
    date = datetime.fromtimestamp(timestamp, timezone.utc).strftime("%Y-%m-%d")

    canonical_headers = (
        "content-type:application/json; charset=utf-8\n"
        f"host:{TENCENT_HOST}\n"
        f"x-tc-action:{action.lower()}\n"
    )
    signed_headers = "content-type;host;x-tc-action"
    canonical_request = "\n".join(
        [
            "POST",
            "/",
            "",
            canonical_headers,
            signed_headers,
            _sha256_hex(body),
        ]
    )

    credential_scope = f"{date}/{TENCENT_SERVICE}/tc3_request"
    string_to_sign = "\n".join(
        [
            "TC3-HMAC-SHA256",
            str(timestamp),
            credential_scope,
            _sha256_hex(canonical_request.encode("utf-8")),
        ]
    )

    secret_date = _hmac(f"TC3{creds['secret_key']}".encode("utf-8"), date)
    secret_service = _hmac(secret_date, TENCENT_SERVICE)
    secret_signing = _hmac(secret_service, "tc3_request")
    signature = hmac.new(
        secret_signing, string_to_sign.encode("utf-8"), hashlib.sha256
    ).hexdigest()

    authorization = (
        f"TC3-HMAC-SHA256 Credential={creds['secret_id']}/{credential_scope}, "
        f"SignedHeaders={signed_headers}, Signature={signature}"
    )

    request = urllib.request.Request(
        TENCENT_ENDPOINT,
        data=body,
        headers={
            "Authorization": authorization,
            "Content-Type": "application/json; charset=utf-8",
            "Host": TENCENT_HOST,
            "X-TC-Action": action,
            "X-TC-Version": TENCENT_VERSION,
            "X-TC-Timestamp": str(timestamp),
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        return json.loads(exc.read().decode("utf-8"))


# ─── 记录查询与写入 ─────────────────────────────────────────────────

def find_record(mode: str, creds: dict, domain: str, sub_domain: str) -> dict | None:
    if mode == "legacy":
        result = post_form(
            f"{DNSPOD_LEGACY_ENDPOINT}/Record.List",
            {
                "login_token": creds["login_token"],
                "format": "json",
                "domain": domain,
                "sub_domain": sub_domain,
            },
        )
        if result.get("status", {}).get("code") != "1":
            raise SystemExit(f"Record.List 失败：{result.get('status')}")
        for record in result.get("records", []):
            if record.get("type") == "A" and record.get("name") == sub_domain:
                return {"id": record.get("id"), "value": record.get("value")}
        return None

    result = post_tencent(
        "DescribeRecordList",
        {"Domain": domain, "Subdomain": sub_domain, "RecordType": "A"},
        creds,
    )
    response = result.get("Response", {})
    if response.get("Error"):
        raise SystemExit(f"DescribeRecordList 失败：{response['Error']}")
    for record in response.get("RecordList", []):
        return {"id": str(record.get("RecordId")), "value": record.get("Value")}
    return None


def upsert_record(mode: str, creds: dict, domain: str, sub_domain: str, ip: str) -> str:
    existing = find_record(mode, creds, domain, sub_domain)

    if mode == "legacy":
        if existing and existing["value"] == ip:
            return f"已存在且值正确（record id {existing['id']}），无需改动"
        fields = {
            "login_token": creds["login_token"],
            "format": "json",
            "domain": domain,
            "sub_domain": sub_domain,
            "record_type": "A",
            "record_line": "默认",
            "value": ip,
            "ttl": "600",
        }
        if existing:
            fields["record_id"] = str(existing["id"])
            result = post_form(f"{DNSPOD_LEGACY_ENDPOINT}/Record.Modify", fields)
            action = "已更新"
        else:
            result = post_form(f"{DNSPOD_LEGACY_ENDPOINT}/Record.Create", fields)
            action = "已创建"
        if result.get("status", {}).get("code") != "1":
            raise SystemExit(f"写入失败：{result.get('status')}")
        return f"{action} A 记录 {sub_domain}.{domain} → {ip}"

    payload = {"Domain": domain, "SubDomain": sub_domain, "RecordType": "A", "RecordLine": "默认", "Value": ip, "TTL": 600}
    if existing:
        if existing["value"] == ip:
            return f"已存在且值正确（RecordId {existing['id']}），无需改动"
        payload["RecordId"] = int(existing["id"])
        result = post_tencent("ModifyRecord", payload, creds)
        action = "已更新"
    else:
        result = post_tencent("CreateRecord", payload, creds)
        action = "已创建"
    response = result.get("Response", {})
    if response.get("Error"):
        raise SystemExit(f"写入失败：{response['Error']}")
    return f"{action} A 记录 {sub_domain}.{domain} → {ip}"


# ─── 入口 ───────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(description="为测试环境添加/更新 DNSPod A 记录")
    parser.add_argument("--env-file", default="~/.dnspod.env", help="凭据文件（默认 ~/.dnspod.env）")
    parser.add_argument("--domain", default="onrein.top", help="主域名")
    parser.add_argument("--sub-domain", default="test-api", help="主机记录")
    parser.add_argument("--ip", default="106.55.2.248", help="目标 IP")
    parser.add_argument("--check", action="store_true", help="只读：验证凭据并查询现有记录")
    args = parser.parse_args()

    env_file = Path(args.env_file).expanduser()
    mode, creds = resolve_credentials(env_file)
    print(f"凭据来源：{env_file}（模式：{mode}）")

    if args.check:
        existing = find_record(mode, creds, args.domain, args.sub_domain)
        if existing:
            print(f"现有记录：{args.sub_domain}.{args.domain} → {existing['value']}（id {existing['id']}）")
            if existing["value"] != args.ip:
                print(f"注意：与目标 IP {args.ip} 不一致，执行不带 --check 的命令即可更新。")
        else:
            print(f"未找到 {args.sub_domain}.{args.domain} 的 A 记录（将新建）。")
        return 0

    print(upsert_record(mode, creds, args.domain, args.sub_domain, args.ip))
    print("提示：DNS 生效通常需要几十秒到几分钟；可用 `dig +short @tomato.dnspod.net " + f"{args.sub_domain}.{args.domain}" + "` 直接问权威 NS。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
