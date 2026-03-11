#!/usr/bin/env python3
"""Client network diagnostics: ping-style probe and DNS resolution helpers."""

from __future__ import annotations

import argparse
import ipaddress
import json
import socket
import subprocess
import sys


# Parses CLI arguments for standalone client diagnostics.
def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run local client diagnostics (ping or DNS resolution)."
    )
    subparsers = parser.add_subparsers(dest="action", required=True)

    ping_parser = subparsers.add_parser("ping", help="Run ping-style reachability checks.")
    ping_parser.add_argument("target", help="Client hostname or IP address.")
    ping_parser.add_argument("--count", type=int, default=3, help="Ping count. Default: 3.")
    ping_parser.add_argument("--timeout", type=int, default=2, help="Per-ping timeout seconds. Default: 2.")

    dns_parser = subparsers.add_parser("dns", help="Resolve DNS forward or reverse.")
    dns_parser.add_argument("target", help="Client hostname or IP address.")

    http_parser = subparsers.add_parser("http", help="Probe HTTP/HTTPS endpoint.")
    http_parser.add_argument("target", help="Client hostname or IP address.")
    http_parser.add_argument("--scheme", choices=["http", "https"], default="http", help="URL scheme. Default: http.")
    http_parser.add_argument("--path", default="/", help="Request path. Default: /")
    http_parser.add_argument("--timeout", type=int, default=5, help="Request timeout seconds. Default: 5.")

    ports_parser = subparsers.add_parser("ports", help="Check TCP ports.")
    ports_parser.add_argument("target", help="Client hostname or IP address.")
    ports_parser.add_argument("--ports", required=True, help="Comma-separated ports, e.g. 22,53,80,443")
    ports_parser.add_argument("--timeout", type=int, default=2, help="Per-port timeout seconds. Default: 2.")

    return parser.parse_args()


# Runs a ping probe against the requested target.
def run_ping(target: str, count: int, timeout: int) -> int:
    cmd = [
        "ping",
        "-c",
        str(max(1, min(count, 10))),
        "-W",
        str(max(1, min(timeout, 10))),
        target,
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    payload = {
        "action": "ping",
        "target": target,
        "exit_code": result.returncode,
        "success": result.returncode == 0,
        "stdout": result.stdout.strip(),
        "stderr": result.stderr.strip(),
        "command": " ".join(cmd),
    }
    json.dump(payload, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0 if result.returncode == 0 else 1


# Runs forward and reverse DNS lookups for the requested target.
def run_dns(target: str) -> int:
    try:
        ip = ipaddress.ip_address(target)
        try:
            hostname, _, _ = socket.gethostbyaddr(str(ip))
            payload = {
                "action": "dns",
                "target": target,
                "mode": "reverse",
                "success": True,
                "hostname": hostname,
            }
            json.dump(payload, sys.stdout, indent=2, sort_keys=True)
            sys.stdout.write("\n")
            return 0
        except OSError as exc:
            payload = {
                "action": "dns",
                "target": target,
                "mode": "reverse",
                "success": False,
                "error": str(exc),
            }
            json.dump(payload, sys.stdout, indent=2, sort_keys=True)
            sys.stdout.write("\n")
            return 1
    except ValueError:
        pass

    try:
        rows = socket.getaddrinfo(target, None)
    except OSError as exc:
        payload = {
            "action": "dns",
            "target": target,
            "mode": "forward",
            "success": False,
            "error": str(exc),
        }
        json.dump(payload, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return 1

    ips: list[str] = []
    for row in rows:
        addr = row[4][0]
        if addr not in ips:
            ips.append(addr)
    payload = {
        "action": "dns",
        "target": target,
        "mode": "forward",
        "success": bool(ips),
        "addresses": ips,
    }
    json.dump(payload, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0 if ips else 1


# Runs an HTTP probe against the requested target and path.
def run_http(target: str, scheme: str, path: str, timeout: int) -> int:
    import urllib.error
    import urllib.request

    path = path if path.startswith("/") else f"/{path}"
    url = f"{scheme}://{target}{path}"
    request = urllib.request.Request(url=url, method="GET", headers={"Connection": "close"})
    try:
        with urllib.request.urlopen(request, timeout=max(1, min(timeout, 20))) as response:
            payload = {
                "action": "http",
                "url": url,
                "success": True,
                "status": getattr(response, "status", 200),
            }
            json.dump(payload, sys.stdout, indent=2, sort_keys=True)
            sys.stdout.write("\n")
            return 0
    except urllib.error.HTTPError as exc:
        payload = {
            "action": "http",
            "url": url,
            "success": False,
            "status": exc.code,
            "error": str(exc),
        }
        json.dump(payload, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return 1
    except Exception as exc:  # noqa: BLE001
        payload = {
            "action": "http",
            "url": url,
            "success": False,
            "error": str(exc),
        }
        json.dump(payload, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return 1


# Runs TCP port checks against the requested target.
def run_ports(target: str, ports_csv: str, timeout: int) -> int:
    ports = []
    for item in ports_csv.split(","):
        item = item.strip()
        if not item:
            continue
        try:
            value = int(item)
        except ValueError:
            continue
        if 1 <= value <= 65535:
            ports.append(value)
    if not ports:
        raise SystemExit("no valid ports parsed from --ports")

    results = []
    all_open = True
    for port in ports[:20]:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(max(1, min(timeout, 10)))
        try:
            rc = sock.connect_ex((target, port))
            open_state = rc == 0
        except OSError:
            open_state = False
        finally:
            sock.close()
        results.append({"port": port, "reachable": open_state})
        if not open_state:
            all_open = False

    payload = {
        "action": "ports",
        "target": target,
        "success": all_open,
        "results": results,
    }
    json.dump(payload, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0 if all_open else 1


# Dispatches the selected client diagnostics command.
def main() -> int:
    args = parse_args()
    if args.action == "ping":
        return run_ping(args.target, args.count, args.timeout)
    if args.action == "dns":
        return run_dns(args.target)
    if args.action == "http":
        return run_http(args.target, args.scheme, args.path, args.timeout)
    if args.action == "ports":
        return run_ports(args.target, args.ports, args.timeout)
    raise SystemExit(f"unsupported action: {args.action}")


if __name__ == "__main__":
    raise SystemExit(main())
