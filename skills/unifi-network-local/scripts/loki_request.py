#!/usr/bin/env python3
"""Generic Grafana Loki API client using optional bearer token authentication."""

from __future__ import annotations

import argparse
import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, TextIO


READ_ONLY_METHODS = {"GET", "HEAD", "OPTIONS"}


# Parses CLI arguments for raw Loki API requests.
def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Send a request to a local Grafana Loki endpoint."
    )
    parser.add_argument("method", help="HTTP method, for example GET")
    parser.add_argument("path", help="API path beginning with /")
    parser.add_argument(
        "--base-url",
        default=os.environ.get("LOKI_BASE_URL"),
        help="Loki base URL. Defaults to LOKI_BASE_URL.",
    )
    parser.add_argument(
        "--api-key",
        default=os.environ.get("LOKI_API_KEY"),
        help="Optional bearer token. Defaults to LOKI_API_KEY.",
    )
    parser.add_argument(
        "--query",
        action="append",
        default=[],
        metavar="KEY=VALUE",
        help="Add a query parameter. Repeat as needed.",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=25,
        help="Request timeout in seconds. Default: 25.",
    )
    parser.add_argument(
        "--insecure",
        action="store_true",
        help="Disable TLS certificate verification for self-signed local certs.",
    )
    parser.add_argument(
        "--allow-write",
        action="store_true",
        help="Permit non-read-only methods such as POST or DELETE.",
    )
    return parser.parse_args()


# Returns a required value or exits with a helpful error when it is missing.
def require(value: str | None, env_name: str) -> str:
    if value:
        return value
    raise SystemExit(f"missing required value: set {env_name} or pass the matching flag")


# Parses repeated key=value query arguments into URL query tuples.
def parse_query(items: list[str]) -> list[tuple[str, str]]:
    pairs: list[tuple[str, str]] = []
    for item in items:
        if "=" not in item:
            raise SystemExit(f"invalid query parameter {item!r}; expected KEY=VALUE")
        key, value = item.split("=", 1)
        pairs.append((key, value))
    return pairs


# Builds the final request URL from the base URL, path, and query items.
def build_url(base_url: str, path: str, query_items: list[tuple[str, str]]) -> str:
    if not path.startswith("/"):
        raise SystemExit("path must begin with '/'")
    base_url = base_url.rstrip("/")
    url = f"{base_url}{path}"
    if query_items:
        url = f"{url}?{urllib.parse.urlencode(query_items)}"
    return url


# Builds an SSL context that optionally allows self-signed certificates.
def build_context(insecure: bool) -> ssl.SSLContext | None:
    if not insecure:
        return None
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    return context


# Pretty-prints a JSON response body, or falls back to raw text.
def print_response(body: bytes, stream: TextIO = sys.stdout) -> None:
    text = body.decode("utf-8", errors="replace")
    try:
        parsed: Any = json.loads(text)
    except json.JSONDecodeError:
        stream.write(text)
        if not text.endswith("\n"):
            stream.write("\n")
        return
    json.dump(parsed, stream, indent=2, sort_keys=True)
    stream.write("\n")


# Dispatches the raw Loki request CLI flow.
def main() -> int:
    args = parse_args()
    method = args.method.upper()
    if method not in READ_ONLY_METHODS and not args.allow_write:
        raise SystemExit(
            f"{method} is blocked by default; re-run with --allow-write after explicit user approval"
        )

    base_url = require(args.base_url, "LOKI_BASE_URL")
    api_key = (args.api_key or "").strip()
    query_items = parse_query(args.query)
    url = build_url(base_url, args.path, query_items)

    headers = {"Accept": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

    request = urllib.request.Request(url=url, headers=headers, method=method)
    context = build_context(args.insecure)

    try:
        with urllib.request.urlopen(request, timeout=args.timeout, context=context) as response:
            print_response(response.read())
            return 0
    except urllib.error.HTTPError as exc:
        error_body = exc.read()
        sys.stderr.write(f"HTTP {exc.code} {exc.reason}\n")
        if error_body:
            print_response(error_body, stream=sys.stderr)
        return 1
    except urllib.error.URLError as exc:
        sys.stderr.write(f"request failed: {exc.reason}\n")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

