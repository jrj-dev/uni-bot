#!/usr/bin/env python3
"""Poll UniFi Network events and forward them to Loki."""

from __future__ import annotations

import hashlib
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import deque
from typing import Any


def print_help() -> None:
    print(
        """UniFi event poller environment variables:

Required:
  UNIFI_BASE_URL
  UNIFI_API_KEY
  LOKI_BASE_URL

Optional:
  LOKI_API_KEY
  UNIFI_EVENT_PATH (single path override; optional)
  UNIFI_EVENT_PATHS (comma-separated path overrides; optional)
  UNIFI_SITE_REF (default: default)
  UNIFI_SITE_ID (optional; used for integration v1 fallback path)
  UNIFI_EVENT_LIMIT (default: 50)
  UNIFI_POLL_INTERVAL_SECONDS (default: 30)
  UNIFI_EVENT_TIMEOUT_SECONDS (default: 20)
  UNIFI_EVENT_LOKI_JOB (default: unifi_siem)
  UNIFI_EVENT_USE_CURSOR (default: true)
  UNIFI_EVENT_CURSOR_OVERLAP_SECONDS (default: 5)
  UNIFI_BACKFILL_ON_START (default: false)
  UNIFI_BACKFILL_HOURS (default: 24)
  UNIFI_BACKFILL_LIMIT (default: 1000)
  UNIFI_INSECURE (default: true)
  LOKI_INSECURE (default: false)
"""
    )


def env_bool(name: str, default: bool = False) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def require_env(name: str) -> str:
    value = (os.environ.get(name) or "").strip()
    if not value:
        raise SystemExit(f"missing required env var: {name}")
    return value


def optional_ssl_context(insecure: bool) -> ssl.SSLContext | None:
    if not insecure:
        return None
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    return context


def normalize_loki_push_url(base_url: str) -> str:
    parsed = urllib.parse.urlparse(base_url.strip().strip("'").strip('"'))
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise SystemExit("invalid LOKI_BASE_URL; expected http(s)://host[:port]")
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
    return urllib.parse.urlunparse((parsed.scheme, parsed.netloc, push_path, "", "", ""))


def normalize_unifi_url_or_path(value: str, unifi_base: str) -> str:
    value = value.strip()
    if not value:
        return ""
    parsed = urllib.parse.urlparse(value)
    if parsed.scheme in {"http", "https"} and parsed.netloc:
        return value
    if not value.startswith("/"):
        value = f"/{value}"
    return f"{unifi_base}{value}"


def with_limit(url: str, limit: int) -> str:
    parsed = urllib.parse.urlparse(url)
    query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
    if "limit" not in query:
        query["limit"] = [str(max(1, limit))]
    encoded = urllib.parse.urlencode(query, doseq=True)
    return urllib.parse.urlunparse(
        (parsed.scheme, parsed.netloc, parsed.path, parsed.params, encoded, parsed.fragment)
    )


def with_query_params(url: str, params: list[tuple[str, str]]) -> str:
    parsed = urllib.parse.urlparse(url)
    query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
    for key, value in params:
        query[key] = [value]
    encoded = urllib.parse.urlencode(query, doseq=True)
    return urllib.parse.urlunparse(
        (parsed.scheme, parsed.netloc, parsed.path, parsed.params, encoded, parsed.fragment)
    )


