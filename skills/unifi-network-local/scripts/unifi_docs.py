#!/usr/bin/env python3
"""Search and fetch official UniFi Help Center articles."""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Search or fetch UniFi Help Center documentation."
    )
    sub = parser.add_subparsers(dest="command", required=True)

    search = sub.add_parser("search", help="Search Help Center articles.")
    search.add_argument("query", help="Search phrase.")
    search.add_argument(
        "--max-results",
        type=int,
        default=5,
        help="Maximum results (1-8). Default: 5.",
    )

    article = sub.add_parser("article", help="Fetch article by ID or URL.")
    article.add_argument("--article-id", help="Article ID, for example 32065480092951.")
    article.add_argument("--article-url", help="Article URL containing /articles/<id>-...")
    return parser.parse_args()


def get_json(url: str) -> dict:
    req = urllib.request.Request(url, headers={"Accept": "application/json"}, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return json.loads(resp.read().decode("utf-8", errors="replace"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise SystemExit(f"HTTP {exc.code}: {body}") from exc
    except urllib.error.URLError as exc:
        raise SystemExit(f"request failed: {exc.reason}") from exc


def compact(text: str, max_len: int) -> str:
    without_tags = re.sub(r"<[^>]+>", " ", text)
    decoded = (
        without_tags.replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&quot;", '"')
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
    )
    normalized = re.sub(r"\s+", " ", decoded).strip()
    if len(normalized) <= max_len:
        return normalized
    return normalized[:max_len] + "..."


def command_search(query: str, max_results: int) -> int:
    trimmed = query.strip()
    if not trimmed:
        raise SystemExit("search query must not be empty")
    cap = max(1, min(max_results, 8))
    params = urllib.parse.urlencode({"locale": "en-us", "query": trimmed})
    url = f"https://help.ui.com/api/v2/help_center/articles/search.json?{params}"
    payload = get_json(url)
    results = payload.get("results", [])
    if not isinstance(results, list) or not results:
        print(f'No official UniFi Help Center articles found for "{trimmed}".')
        return 0

    print(f'UniFi Help Center search results for "{trimmed}" ({min(cap, len(results))} shown):')
    for idx, article in enumerate(results[:cap], start=1):
        aid = article.get("id", "unknown")
        title = article.get("title", "untitled")
        article_url = article.get("html_url", "unknown")
        snippet = compact(str(article.get("snippet") or article.get("body") or ""), 220)
        print(f"{idx}. [{aid}] {title}")
        print(f"   URL: {article_url}")
        print(f"   Summary: {snippet}")
    return 0


def resolve_article_id(article_id: str | None, article_url: str | None) -> str:
    if article_id and article_id.strip():
        return article_id.strip()
    if not article_url:
        raise SystemExit("provide --article-id or --article-url")
    match = re.search(r"/articles/(\d+)", article_url)
    if not match:
        raise SystemExit("unable to parse article ID from URL")
    return match.group(1)


def command_article(article_id: str | None, article_url: str | None) -> int:
    resolved = resolve_article_id(article_id, article_url)
    url = f"https://help.ui.com/api/v2/help_center/en-us/articles/{resolved}.json"
    payload = get_json(url)
    article = payload.get("article")
    if not isinstance(article, dict):
        raise SystemExit("unexpected article response format")

    print("UniFi Help Center article:")
    print(f"- id: {article.get('id', 'unknown')}")
    print(f"- title: {article.get('title', 'untitled')}")
    print(f"- url: {article.get('html_url', 'unknown')}")
    print("- content_summary:")
    print(compact(str(article.get("body") or article.get("snippet") or ""), 5000))
    return 0


def main() -> int:
    args = parse_args()
    if args.command == "search":
        return command_search(args.query, args.max_results)
    return command_article(args.article_id, args.article_url)


if __name__ == "__main__":
    raise SystemExit(main())

