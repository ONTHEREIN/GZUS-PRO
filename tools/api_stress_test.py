#!/usr/bin/env python3
"""
OneGZUS API 功能压力测试脚本。

默认覆盖只读功能接口；可用已有 session，也可用环境变量账号密码登录后测试。
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import random
import statistics
import time
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any
from urllib.parse import urljoin

import httpx


DEFAULT_ENDPOINTS = [
    ("health", "GET", "/health", 1),
    ("me", "GET", "/me", 2),
    ("schedule", "GET", "/schedule", 1),
    ("exams", "GET", "/exams", 2),
    ("grades", "GET", "/grades", 2),
    ("credits", "GET", "/credits", 2),
    ("attendance", "GET", "/attendance", 2),
    ("notices", "GET", "/notices", 2),
    ("ehall_progress", "GET", "/ehall/progress", 1),
    ("ecard_summary", "GET", "/ecard/summary", 1),
    ("push_poll", "GET", "/push/poll", 1),
]

PUBLIC_PATHS = {"/health"}

PROFILE_ENDPOINTS = {
    "mixed": DEFAULT_ENDPOINTS,
    "schedule": [
        ("health", "GET", "/health", 1),
        ("me", "GET", "/me", 1),
        ("schedule", "GET", "/schedule", 8),
    ],
    "fast": [
        ("health", "GET", "/health", 1),
        ("me", "GET", "/me", 3),
        ("exams", "GET", "/exams", 2),
        ("grades", "GET", "/grades", 2),
        ("credits", "GET", "/credits", 2),
        ("attendance", "GET", "/attendance", 2),
        ("push_poll", "GET", "/push/poll", 1),
    ],
    "slow": [
        ("notices", "GET", "/notices", 3),
        ("ehall_progress", "GET", "/ehall/progress", 2),
        ("ecard_summary", "GET", "/ecard/summary", 2),
        ("schedule", "GET", "/schedule", 1),
    ],
}


@dataclass(frozen=True)
class Endpoint:
    name: str
    method: str
    path: str
    weight: int = 1


@dataclass
class Sample:
    endpoint: str
    status: int | None
    elapsed_ms: float
    ok: bool
    error: str = ""


@dataclass
class RunStats:
    samples: list[Sample] = field(default_factory=list)
    started_at: float = field(default_factory=time.perf_counter)
    ended_at: float = field(default_factory=time.perf_counter)

    @property
    def total(self) -> int:
        return len(self.samples)

    @property
    def ok(self) -> int:
        return sum(1 for sample in self.samples if sample.ok)

    @property
    def failed(self) -> int:
        return self.total - self.ok

    @property
    def elapsed(self) -> float:
        return max(0.001, self.ended_at - self.started_at)

    @property
    def rps(self) -> float:
        return self.total / self.elapsed


def normalize_base_url(value: str) -> str:
    value = value.strip().rstrip("/")
    if not value:
        raise ValueError("base URL 不能为空")
    return value


def build_url(base_url: str, path: str) -> str:
    return urljoin(base_url.rstrip("/") + "/", path.lstrip("/"))


def parse_endpoint(value: str) -> Endpoint:
    parts = [part.strip() for part in value.split(":")]
    if len(parts) == 1:
        path = parts[0]
        name = path.strip("/").replace("/", "_") or "root"
        return Endpoint(name=name, method="GET", path=path)
    if len(parts) not in {2, 3, 4}:
        raise argparse.ArgumentTypeError(
            "接口格式应为 /path 或 name:METHOD:/path[:weight]"
        )
    name, method, path = parts[:3]
    weight = int(parts[3]) if len(parts) == 4 else 1
    return Endpoint(name=name, method=method.upper(), path=path, weight=max(1, weight))


def endpoints_for_profile(profile: str) -> list[Endpoint]:
    return [
        Endpoint(name=name, method=method, path=path, weight=weight)
        for name, method, path, weight in PROFILE_ENDPOINTS[profile]
    ]


async def auto_login(
    client: httpx.AsyncClient,
    base_url: str,
    account: str,
    password: str,
    timeout: float,
) -> str:
    try:
        response = await client.post(
            build_url(base_url, "/auth/auto-login"),
            json={"account": account, "password": password},
            timeout=timeout,
        )
        response.raise_for_status()
    except httpx.TimeoutException as exc:
        raise RuntimeError(
            f"自动登录超时（{timeout:.0f}s）。可加大 --login-timeout，"
            "或先在客户端登录后用 --session-id/GZUS_SESSION_ID 压测。"
        ) from exc
    except httpx.HTTPStatusError as exc:
        detail = exc.response.text[:300]
        raise RuntimeError(
            f"自动登录失败: HTTP {exc.response.status_code} {detail}"
        ) from exc
    data = response.json()
    session_id = data.get("sessionId") or data.get("session_id")
    if not session_id:
        raise RuntimeError("/auth/auto-login 未返回 sessionId")
    return str(session_id)


async def relogin_with_credential_token(
    client: httpx.AsyncClient,
    base_url: str,
    credential_token: str,
    timeout: float,
) -> tuple[str, str | None]:
    try:
        response = await client.post(
            build_url(base_url, "/auth/relogin"),
            json={"credentialToken": credential_token},
            timeout=timeout,
        )
        response.raise_for_status()
    except httpx.TimeoutException as exc:
        raise RuntimeError(
            f"凭据续登超时（{timeout:.0f}s）。可加大 --login-timeout，"
            "或先在客户端重新登录后复制新的 session。"
        ) from exc
    except httpx.HTTPStatusError as exc:
        detail = exc.response.text[:300]
        raise RuntimeError(
            f"凭据续登失败: HTTP {exc.response.status_code} {detail}"
        ) from exc
    data = response.json()
    session_id = data.get("sessionId") or data.get("session_id")
    if not session_id:
        raise RuntimeError("/auth/relogin 未返回 sessionId")
    fresh_token = data.get("credentialToken") or data.get("credential_token")
    return str(session_id), str(fresh_token) if fresh_token else None


async def validate_session(
    client: httpx.AsyncClient,
    base_url: str,
    session_id: str | None,
    endpoints: list[Endpoint],
) -> None:
    if not session_id and any(endpoint.path not in PUBLIC_PATHS for endpoint in endpoints):
        raise RuntimeError(
            "未提供 session，受保护接口无法预检。请传入 --session-id，或使用 "
            "--credential-token/GZUS_CREDENTIAL_TOKEN 自动续登。"
        )
    if not session_id:
        return
    sample = await single_request(
        client,
        base_url,
        Endpoint(name="me", method="GET", path="/me"),
        session_id,
    )
    if sample.status == 401:
        raise RuntimeError(
            "当前 session 已过期。请换新的 --session-id，或使用 "
            "--credential-token/GZUS_CREDENTIAL_TOKEN 自动续登。"
        )


async def single_request(
    client: httpx.AsyncClient,
    base_url: str,
    endpoint: Endpoint,
    session_id: str | None,
) -> Sample:
    started = time.perf_counter()
    headers = {"X-Session-Id": session_id} if session_id else {}
    try:
        response = await client.request(
            endpoint.method,
            build_url(base_url, endpoint.path),
            headers=headers,
        )
        await response.aread()
        elapsed_ms = (time.perf_counter() - started) * 1000
        return Sample(
            endpoint=endpoint.name,
            status=response.status_code,
            elapsed_ms=elapsed_ms,
            ok=200 <= response.status_code < 400,
            error="" if response.status_code < 400 else response.text[:160],
        )
    except Exception as exc:
        elapsed_ms = (time.perf_counter() - started) * 1000
        return Sample(
            endpoint=endpoint.name,
            status=None,
            elapsed_ms=elapsed_ms,
            ok=False,
            error=f"{type(exc).__name__}: {exc}",
        )


async def worker(
    worker_id: int,
    client: httpx.AsyncClient,
    base_url: str,
    endpoints: list[Endpoint],
    session_id: str | None,
    deadline: float,
    max_requests: int | None,
    max_401: int | None,
    counter_lock: asyncio.Lock,
    request_counter: list[int],
    unauthorized_counter: list[int],
    result_queue: asyncio.Queue[Sample],
) -> None:
    weighted = [
        endpoint
        for endpoint in endpoints
        for _ in range(max(1, endpoint.weight))
    ]
    while time.perf_counter() < deadline:
        async with counter_lock:
            if max_401 is not None and unauthorized_counter[0] >= max_401:
                return
            if max_requests is not None and request_counter[0] >= max_requests:
                return
            request_counter[0] += 1
        endpoint = random.choice(weighted)
        sample = await single_request(client, base_url, endpoint, session_id)
        await result_queue.put(sample)
        if sample.status == 401 and max_401 is not None:
            async with counter_lock:
                unauthorized_counter[0] += 1
                if unauthorized_counter[0] >= max_401:
                    return


async def collect_results(
    result_queue: asyncio.Queue[Sample],
    stats: RunStats,
    stop_event: asyncio.Event,
) -> None:
    while not stop_event.is_set() or not result_queue.empty():
        try:
            sample = await asyncio.wait_for(result_queue.get(), timeout=0.2)
        except TimeoutError:
            continue
        stats.samples.append(sample)


def percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = round((len(ordered) - 1) * pct)
    return ordered[index]


def render_report(stats: RunStats) -> None:
    latencies = [sample.elapsed_ms for sample in stats.samples]
    statuses = Counter(
        str(sample.status) if sample.status is not None else "ERR"
        for sample in stats.samples
    )
    by_endpoint: dict[str, list[Sample]] = defaultdict(list)
    for sample in stats.samples:
        by_endpoint[sample.endpoint].append(sample)

    print("\n=== 压力测试报告 ===")
    print(f"总请求: {stats.total}")
    print(f"成功: {stats.ok}")
    print(f"失败: {stats.failed}")
    print(f"成功率: {(stats.ok / stats.total * 100 if stats.total else 0):.2f}%")
    print(f"耗时: {stats.elapsed:.2f}s")
    print(f"吞吐: {stats.rps:.2f} req/s")
    print(
        "延迟(ms): "
        f"avg={statistics.mean(latencies) if latencies else 0:.1f} "
        f"p50={percentile(latencies, 0.50):.1f} "
        f"p95={percentile(latencies, 0.95):.1f} "
        f"p99={percentile(latencies, 0.99):.1f} "
        f"max={max(latencies) if latencies else 0:.1f}"
    )
    print(f"状态码: {dict(statuses)}")
    html_errors = sum(
        1
        for sample in stats.samples
        if sample.error and "<!doctype html" in sample.error.lower()
    )
    print(f"HTML错误回包: {html_errors}")

    print("\n--- 按接口统计 ---")
    for endpoint, samples in sorted(by_endpoint.items()):
        endpoint_latencies = [sample.elapsed_ms for sample in samples]
        ok = sum(1 for sample in samples if sample.ok)
        print(
            f"{endpoint:16} total={len(samples):5d} "
            f"ok={ok:5d} "
            f"fail={len(samples) - ok:5d} "
            f"p95={percentile(endpoint_latencies, 0.95):7.1f}ms"
        )

    errors = [sample for sample in stats.samples if not sample.ok and sample.error]
    if errors:
        print("\n--- 错误样本，最多 10 条 ---")
        for sample in errors[:10]:
            print(
                f"{sample.endpoint} status={sample.status} "
                f"elapsed={sample.elapsed_ms:.1f}ms error={sample.error}"
            )


def write_json_report(path: Path, stats: RunStats) -> None:
    payload: dict[str, Any] = {
        "total": stats.total,
        "ok": stats.ok,
        "failed": stats.failed,
        "elapsedSeconds": stats.elapsed,
        "rps": stats.rps,
        "samples": [
            {
                "endpoint": sample.endpoint,
                "status": sample.status,
                "elapsedMs": sample.elapsed_ms,
                "ok": sample.ok,
                "error": sample.error,
            }
            for sample in stats.samples
        ],
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


async def run(args: argparse.Namespace) -> int:
    base_url = normalize_base_url(args.base_url)
    endpoints = args.endpoint or endpoints_for_profile(args.profile)
    timeout = httpx.Timeout(args.timeout, connect=args.connect_timeout)
    limits = httpx.Limits(
        max_connections=max(args.concurrency * 2, 20),
        max_keepalive_connections=max(args.concurrency, 10),
    )
    session_id = args.session_id or os.getenv("GZUS_SESSION_ID")
    credential_token = args.credential_token or os.getenv("GZUS_CREDENTIAL_TOKEN")
    account = args.account or os.getenv("GZUS_TEST_ACCOUNT")
    password = args.password or os.getenv("GZUS_TEST_PASSWORD")

    async with httpx.AsyncClient(timeout=timeout, limits=limits) as client:
        if credential_token:
            print("正在通过 /auth/relogin 刷新测试 session...")
            session_id, fresh_token = await relogin_with_credential_token(
                client,
                base_url,
                credential_token,
                timeout=args.login_timeout,
            )
            if fresh_token and fresh_token != credential_token:
                print("已获取新的 credentialToken；如需长期压测，请更新 GZUS_CREDENTIAL_TOKEN。")
        elif not session_id and account and password:
            print("正在通过 /auth/auto-login 获取测试 session...")
            session_id = await auto_login(
                client,
                base_url,
                account,
                password,
                timeout=args.login_timeout,
            )
        if not session_id and any(endpoint.path != "/health" for endpoint in endpoints):
            print("未提供 session，除 /health 外的接口可能返回 401。")
        if args.preflight:
            await validate_session(client, base_url, session_id, endpoints)

        if args.warmup > 0:
            print(f"预热 {args.warmup} 秒...")
            warmup_deadline = time.perf_counter() + args.warmup
            while time.perf_counter() < warmup_deadline:
                await single_request(client, base_url, endpoints[0], session_id)

        stats = RunStats(started_at=time.perf_counter())
        result_queue: asyncio.Queue[Sample] = asyncio.Queue()
        stop_event = asyncio.Event()
        collector = asyncio.create_task(collect_results(result_queue, stats, stop_event))
        deadline = time.perf_counter() + args.duration
        counter_lock = asyncio.Lock()
        request_counter = [0]
        unauthorized_counter = [0]

        print(
            f"开始压测: base={base_url}, profile={args.profile}, 并发={args.concurrency}, "
            f"时长={args.duration}s, 上限={args.requests or '不限'}"
        )
        tasks = [
            asyncio.create_task(
                worker(
                    worker_id=i,
                    client=client,
                    base_url=base_url,
                    endpoints=endpoints,
                    session_id=session_id,
                    deadline=deadline,
                    max_requests=args.requests,
                    max_401=args.max_401,
                    counter_lock=counter_lock,
                    request_counter=request_counter,
                    unauthorized_counter=unauthorized_counter,
                    result_queue=result_queue,
                )
            )
            for i in range(args.concurrency)
        ]
        await asyncio.gather(*tasks)
        stats.ended_at = time.perf_counter()
        stop_event.set()
        await collector

    render_report(stats)
    if args.json_report:
        write_json_report(Path(args.json_report), stats)
        print(f"\nJSON 报告已写入: {args.json_report}")
    return 0 if stats.failed == 0 or not args.fail_on_error else 1


def main() -> None:
    parser = argparse.ArgumentParser(
        description="OneGZUS API 功能压力测试脚本",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  # 只测本地健康检查
  python tools/api_stress_test.py --base-url http://127.0.0.1:8000 --endpoint health:GET:/health --duration 30 --concurrency 20

  # 使用已有 session 测主要只读功能
  python tools/api_stress_test.py --base-url http://127.0.0.1:8000 --session-id YOUR_SESSION --duration 60 --concurrency 10

  # 单独压测课表链路
  python tools/api_stress_test.py --base-url https://onegzus.cc.cd/api --session-id YOUR_SESSION --profile schedule --duration 60 --concurrency 3

  # 使用环境变量账号密码登录后测试
  $env:GZUS_TEST_ACCOUNT="学号"; $env:GZUS_TEST_PASSWORD="密码"
  python tools/api_stress_test.py --base-url https://onegzus.cc.cd/api --duration 60 --concurrency 5
        """,
    )
    parser.add_argument("--base-url", required=True, help="API 根地址，例如 http://127.0.0.1:8000 或 https://onegzus.cc.cd/api")
    parser.add_argument("--session-id", help="已有 X-Session-Id；也可用环境变量 GZUS_SESSION_ID")
    parser.add_argument("--credential-token", help="用于 /auth/relogin 的 credentialToken；也可用环境变量 GZUS_CREDENTIAL_TOKEN")
    parser.add_argument("--account", help="测试账号；也可用环境变量 GZUS_TEST_ACCOUNT")
    parser.add_argument("--password", help="测试密码；也可用环境变量 GZUS_TEST_PASSWORD")
    parser.add_argument("--duration", type=int, default=60, help="测试时长秒数，默认 60")
    parser.add_argument("--concurrency", type=int, default=10, help="并发协程数，默认 10")
    parser.add_argument(
        "--profile",
        choices=sorted(PROFILE_ENDPOINTS),
        default="mixed",
        help="预设接口组合：mixed=常规混合，fast=较快只读接口，slow=慢接口，schedule=课表专项",
    )
    parser.add_argument("--requests", type=int, help="最大请求数；不填则按时长持续压测")
    parser.add_argument("--timeout", type=float, default=30.0, help="单请求总超时秒数，默认 30")
    parser.add_argument("--login-timeout", type=float, default=90.0, help="自动登录超时秒数，默认 90")
    parser.add_argument("--connect-timeout", type=float, default=10.0, help="连接超时秒数，默认 10")
    parser.add_argument("--warmup", type=int, default=3, help="正式压测前预热秒数，默认 3")
    parser.add_argument("--preflight", action=argparse.BooleanOptionalAction, default=True, help="压测前用 /me 预检 session，默认开启")
    parser.add_argument("--max-401", type=int, default=5, help="401 数量达到该值后停止继续发新请求，默认 5；设为 0 表示不限制")
    parser.add_argument(
        "--endpoint",
        action="append",
        type=parse_endpoint,
        help="自定义接口，可重复。格式: /path 或 name:METHOD:/path[:weight]",
    )
    parser.add_argument("--json-report", help="写出 JSON 明细报告路径")
    parser.add_argument("--fail-on-error", action="store_true", help="存在失败请求时返回非 0")
    args = parser.parse_args()

    if args.concurrency < 1:
        parser.error("--concurrency 必须大于 0")
    if args.duration < 1:
        parser.error("--duration 必须大于 0")
    if args.requests is not None and args.requests < 1:
        parser.error("--requests 必须大于 0")
    if args.max_401 is not None and args.max_401 < 0:
        parser.error("--max-401 不能小于 0")
    if args.max_401 == 0:
        args.max_401 = None

    try:
        raise SystemExit(asyncio.run(run(args)))
    except KeyboardInterrupt:
        print("\n测试已取消")
        raise SystemExit(130)
    except RuntimeError as exc:
        print(f"\n错误: {exc}")
        raise SystemExit(1)


if __name__ == "__main__":
    main()