def event_fingerprint(event: dict[str, Any]) -> str:
    for key in ("id", "_id", "eventId", "event_id", "uuid"):
        value = event.get(key)
        if isinstance(value, str) and value:
            return value
    stable = json.dumps(event, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(stable).hexdigest()


def extract_event_rows(payload: Any) -> list[dict[str, Any]]:
    if isinstance(payload, list):
        return [item for item in payload if isinstance(item, dict)]
    if isinstance(payload, dict):
        for key in ("data", "items", "events"):
            rows = payload.get(key)
            if isinstance(rows, list):
                return [item for item in rows if isinstance(item, dict)]
        # Some endpoints may return a single event object.
        if payload:
            return [payload]
    return []


def fetch_events(
    *,
    unifi_url: str,
    unifi_api_key: str,
    timeout: int,
    insecure: bool,
) -> list[dict[str, Any]]:
    headers = {
        "Accept": "application/json",
        "X-API-Key": unifi_api_key,
    }
    request = urllib.request.Request(url=unifi_url, method="GET", headers=headers)
    context = optional_ssl_context(insecure)
    with urllib.request.urlopen(request, timeout=timeout, context=context) as response:
        raw = response.read().decode("utf-8", errors="replace")
    payload = json.loads(raw)
    return extract_event_rows(payload)


def fetch_sites(
    *,
    unifi_base: str,
    unifi_api_key: str,
    timeout: int,
    insecure: bool,
) -> list[dict[str, Any]]:
    url = f"{unifi_base}/proxy/network/integration/v1/sites"
    headers = {
        "Accept": "application/json",
        "X-API-Key": unifi_api_key,
    }
    request = urllib.request.Request(url=url, method="GET", headers=headers)
    context = optional_ssl_context(insecure)
    with urllib.request.urlopen(request, timeout=timeout, context=context) as response:
        raw = response.read().decode("utf-8", errors="replace")
    payload = json.loads(raw)
    if isinstance(payload, dict):
        rows = payload.get("data")
        if isinstance(rows, list):
            return [item for item in rows if isinstance(item, dict)]
    return []


def resolve_site_id(
    *,
    unifi_base: str,
    unifi_api_key: str,
    timeout: int,
    insecure: bool,
    site_ref: str,
) -> str | None:
    rows = fetch_sites(
        unifi_base=unifi_base,
        unifi_api_key=unifi_api_key,
        timeout=timeout,
        insecure=insecure,
    )
    for row in rows:
        if row.get("internalReference") == site_ref:
            site_id = row.get("id")
            if isinstance(site_id, str) and site_id:
                return site_id
    return None


def candidate_event_urls(
    *,
    unifi_base: str,
    event_path: str,
    event_paths_raw: str,
    event_limit: int,
    site_ref: str,
    site_id: str,
) -> list[str]:
    ordered: list[str] = []

    def add(candidate: str) -> None:
        normalized = normalize_unifi_url_or_path(candidate, unifi_base)
        if not normalized:
            return
        normalized = with_limit(normalized, event_limit)
        if normalized not in ordered:
            ordered.append(normalized)

    if event_paths_raw.strip():
        for item in event_paths_raw.split(","):
            add(item)
    if event_path.strip():
        add(event_path)

    # Common UniFi variants observed across local controller versions.
    add(f"/proxy/network/v2/api/site/{site_ref}/event")
    add(f"/proxy/network/v2/api/site/{site_ref}/events")
    add(f"/proxy/network/v2/site/{site_ref}/event")
    add(f"/proxy/network/v2/site/{site_ref}/events")
    if site_id:
        add(f"/proxy/network/v2/api/site/{site_id}/event")
        add(f"/proxy/network/v2/api/site/{site_id}/events")
        add(f"/proxy/network/v2/site/{site_id}/event")
        add(f"/proxy/network/v2/site/{site_id}/events")
        add(f"/proxy/network/integration/v1/sites/{site_id}/events")
    add(f"/proxy/network/integration/v1/sites/{site_ref}/events")

    return ordered


def discover_working_event_url(
    *,
    candidates: list[str],
    unifi_api_key: str,
    timeout: int,
    insecure: bool,
) -> tuple[str, list[dict[str, Any]]]:
    last_error: Exception | None = None
    for url in candidates:
        try:
            rows = fetch_events(
                unifi_url=url,
                unifi_api_key=unifi_api_key,
                timeout=timeout,
                insecure=insecure,
            )
            print(f"[unifi-event-poller] selected event endpoint: {url}")
            return url, rows
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                print(f"[unifi-event-poller] endpoint not found (404): {url}")
                last_error = exc
                continue
            details = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"HTTP {exc.code} on {url}: {details[:240]}") from exc
        except Exception as exc:  # noqa: BLE001
            last_error = exc
            continue

    if last_error is not None:
        raise RuntimeError(f"no working UniFi event endpoint found; last error: {last_error}")
    raise RuntimeError("no UniFi event endpoint candidates were configured")


