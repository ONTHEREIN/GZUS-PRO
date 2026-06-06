#!/usr/bin/env python3
"""
服务器压力测试与并发测试脚本
支持调节：并发数、线程数、测试时长、目标URL
"""

import argparse
import time
import statistics
import threading
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from typing import List, Optional
import urllib.request
import urllib.error
import json


@dataclass
class TestResult:
    """测试结果统计"""
    total_requests: int = 0
    success_count: int = 0
    fail_count: int = 0
    response_times: List[float] = None

    def __post_init__(self):
        if self.response_times is None:
            self.response_times = []

    @property
    def success_rate(self) -> float:
        if self.total_requests == 0:
            return 0.0
        return (self.success_count / self.total_requests) * 100

    @property
    def avg_response_time(self) -> float:
        if not self.response_times:
            return 0.0
        return statistics.mean(self.response_times)

    @property
    def min_response_time(self) -> float:
        if not self.response_times:
            return 0.0
        return min(self.response_times)

    @property
    def max_response_time(self) -> float:
        if not self.response_times:
            return 0.0
        return max(self.response_times)

    @property
    def p50_response_time(self) -> float:
        if not self.response_times:
            return 0.0
        return statistics.median(self.response_times)

    @property
    def p95_response_time(self) -> float:
        if not self.response_times:
            return 0.0
        sorted_times = sorted(self.response_times)
        index = int(len(sorted_times) * 0.95)
        return sorted_times[min(index, len(sorted_times) - 1)]

    @property
    def p99_response_time(self) -> float:
        if not self.response_times:
            return 0.0
        sorted_times = sorted(self.response_times)
        index = int(len(sorted_times) * 0.99)
        return sorted_times[min(index, len(sorted_times) - 1)]

    @property
    def qps(self) -> float:
        if not self.response_times:
            return 0.0
        total_time = sum(self.response_times)
        if total_time == 0:
            return 0.0
        return self.success_count / total_time


class ServerTester:
    """服务器测试器"""

    def __init__(self, url: str, timeout: int = 30):
        self.url = url
        self.timeout = timeout
        self.result = TestResult()
        self.result_lock = threading.Lock()
        self._stop_event = threading.Event()

    def make_request(self) -> bool:
        """发起单个请求"""
        start_time = time.time()
        try:
            req = urllib.request.Request(self.url)
            with urllib.request.urlopen(req, timeout=self.timeout) as response:
                response.read()
                elapsed = time.time() - start_time
                with self.result_lock:
                    self.result.success_count += 1
                    self.result.response_times.append(elapsed)
                return True
        except urllib.error.HTTPError as e:
            elapsed = time.time() - start_time
            with self.result_lock:
                self.result.fail_count += 1
                self.result.response_times.append(elapsed)
            return False
        except Exception:
            elapsed = time.time() - start_time
            with self.result_lock:
                self.result.fail_count += 1
                self.result.response_times.append(elapsed)
            return False

    def worker(self, worker_id: int):
        """工作线程"""
        while not self._stop_event.is_set():
            with self.result_lock:
                self.result.total_requests += 1
            self.make_request()

    def stress_test(self, threads: int, duration: int) -> TestResult:
        """
        压力测试 - 固定并发线程持续发送请求

        Args:
            threads: 并发线程数
            duration: 测试持续时间(秒)
        """
        self.result = TestResult()
        self._stop_event.clear()

        print(f"\n{'='*60}")
        print(f"压力测试开始")
        print(f"  目标地址: {self.url}")
        print(f"  并发线程: {threads}")
        print(f"  测试时长: {duration} 秒")
        print(f"{'='*60}\n")

        start_time = time.time()
        with ThreadPoolExecutor(max_workers=threads) as executor:
            futures = [executor.submit(self.worker, i) for i in range(threads)]

            while time.time() - start_time < duration:
                time.sleep(0.1)

            self._stop_event.set()
            for future in futures:
                future.result()

        elapsed = time.time() - start_time
        return self._generate_report(elapsed)

    def load_test(self, threads: int, total_requests: int) -> TestResult:
        """
        负载测试 - 固定总请求数

        Args:
            threads: 并发线程数
            total_requests: 总请求数
        """
        self.result = TestResult()
        self._stop_event.clear()

        print(f"\n{'='*60}")
        print(f"负载测试开始")
        print(f"  目标地址: {self.url}")
        print(f"  并发线程: {threads}")
        print(f"  总请求数: {total_requests}")
        print(f"{'='*60}\n")

        start_time = time.time()
        request_counter = 0

        with ThreadPoolExecutor(max_workers=threads) as executor:
            while request_counter < total_requests:
                futures = []
                batch_size = min(threads, total_requests - request_counter)
                for _ in range(batch_size):
                    futures.append(executor.submit(self.make_request))
                    request_counter += 1
                    with self.result_lock:
                        self.result.total_requests += 1

                for future in as_completed(futures):
                    future.result()

        elapsed = time.time() - start_time
        return self._generate_report(elapsed)

    def burst_test(self, threads: int, burst_requests: int, burst_interval: int, bursts: int) -> TestResult:
        """
        突发测试 - 模拟流量突增场景

        Args:
            threads: 每个波次的并发线程数
            burst_requests: 每个波次的请求数
            burst_interval: 波次间隔时间(秒)
            bursts: 波次数量
        """
        self.result = TestResult()
        self._stop_event.clear()

        print(f"\n{'='*60}")
        print(f"突发测试开始")
        print(f"  目标地址: {self.url}")
        print(f"  每波次并发: {threads}")
        print(f"  每波次请求: {burst_requests}")
        print(f"  波次间隔: {burst_interval} 秒")
        print(f"  波次数量: {bursts}")
        print(f"{'='*60}\n")

        start_time = time.time()
        for burst_num in range(bursts):
            print(f"  [波次 {burst_num + 1}/{bursts}] 开始...")
            burst_start = time.time()

            with ThreadPoolExecutor(max_workers=threads) as executor:
                futures = []
                for _ in range(burst_requests):
                    futures.append(executor.submit(self.make_request))
                    with self.result_lock:
                        self.result.total_requests += 1

                for future in as_completed(futures):
                    future.result()

            burst_elapsed = time.time() - burst_start
            print(f"  [波次 {burst_num + 1}/{bursts}] 完成, 耗时: {burst_elapsed:.2f}秒")

            if burst_num < bursts - 1:
                time.sleep(max(0, burst_interval - burst_elapsed))

        elapsed = time.time() - start_time
        return self._generate_report(elapsed)

    def _generate_report(self, elapsed: float) -> TestResult:
        """生成测试报告"""
        r = self.result
        print(f"\n{'='*60}")
        print(f"测试报告")
        print(f"{'='*60}")
        print(f"  总请求数:     {r.total_requests}")
        print(f"  成功请求:     {r.success_count}")
        print(f"  失败请求:     {r.fail_count}")
        print(f"  成功率:       {r.success_rate:.2f}%")
        print(f"  总耗时:       {elapsed:.2f} 秒")
        print(f"  平均QPS:      {r.qps:.2f} 请求/秒")
        print(f"{'-'*60}")
        print(f"响应时间统计 (秒)")
        print(f"  最小响应:     {r.min_response_time:.4f}s")
        print(f"  最大响应:     {r.max_response_time:.4f}s")
        print(f"  平均响应:     {r.avg_response_time:.4f}s")
        print(f"  P50(中位数):  {r.p50_response_time:.4f}s")
        print(f"  P95:          {r.p95_response_time:.4f}s")
        print(f"  P99:          {r.p99_response_time:.4f}s")
        print(f"{'='*60}\n")
        return self.result


