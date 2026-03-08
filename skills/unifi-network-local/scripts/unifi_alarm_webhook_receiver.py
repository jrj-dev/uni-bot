#!/usr/bin/env python3
"""Simple UniFi Alarm Manager webhook receiver that forwards events to Loki."""

from __future__ import annotations

import argparse
import json
import os
import re
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


LABEL_SAFE_RE = re.compile(r"[^a-zA-Z0-9_]")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Receive UniFi Alarm Manager webhook events and push them to Loki."
    )
    parser.add_argument(
        "--bind",
        default=os.environ.get("UNIFI_ALARM_WEBHOOK_BIND", "0.0.0.0"),
        help="Bind address. Default: UNIFI_ALARM_WEBHOOK_BIND or 0.0.0.0",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=int(os.environ.get("UNIFI_ALARM_WEBHOOK_PORT", "8787")),
        help="Bind port. Default: UNIFI_ALARM_WEBHOOK_PORT or 8787",
    )
    parser.add_argument(
        "--path",
        default=os.environ.get("UNIFI_ALARM_WEBHOOK_PATH", "/webhook/unifi/alarm"),
        help="Webhook path. Default: UNIFI_ALARM_WEBHOOK_PATH or /webhook/unifi/alarm",
    )
    parser.add_argument(
        "--secret",
        default=os.environ.get("UNIFI_ALARM_WEBHOOK_SECRET", ""),
        help="Optional shared secret. If set, inbound request must provide it.",
    )
    parser.add_argument(
        "--loki-base-url",
        default=os.environ.get("LOKI_BASE_URL", ""),
        help="Loki base URL. Defaults to LOKI_BASE_URL.",
    )
    parser.add_argument(
        "--loki-api-key",
        default=os.environ.get("LOKI_API_KEY", ""),
        help="Optional Loki bearer token. Defaults to LOKI_API_KEY.",
    )
    parser.add_argument(
        "--loki-job",
        default=os.environ.get("UNIFI_ALARM_LOKI_JOB", "unifi_alarm_manager"),
        help="Loki job label. Default: UNIFI_ALARM_LOKI_JOB or unifi_alarm_manager",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=15,
        help="Loki request timeout in seconds. Default: 15",
    )
    parser.add_argument(
        "--insecure",
        action="store_true",
        help="Disable TLS verification for self-signed Loki endpoints.",
    )
    return parser.parse_args()


def sanitize_label(value: Any, fallback: str = "unknown") -> str:
    text = str(value).strip()
    if not text:
        return fallback
    return LABEL_SAFE_RE.sub("_", text.lower())[:120] or fallback


def build_context(insecure: bool) -> ssl.SSLContext | None:
    if not insecure:
        return None
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    return context


def normalize_loki_push_url(raw_base_url: str) -> str:
    base = (raw_base_url or "").strip().strip("'").strip('"')
    if not base:
        raise ValueError("LOKI_BASE_URL is empty")
    parsed = urllib.parse.urlparse(base)
    if parsed.scheme not in {"http", "https"}:
        raise ValueError("LOKI_BASE_URL must include http:// or https://")
    if not parsed.netloc:
        raise ValueError("LOKI_BASE_URL missing host")

    path = parsed.path.rstrip("/")
    if path.endswith("/loki/api/v1/push"):
        push_path = path
    elif path.endswith("/loki/api/v1"):
        push_path = path + "/push"
    elif path.endswith("/loki"):
        push_path = path + "/api/v1/push"
    elif path:
        push_path = path + "/loki/api/v1/push"
    else:
        push_path = "/loki/api/v1/push"

    return urllib.parse.urlunparse(
        (parsed.scheme, parsed.netloc, push_path, "", "", "")
    )


def candidate_loki_push_urls(raw_base_url: str) -> list[str]:
    primary = normalize_loki_push_url(raw_base_url)
    parsed = urllib.parse.urlparse(primary)
    host = (parsed.hostname or "").lower()
    candidates = [primary]

    # Docker containers often cannot resolve mDNS .local hostnames.
    # Provide a pragmatic fallback for local Docker Desktop networking.
    if host.endswith(".local"):
        fallback_netloc = "host.docker.internal"
        if parsed.port:
            fallback_netloc = f"{fallback_netloc}:{parsed.port}"
        fallback = urllib.parse.urlunparse(
            (parsed.scheme, fallback_netloc, parsed.path, "", "", "")
        )
        candidates.append(fallback)
    return candidates


@dataclass
class AppConfig:
    path: str
    secret: str
    loki_base_url: str
    loki_api_key: str
    loki_job: str
    timeout: int
    insecure: bool


