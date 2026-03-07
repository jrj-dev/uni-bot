#!/usr/bin/env python3
"""Send a prompt to a locally hosted LM Studio OpenAI-compatible API."""

from __future__ import annotations

import argparse
import json
import os
import ssl
import sys
import urllib.error
import urllib.request


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Query a local LM Studio chat/completions endpoint."
    )
    parser.add_argument(
        "prompt",
        nargs="?",
        help="User prompt to send. Not required with --list-models.",
    )
    parser.add_argument(
        "--system",
        default="You are a concise network troubleshooting assistant.",
        help="Optional system message.",
    )
    parser.add_argument(
        "--model",
        default=os.environ.get("LM_STUDIO_MODEL"),
        help="Model name. Defaults to LM_STUDIO_MODEL.",
    )
    parser.add_argument(
        "--base-url",
        default=os.environ.get("LM_STUDIO_BASE_URL"),
        help="LM Studio base URL. Defaults to LM_STUDIO_BASE_URL.",
    )
    parser.add_argument(
        "--api-key",
        default=os.environ.get("LM_STUDIO_API_KEY"),
        help="LM Studio API key. Defaults to LM_STUDIO_API_KEY.",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=60,
        help="Request timeout in seconds. Default: 60.",
    )
    parser.add_argument(
        "--insecure",
        action="store_true",
        help="Disable TLS verification for local self-signed certificates.",
    )
    parser.add_argument(
        "--list-models",
        action="store_true",
        help="List loaded model ids from /v1/models and exit.",
    )
    parser.add_argument(
        "--debug",
        action="store_true",
        help="Print request diagnostics to stderr.",
    )
    return parser.parse_args()


def require(value: str | None, env_name: str) -> str:
    if value:
        return value
    raise SystemExit(f"missing required value: set {env_name} or pass the matching flag")


def context_for(insecure: bool) -> ssl.SSLContext | None:
    if not insecure:
        return None
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    return context


def main() -> int:
    args = parse_args()
    base_url = require(args.base_url, "LM_STUDIO_BASE_URL").rstrip("/")
    api_key = require(args.api_key, "LM_STUDIO_API_KEY").strip()
    if args.list_models:
        url = f"{base_url}/v1/models"
        request = urllib.request.Request(
            url=url,
            method="GET",
            headers={
                "Accept": "application/json",
                "Authorization": f"Bearer {api_key}",
            },
        )
        if args.debug:
            sys.stderr.write(f"[LMStudio] GET {url}\n")
        try:
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            with opener.open(
                request,
                timeout=args.timeout,
                context=context_for(args.insecure),
            ) as response:
                data = json.loads(response.read().decode("utf-8", errors="replace"))
        except urllib.error.HTTPError as exc:
            details = exc.read().decode("utf-8", errors="replace")
            sys.stderr.write(f"HTTP {exc.code} {exc.reason}\n{details}\n")
            return 1
        except urllib.error.URLError as exc:
            sys.stderr.write(f"request failed: {exc.reason}\n")
            return 2

        models = []
        for item in data.get("data", []):
            model_id = item.get("id")
            if isinstance(model_id, str):
                models.append(model_id)
        for model_id in sorted(set(models)):
            print(model_id)
        if not models:
            json.dump(data, sys.stdout, indent=2, sort_keys=True)
            sys.stdout.write("\n")
        return 0

    if not args.prompt:
        raise SystemExit("missing prompt: pass prompt text or use --list-models")
    if not args.model:
        raise SystemExit("missing model: set LM_STUDIO_MODEL or pass --model")

    url = f"{base_url}/v1/chat/completions"

    payload = {
        "model": args.model,
        "messages": [
            {"role": "system", "content": args.system},
            {"role": "user", "content": args.prompt},
        ],
    }
    body = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url=url,
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Authorization": f"Bearer {api_key}",
        },
    )

    if args.debug:
        sys.stderr.write(f"[LMStudio] POST {url} model={args.model}\n")
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(
            request,
            timeout=args.timeout,
            context=context_for(args.insecure),
        ) as response:
            data = json.loads(response.read().decode("utf-8", errors="replace"))
    except urllib.error.HTTPError as exc:
        details = exc.read().decode("utf-8", errors="replace")
        sys.stderr.write(f"HTTP {exc.code} {exc.reason}\n{details}\n")
        return 1
    except urllib.error.URLError as exc:
        sys.stderr.write(f"request failed: {exc.reason}\n")
        return 2

    choices = data.get("choices", [])
    if not choices:
        json.dump(data, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return 0

    message = choices[0].get("message", {})
    content = message.get("content", "")
    if content:
        print(content)
    else:
        json.dump(data, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