def fetch_backfill_events(
    *,
    selected_unifi_url: str,
    unifi_api_key: str,
    timeout: int,
    insecure: bool,
    hours: int,
    limit: int,
) -> list[dict[str, Any]]:
    now = int(time.time())
    start = max(0, now - max(1, hours) * 3600)
    now_ms = now * 1000
    start_ms = start * 1000

    candidates = [
        with_query_params(selected_unifi_url, [("start", str(start_ms)), ("end", str(now_ms)), ("limit", str(max(1, limit)))]),
        with_query_params(selected_unifi_url, [("_start", str(start)), ("_end", str(now)), ("_limit", str(max(1, limit)))]),
        with_query_params(selected_unifi_url, [("start", str(start)), ("end", str(now)), ("limit", str(max(1, limit)))]),
    ]

    for candidate in candidates:
        try:
            rows = fetch_events(
                unifi_url=candidate,
                unifi_api_key=unifi_api_key,
                timeout=timeout,
                insecure=insecure,
            )
            print(f"[unifi-event-poller] backfill endpoint selected: {candidate}")
            return rows
        except urllib.error.HTTPError as exc:
            details = exc.read().decode("utf-8", errors="replace")
            print(
                f"[unifi-event-poller] backfill HTTP {exc.code} on {candidate}: {details[:180]}",
                file=sys.stderr,
            )
        except Exception as exc:  # noqa: BLE001
            print(f"[unifi-event-poller] backfill attempt failed on {candidate}: {exc}", file=sys.stderr)
    return []


def fetch_events_since(
    *,
    selected_unifi_url: str,
    unifi_api_key: str,
    timeout: int,
    insecure: bool,
    start_s: int,
    end_s: int,
    limit: int,
    mode_hint: str,
) -> tuple[list[dict[str, Any]], str]:
    start_ms = start_s * 1000
    end_ms = end_s * 1000
    mode_params: dict[str, list[tuple[str, str]]] = {
        "ms": [("start", str(start_ms)), ("end", str(end_ms)), ("limit", str(max(1, limit)))],
        "underscore_sec": [("_start", str(start_s)), ("_end", str(end_s)), ("_limit", str(max(1, limit)))],
        "sec": [("start", str(start_s)), ("end", str(end_s)), ("limit", str(max(1, limit)))],
    }
    modes = ["ms", "underscore_sec", "sec"]
    if mode_hint in mode_params:
        modes = [mode_hint] + [m for m in modes if m != mode_hint]

    last_error: Exception | None = None
    for mode in modes:
        url = with_query_params(selected_unifi_url, mode_params[mode])
        try:
            rows = fetch_events(
                unifi_url=url,
                unifi_api_key=unifi_api_key,
                timeout=timeout,
                insecure=insecure,
            )
            return rows, mode
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                last_error = exc
                continue
            details = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"HTTP {exc.code} on {url}: {details[:200]}") from exc
        except Exception as exc:  # noqa: BLE001
            last_error = exc
            continue

    if last_error is not None:
        return [], ""
    return [], ""