def push_to_loki(config: AppConfig, payload: dict[str, Any]) -> None:
    if not config.loki_base_url:
        raise RuntimeError("LOKI_BASE_URL is required")

    event_type = (
        payload.get("alarmType")
        or payload.get("type")
        or payload.get("eventType")
        or "unknown"
    )
    severity = payload.get("severity") or payload.get("level") or "unknown"
    site = payload.get("siteId") or payload.get("site_id") or payload.get("site") or "unknown"
    host = payload.get("host") or payload.get("console") or "unknown"

    labels = {
        "job": sanitize_label(config.loki_job, fallback="unifi_alarm_manager"),
        "source": "unifi_alarm_manager",
        "event_type": sanitize_label(event_type),
        "severity": sanitize_label(severity),
        "site": sanitize_label(site),
        "host": sanitize_label(host),
    }
    line = json.dumps(payload, separators=(",", ":"), sort_keys=True)
    ts_ns = str(time.time_ns())
    loki_payload = {"streams": [{"stream": labels, "values": [[ts_ns, line]]}]}

    urls = candidate_loki_push_urls(config.loki_base_url)
    body = json.dumps(loki_payload, separators=(",", ":")).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    if config.loki_api_key.strip():
        headers["Authorization"] = f"Bearer {config.loki_api_key.strip()}"

    context = build_context(config.insecure)
    last_error: Exception | None = None
    for url in urls:
        request = urllib.request.Request(url=url, data=body, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(request, timeout=config.timeout, context=context) as response:
                status = getattr(response, "status", 200)
                if status < 200 or status >= 300:
                    raise RuntimeError(f"Loki push failed with HTTP {status}")
            return
        except Exception as exc:  # noqa: BLE001
            last_error = exc
            continue
    if last_error is not None:
        raise last_error
    raise RuntimeError("Loki push failed for unknown reason")


def is_authorized(handler: BaseHTTPRequestHandler, secret: str) -> bool:
    if not secret:
        return True
    token = (
        handler.headers.get("X-UniFi-Webhook-Secret")
        or handler.headers.get("X-Webhook-Secret")
        or handler.headers.get("X-Api-Key")
        or ""
    ).strip()
    if not token:
        auth = (handler.headers.get("Authorization") or "").strip()
        if auth.lower().startswith("bearer "):
            token = auth[7:].strip()
    return token == secret


def make_handler(config: AppConfig):
    class WebhookHandler(BaseHTTPRequestHandler):
        def do_POST(self) -> None:  # noqa: N802
            if self.path != config.path:
                self.send_response(404)
                self.end_headers()
                return

            if not is_authorized(self, config.secret):
                self.send_response(401)
                self.end_headers()
                self.wfile.write(b"unauthorized\n")
                return

            length_header = self.headers.get("Content-Length", "").strip()
            if not length_header.isdigit():
                self.send_response(400)
                self.end_headers()
                self.wfile.write(b"missing/invalid Content-Length\n")
                return
            length = int(length_header)
            raw = self.rfile.read(length)
            try:
                payload = json.loads(raw.decode("utf-8", errors="replace"))
            except json.JSONDecodeError:
                self.send_response(400)
                self.end_headers()
                self.wfile.write(b"invalid JSON\n")
                return
            if not isinstance(payload, dict):
                self.send_response(400)
                self.end_headers()
                self.wfile.write(b"JSON object expected\n")
                return

            try:
                push_to_loki(config, payload)
            except urllib.error.HTTPError as exc:
                details = exc.read().decode("utf-8", errors="replace")
                sys.stderr.write(f"[alarm-webhook] Loki HTTP {exc.code}: {details}\n")
                self.send_response(502)
                self.end_headers()
                self.wfile.write(b"loki push failed\n")
                return
            except Exception as exc:  # noqa: BLE001
                safe_loki = (config.loki_base_url or "").strip()
                sys.stderr.write(
                    f"[alarm-webhook] push error: {exc} (loki_base_url={safe_loki})\n"
                )
                self.send_response(502)
                self.end_headers()
                self.wfile.write(b"loki push failed\n")
                return

            self.send_response(202)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{\"ok\":true}\n')

        def log_message(self, format: str, *args) -> None:  # noqa: A003
            sys.stderr.write(f"[alarm-webhook] {self.address_string()} - {format % args}\n")

    return WebhookHandler


def main() -> int:
    args = parse_args()
    config = AppConfig(
        path=args.path,
        secret=(args.secret or "").strip(),
        loki_base_url=(args.loki_base_url or "").strip(),
        loki_api_key=(args.loki_api_key or "").strip(),
        loki_job=args.loki_job,
        timeout=args.timeout,
        insecure=args.insecure,
    )
    if not config.path.startswith("/"):
        raise SystemExit("--path must start with '/'")
    if not config.loki_base_url:
        raise SystemExit("missing required value: set LOKI_BASE_URL or pass --loki-base-url")

    server = ThreadingHTTPServer((args.bind, args.port), make_handler(config))
    print(
        f"Listening on http://{args.bind}:{args.port}{config.path} "
        f"(loki={config.loki_base_url.rstrip('/')}/loki/api/v1/push)"
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