def main():
    parser = argparse.ArgumentParser(
        description="服务器压力测试与并发测试工具",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  # 压力测试: 50线程, 持续60秒
  python server_tester.py --url http://localhost:8080/api/health --stress --threads 50 --duration 60

  # 负载测试: 20线程, 总共10000请求
  python server_tester.py --url http://localhost:8080/api/health --load --threads 20 --requests 10000

  # 突发测试: 30并发, 每波100请求, 间隔5秒, 共10波
  python server_tester.py --url http://localhost:8080/api/health --burst --threads 30 --burst-requests 100 --burst-interval 5 --bursts 10
        """
    )

    parser.add_argument("--url", "-u", required=True, help="测试目标URL")
    parser.add_argument("--timeout", "-t", type=int, default=30, help="请求超时时间(秒), 默认30")
    parser.add_argument("--method", "-m", default="GET", choices=["GET", "POST", "PUT", "DELETE"], help="HTTP请求方法")

    # 测试模式
    test_group = parser.add_argument_group("测试模式 (选择其一)")
    test_mode = test_group.add_mutually_exclusive_group(required=True)
    test_mode.add_argument("--stress", action="store_true", help="压力测试模式")
    test_mode.add_argument("--load", action="store_true", help="负载测试模式")
    test_mode.add_argument("--burst", action="store_true", help="突发测试模式")

    # 压力测试参数
    stress_group = parser.add_argument_group("压力测试参数")
    stress_group.add_argument("--threads", type=int, default=10, help="并发线程数, 默认10")
    stress_group.add_argument("--duration", type=int, default=60, help="测试持续时间(秒), 默认60")

    # 负载测试参数
    load_group = parser.add_argument_group("负载测试参数")
    load_group.add_argument("--requests", type=int, default=1000, help="总请求数, 默认1000")

    # 突发测试参数
    burst_group = parser.add_argument_group("突发测试参数")
    burst_group.add_argument("--burst-requests", type=int, default=100, help="每个波次的请求数, 默认100")
    burst_group.add_argument("--burst-interval", type=int, default=5, help="波次间隔(秒), 默认5")
    burst_group.add_argument("--bursts", type=int, default=10, help="波次数量, 默认10")

    args = parser.parse_args()

    # 创建测试器
    tester = ServerTester(args.url, args.timeout)

    try:
        if args.stress:
            tester.stress_test(args.threads, args.duration)
        elif args.load:
            tester.load_test(args.threads, args.requests)
        elif args.burst:
            tester.burst_test(args.threads, args.burst_requests, args.burst_interval, args.bursts)
    except KeyboardInterrupt:
        print("\n\n测试已取消")
        sys.exit(1)


if __name__ == "__main__":
    main()
