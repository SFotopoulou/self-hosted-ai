#!/usr/bin/env python3
"""
Concurrent load test for the Team AI stack via LiteLLM.

Uses only Python 3 stdlib. Reads defaults from environment variables or a .env file.

Examples:
  ./scripts/load-test.py
  ./scripts/load-test.py --concurrency 8 --requests 5
  LITELLM_API_KEY=sk-... ./scripts/load-test.py --base-url http://127.0.0.1:4000/v1
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import statistics
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any


DEFAULT_PROMPT = (
    "Explain what a binary search tree is in two short paragraphs. "
    "Include time complexity for search, insert, and delete."
)


@dataclass
class RequestResult:
    ok: bool
    status: int | None
    latency_s: float
    ttft_s: float | None
    completion_tokens: int
    error: str | None


def load_dotenv(path: Path) -> None:
    if not path.is_file():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        os.environ.setdefault(key, value)


def percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = int(round((pct / 100.0) * (len(ordered) - 1)))
    return ordered[index]


def build_payload(model: str, max_tokens: int, stream: bool) -> dict[str, Any]:
    return {
        "model": model,
        "messages": [{"role": "user", "content": DEFAULT_PROMPT}],
        "max_tokens": max_tokens,
        "temperature": 0.2,
        "stream": stream,
    }


def parse_usage(body: dict[str, Any]) -> int:
    usage = body.get("usage") or {}
    return int(usage.get("completion_tokens") or 0)


def run_request(
    *,
    base_url: str,
    api_key: str,
    model: str,
    max_tokens: int,
    stream: bool,
    timeout_s: float,
    request_id: int,
) -> RequestResult:
    url = f"{base_url.rstrip('/')}/chat/completions"
    payload = build_payload(model, max_tokens, stream)
    data = json.dumps(payload).encode("utf-8")
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_key}",
        "X-Request-Id": f"load-test-{request_id}",
    }

    start = time.perf_counter()
    ttft: float | None = None
    completion_tokens = 0

    try:
        request = urllib.request.Request(url, data=data, headers=headers, method="POST")
        with urllib.request.urlopen(request, timeout=timeout_s) as response:
            status = response.status
            if stream:
                first_chunk = True
                for raw_line in response:
                    line = raw_line.decode("utf-8", errors="replace").strip()
                    if not line.startswith("data: "):
                        continue
                    chunk = line[6:]
                    if chunk == "[DONE]":
                        break
                    if first_chunk:
                        ttft = time.perf_counter() - start
                        first_chunk = False
                    try:
                        event = json.loads(chunk)
                    except json.JSONDecodeError:
                        continue
                    delta = (
                        event.get("choices", [{}])[0]
                        .get("delta", {})
                        .get("content")
                    )
                    if delta:
                        completion_tokens += max(1, len(delta.split()))
                latency = time.perf_counter() - start
                return RequestResult(
                    ok=True,
                    status=status,
                    latency_s=latency,
                    ttft_s=ttft,
                    completion_tokens=completion_tokens,
                    error=None,
                )

            body = json.loads(response.read().decode("utf-8"))
            latency = time.perf_counter() - start
            completion_tokens = parse_usage(body)
            return RequestResult(
                ok=True,
                status=status,
                latency_s=latency,
                ttft_s=latency,
                completion_tokens=completion_tokens,
                error=None,
            )
    except urllib.error.HTTPError as exc:
        latency = time.perf_counter() - start
        detail = exc.read().decode("utf-8", errors="replace")[:300]
        return RequestResult(
            ok=False,
            status=exc.code,
            latency_s=latency,
            ttft_s=None,
            completion_tokens=0,
            error=f"HTTP {exc.code}: {detail}",
        )
    except Exception as exc:  # noqa: BLE001 - report all failures in summary
        latency = time.perf_counter() - start
        return RequestResult(
            ok=False,
            status=None,
            latency_s=latency,
            ttft_s=None,
            completion_tokens=0,
            error=str(exc),
        )


def wait_for_health(base_url: str, api_key: str, timeout_s: float) -> None:
    health_url = base_url.rstrip("/").replace("/v1", "") + "/health/liveliness"
    deadline = time.time() + timeout_s
    headers = {"Authorization": f"Bearer {api_key}"}

    while time.time() < deadline:
        try:
            request = urllib.request.Request(health_url, headers=headers, method="GET")
            with urllib.request.urlopen(request, timeout=5) as response:
                if response.status == 200:
                    return
        except Exception:
            pass
        time.sleep(2)

    raise SystemExit(f"LiteLLM health check failed: {health_url}")


def print_summary(results: list[RequestResult], wall_s: float, concurrency: int) -> int:
    successes = [r for r in results if r.ok]
    failures = [r for r in results if not r.ok]
    latencies = [r.latency_s for r in successes]
    ttfts = [r.ttft_s for r in successes if r.ttft_s is not None]
    tokens = sum(r.completion_tokens for r in successes)

    print("")
    print("=" * 60)
    print("LOAD TEST SUMMARY")
    print("=" * 60)
    print(f"Total requests:     {len(results)}")
    print(f"Concurrency:        {concurrency}")
    print(f"Successful:         {len(successes)}")
    print(f"Failed:             {len(failures)}")
    print(f"Success rate:       {100.0 * len(successes) / len(results):.1f}%")
    print(f"Wall time:          {wall_s:.2f}s")
    print(f"Throughput:         {len(successes) / wall_s:.2f} req/s")
    print(f"Completion tokens:  {tokens}")
    if wall_s > 0 and tokens > 0:
        print(f"Approx tokens/s:    {tokens / wall_s:.1f}")

    if latencies:
        print("")
        print("Latency (seconds)")
        print(f"  mean:  {statistics.mean(latencies):.2f}")
        print(f"  p50:   {percentile(latencies, 50):.2f}")
        print(f"  p95:   {percentile(latencies, 95):.2f}")
        print(f"  p99:   {percentile(latencies, 99):.2f}")
        print(f"  max:   {max(latencies):.2f}")

    if ttfts:
        print("")
        print("Time to first token (seconds)")
        print(f"  mean:  {statistics.mean(ttfts):.2f}")
        print(f"  p50:   {percentile(ttfts, 50):.2f}")
        print(f"  p95:   {percentile(ttfts, 95):.2f}")
        print(f"  max:   {max(ttfts):.2f}")

    if failures:
        print("")
        print("Failures")
        status_counts: dict[str, int] = {}
        for result in failures:
            label = str(result.status) if result.status is not None else "error"
            status_counts[label] = status_counts.get(label, 0) + 1
        for label, count in sorted(status_counts.items()):
            print(f"  {label}: {count}")
        print("")
        print("Sample errors:")
        for result in failures[:3]:
            print(f"  - {result.error}")

    print("")
    print("Suggested acceptance thresholds (A6000 + Gemma 4 31B QAT)")
    print("  success rate >= 95%")
    print("  p95 latency <= 60s for short prompts")
    print("  HTTP 429 count should be 0 unless testing rate limits")
    print("=" * 60)

    if len(successes) / len(results) < 0.95:
        return 1
    if latencies and percentile(latencies, 95) > 60:
        return 1
    return 0


def parse_args() -> argparse.Namespace:
    repo_dir = Path(__file__).resolve().parent.parent
    load_dotenv(repo_dir / ".env")

    parser = argparse.ArgumentParser(description="Load test the Team AI LiteLLM endpoint")
    parser.add_argument(
        "--base-url",
        default=os.environ.get("LITELLM_BASE_URL", "http://127.0.0.1:4000/v1"),
        help="LiteLLM OpenAI-compatible base URL",
    )
    parser.add_argument(
        "--api-key",
        default=os.environ.get("LITELLM_API_KEY") or os.environ.get("LITELLM_MASTER_KEY", ""),
        help="LiteLLM API key (defaults to LITELLM_MASTER_KEY from .env)",
    )
    parser.add_argument(
        "--model",
        default=os.environ.get("LOAD_TEST_MODEL", "gemma-4-31b"),
        help="Model alias configured in LiteLLM",
    )
    parser.add_argument(
        "--concurrency",
        type=int,
        default=int(os.environ.get("LOAD_TEST_CONCURRENCY", "8")),
        help="Number of parallel workers",
    )
    parser.add_argument(
        "--requests",
        type=int,
        default=int(os.environ.get("LOAD_TEST_REQUESTS_PER_WORKER", "3")),
        help="Requests per worker",
    )
    parser.add_argument(
        "--max-tokens",
        type=int,
        default=int(os.environ.get("LOAD_TEST_MAX_TOKENS", "256")),
        help="max_tokens per request",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=float(os.environ.get("LOAD_TEST_TIMEOUT", "180")),
        help="Per-request timeout in seconds",
    )
    parser.add_argument(
        "--stream",
        action="store_true",
        default=os.environ.get("LOAD_TEST_STREAM", "").lower() in {"1", "true", "yes"},
        help="Use streaming responses (measures TTFT)",
    )
    parser.add_argument(
        "--skip-health-check",
        action="store_true",
        help="Do not wait for LiteLLM /health/liveliness before testing",
    )
    parser.add_argument(
        "--warmup",
        action="store_true",
        default=True,
        help="Send one warmup request before the load test (default: on)",
    )
    parser.add_argument(
        "--no-warmup",
        action="store_false",
        dest="warmup",
        help="Skip warmup request",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    if not args.api_key:
        print("Error: set LITELLM_MASTER_KEY in .env or pass --api-key", file=sys.stderr)
        return 2

    total_requests = args.concurrency * args.requests
    print("Team AI load test")
    print(f"  base url:     {args.base_url}")
    print(f"  model:        {args.model}")
    print(f"  concurrency:  {args.concurrency}")
    print(f"  requests:     {total_requests} ({args.requests} per worker)")
    print(f"  max tokens:   {args.max_tokens}")
    print(f"  streaming:    {args.stream}")

    if not args.skip_health_check:
        print("Waiting for LiteLLM health check ...")
        wait_for_health(args.base_url, args.api_key, timeout_s=30)

    if args.warmup:
        print("Warmup request ...")
        warmup = run_request(
            base_url=args.base_url,
            api_key=args.api_key,
            model=args.model,
            max_tokens=min(32, args.max_tokens),
            stream=False,
            timeout_s=args.timeout,
            request_id=0,
        )
        if not warmup.ok:
            print(f"Warmup failed: {warmup.error}", file=sys.stderr)
            return 2
        print(f"Warmup OK ({warmup.latency_s:.2f}s)")

    print("Running load test ...")
    started = time.perf_counter()
    results: list[RequestResult] = []

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        futures = []
        request_id = 1
        for worker in range(args.concurrency):
            for _ in range(args.requests):
                futures.append(
                    pool.submit(
                        run_request,
                        base_url=args.base_url,
                        api_key=args.api_key,
                        model=args.model,
                        max_tokens=args.max_tokens,
                        stream=args.stream,
                        timeout_s=args.timeout,
                        request_id=request_id,
                    )
                )
                request_id += 1

        for future in concurrent.futures.as_completed(futures):
            results.append(future.result())

    wall_s = time.perf_counter() - started
    return print_summary(results, wall_s, args.concurrency)


if __name__ == "__main__":
    raise SystemExit(main())