def push_events_to_loki(
    *,
    events: list[dict[str, Any]],
    loki_push_url: str,
    loki_api_key: str,
    timeout: int,
    insecure: bool,
    job_label: str,
) -> None:
    if not events:
        return
    now_ns = time.time_ns()
    values: list[list[str]] = []
    for index, event in enumerate(events):
        ts_ns = str(now_ns + index)
        values.append([ts_ns, json.dumps(event, sort_keys=True, separators=(",", ":"))])

    payload = {
        "streams": [
            {
                "stream": {
                    "job": job_label,
                    "source": "unifi_event_poller",
                },
                "values": values,
            }
        ]
    }
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    if loki_api_key:
        headers["Authorization"] = f"Bearer {loki_api_key}"

    request = urllib.request.Request(
        url=loki_push_url,
        method="POST",
        data=body,
        headers=headers,
    )
    context = optional_ssl_context(insecure)
    with urllib.request.urlopen(request, timeout=timeout, context=context) as response:
        status = getattr(response, "status", 200)
        if status < 200 or status >= 300:
            raise RuntimeError(f"Loki push failed with HTTP {status}")


def main() -> int:
    if any(arg in {"-h", "--help"} for arg in sys.argv[1:]):
        print_help()
        return 0

    unifi_base = require_env("UNIFI_BASE_URL").rstrip("/")
    unifi_api_key = require_env("UNIFI_API_KEY")
    loki_base = require_env("LOKI_BASE_URL")
    loki_api_key = (os.environ.get("LOKI_API_KEY") or "").strip()

    event_path = (os.environ.get("UNIFI_EVENT_PATH") or "").strip()
    event_paths_raw = (os.environ.get("UNIFI_EVENT_PATHS") or "").strip()
    site_ref = (os.environ.get("UNIFI_SITE_REF") or "default").strip() or "default"
    site_id = (os.environ.get("UNIFI_SITE_ID") or "").strip()
    event_limit = int((os.environ.get("UNIFI_EVENT_LIMIT") or "50").strip() or "50")
    interval_seconds = float((os.environ.get("UNIFI_POLL_INTERVAL_SECONDS") or "30").strip() or "30")
    timeout_seconds = int((os.environ.get("UNIFI_EVENT_TIMEOUT_SECONDS") or "20").strip() or "20")
    unifi_insecure = env_bool("UNIFI_INSECURE", default=True)
    loki_insecure = env_bool("LOKI_INSECURE", default=False)
    loki_job = (os.environ.get("UNIFI_EVENT_LOKI_JOB") or "unifi_siem").strip()
    use_cursor = env_bool("UNIFI_EVENT_USE_CURSOR", default=True)
    cursor_overlap_seconds = int((os.environ.get("UNIFI_EVENT_CURSOR_OVERLAP_SECONDS") or "5").strip() or "5")
    backfill_on_start = env_bool("UNIFI_BACKFILL_ON_START", default=False)
    backfill_hours = int((os.environ.get("UNIFI_BACKFILL_HOURS") or "24").strip() or "24")
    backfill_limit = int((os.environ.get("UNIFI_BACKFILL_LIMIT") or "1000").strip() or "1000")

    if interval_seconds <= 0:
        raise SystemExit("UNIFI_POLL_INTERVAL_SECONDS must be > 0")

    if not site_id:
        try:
            resolved = resolve_site_id(
                unifi_base=unifi_base,
                unifi_api_key=unifi_api_key,
                timeout=timeout_seconds,
                insecure=unifi_insecure,
                site_ref=site_ref,
            )
            if resolved:
                site_id = resolved
                print(f"[unifi-event-poller] resolved site_ref={site_ref} to site_id={site_id}")
        except Exception as exc:  # noqa: BLE001
            print(f"[unifi-event-poller] site resolution skipped: {exc}")

    candidates = candidate_event_urls(
        unifi_base=unifi_base,
        event_path=event_path,
        event_paths_raw=event_paths_raw,
        event_limit=event_limit,
        site_ref=site_ref,
        site_id=site_id,
    )
    loki_push_url = normalize_loki_push_url(loki_base)

    print(
        f"[unifi-event-poller] starting poller interval={interval_seconds}s "
        f"candidate_endpoints={len(candidates)} loki={loki_push_url} job={loki_job} "
        f"backfill_on_start={backfill_on_start}"
    )

    seen = deque(maxlen=5000)
    seen_set: set[str] = set()

    selected_unifi_url = ""
    backfill_done = False
    cursor_mode = ""
    cursor_start_s = int(time.time()) - max(60, int(interval_seconds * 2))

    while True:
        started = time.time()
        try:
            if not selected_unifi_url:
                selected_unifi_url, rows = discover_working_event_url(
                    candidates=candidates,
                    unifi_api_key=unifi_api_key,
                    timeout=timeout_seconds,
                    insecure=unifi_insecure,
                )
                if backfill_on_start and not backfill_done:
                    backfill_rows = fetch_backfill_events(
                        selected_unifi_url=selected_unifi_url,
                        unifi_api_key=unifi_api_key,
                        timeout=timeout_seconds,
                        insecure=unifi_insecure,
                        hours=backfill_hours,
                        limit=backfill_limit,
                    )
                    if backfill_rows:
                        rows = backfill_rows + rows
                    backfill_done = True
            else:
                if use_cursor:
                    poll_end_s = int(time.time())
                    rows, detected_mode = fetch_events_since(
                        selected_unifi_url=selected_unifi_url,
                        unifi_api_key=unifi_api_key,
                        timeout=timeout_seconds,
                        insecure=unifi_insecure,
                        start_s=cursor_start_s,
                        end_s=poll_end_s,
                        limit=event_limit,
                        mode_hint=cursor_mode,
                    )
                    if detected_mode and detected_mode != cursor_mode:
                        cursor_mode = detected_mode
                        print(f"[unifi-event-poller] cursor mode selected: {cursor_mode}")
                    if detected_mode:
                        cursor_start_s = max(0, poll_end_s - max(0, cursor_overlap_seconds))
                    else:
                        rows = fetch_events(
                            unifi_url=selected_unifi_url,
                            unifi_api_key=unifi_api_key,
                            timeout=timeout_seconds,
                            insecure=unifi_insecure,
                        )
                else:
                    rows = fetch_events(
                        unifi_url=selected_unifi_url,
                        unifi_api_key=unifi_api_key,
                        timeout=timeout_seconds,
                        insecure=unifi_insecure,
                    )
            new_events: list[dict[str, Any]] = []
            for event in rows:
                fid = event_fingerprint(event)
                if fid in seen_set:
                    continue
                seen.append(fid)
                seen_set.add(fid)
                new_events.append(event)
            # Trim stale IDs from set when deque rolls over.
            if len(seen_set) > seen.maxlen:
                seen_set.clear()
                seen_set.update(seen)

            if new_events:
                push_events_to_loki(
                    events=new_events,
                    loki_push_url=loki_push_url,
                    loki_api_key=loki_api_key,
                    timeout=timeout_seconds,
                    insecure=loki_insecure,
                    job_label=loki_job,
                )
                print(
                    f"[unifi-event-poller] poll stats fetched={len(rows)} "
                    f"new={len(new_events)} forwarded={len(new_events)} cursor_mode={cursor_mode or 'none'}"
                )
            else:
                print(
                    f"[unifi-event-poller] poll stats fetched={len(rows)} "
                    f"new=0 forwarded=0 cursor_mode={cursor_mode or 'none'}"
                )

        except urllib.error.HTTPError as exc:
            details = exc.read().decode("utf-8", errors="replace")
            print(
                f"[unifi-event-poller] HTTP {exc.code} on {selected_unifi_url or 'discovery'}: {details[:240]}",
                file=sys.stderr,
            )
            if exc.code == 404:
                selected_unifi_url = ""
        except urllib.error.URLError as exc:
            print(f"[unifi-event-poller] network error: {exc.reason}", file=sys.stderr)
        except Exception as exc:  # noqa: BLE001
            print(f"[unifi-event-poller] error: {exc}", file=sys.stderr)

        elapsed = time.time() - started
        sleep_for = max(0.1, interval_seconds - elapsed)
        time.sleep(sleep_for)


if __name__ == "__main__":
    raise SystemExit(main())
