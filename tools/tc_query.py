#!/usr/bin/env python3
"""腾讯云实例查询（TC3-HMAC-SHA256 签名，仅用标准库）"""
import hashlib
import hmac
import json
import os
import time
import urllib.request
from datetime import datetime, timezone

# 密钥只从环境变量读取，不写任何默认值，避免密钥泄露进代码库。
# 使用前先导出：export TC_SECRET_ID=...  TC_SECRET_KEY=...
SECRET_ID = os.environ.get("TC_SECRET_ID")
SECRET_KEY = os.environ.get("TC_SECRET_KEY")

SERVICE = "cvm"
ACTION = "DescribeInstances"
VERSION = "2017-03-12"
REGION = "ap-guangzhou"  # 广州


def sign_request(secret_id, secret_key, service, action, version, region, payload):
    host = f"{service}.tencentcloudapi.com"
    algorithm = "TC3-HMAC-SHA256"
    timestamp = int(time.time())
    date = datetime.fromtimestamp(timestamp, tz=timezone.utc).strftime("%Y-%m-%d")

    # 1. canonical request
    http_request_method = "POST"
    canonical_uri = "/"
    canonical_querystring = ""
    ct = "application/json; charset=utf-8"
    canonical_headers = (
        f"content-type:{ct}\n"
        f"host:{host}\n"
        f"x-tc-action:{action.lower()}\n"
    )
    signed_headers = "content-type;host;x-tc-action"
    hashed_payload = hashlib.sha256(payload.encode()).hexdigest()
    canonical_request = "\n".join([
        http_request_method, canonical_uri, canonical_querystring,
        canonical_headers, signed_headers, hashed_payload,
    ])

    # 2. string to sign
    credential_scope = f"{date}/{service}/tc3_request"
    hashed_canonical_request = hashlib.sha256(canonical_request.encode()).hexdigest()
    string_to_sign = "\n".join([
        algorithm, str(timestamp), credential_scope, hashed_canonical_request,
    ])

    # 3. signature
    k_date = hmac.new(("TC3" + secret_key).encode(), date.encode(), hashlib.sha256).digest()
    k_service = hmac.new(k_date, service.encode(), hashlib.sha256).digest()
    k_signing = hmac.new(k_service, "tc3_request".encode(), hashlib.sha256).digest()
    signature = hmac.new(k_signing, string_to_sign.encode(), hashlib.sha256).hexdigest()

    # 4. authorization
    authorization = (
        f"{algorithm} Credential={secret_id}/{credential_scope}, "
        f"SignedHeaders={signed_headers}, Signature={signature}"
    )

    headers = {
        "Authorization": authorization,
        "Content-Type": ct,
        "Host": host,
        "X-TC-Action": action,
        "X-TC-Version": version,
        "X-TC-Timestamp": str(timestamp),
        "X-TC-Region": region,
    }

    req = urllib.request.Request(
        f"https://{host}/", data=payload.encode(), headers=headers, method="POST"
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        return {"http_error": e.code, "body": e.read().decode()[:2000]}
    except Exception as e:
        return {"error": str(e)}


if __name__ == "__main__":
    import sys

    if not SECRET_ID or not SECRET_KEY:
        print(
            "错误：未设置腾讯云密钥环境变量 TC_SECRET_ID / TC_SECRET_KEY",
            file=sys.stderr,
        )
        sys.exit(1)

    action = sys.argv[1] if len(sys.argv) > 1 else ACTION
    # 不同 API 的版本不同
    versions = {
        "DescribeInstances": "2017-03-12",
        "DescribeInstanceStatus": "2017-03-12",
        "DescribeSecurityGroups": "2017-03-12",
        "DescribeSecurityGroupAssociations": "2017-03-12",
        "DescribeZones": "2017-03-12",
        "DescribeRegions": "2017-03-12",
        "InquiryPriceResetInstance": "2017-03-12",
    }
    ver = versions.get(action, VERSION)
    if action in ("DescribeRegions", "DescribeZones"):
        # 区域查询不需要 region
        payload = "{}"
        REGION_ARG = ""
    else:
        payload = "{}"
        REGION_ARG = REGION

    result = sign_request(SECRET_ID, SECRET_KEY, SERVICE, action, ver, REGION_ARG, payload)
    print(json.dumps(result, ensure_ascii=False, indent=2, default=str))