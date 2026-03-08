#!/usr/bin/env python3
"""Shared path helpers for the UniFi SIEM security local skill scripts."""

from __future__ import annotations

from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[2]
