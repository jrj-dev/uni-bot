from __future__ import annotations

import contextlib
import importlib.util
import io
import sys
import unittest
import urllib.error
from pathlib import Path
from types import ModuleType, SimpleNamespace
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS_DIR = ROOT / "skills" / "unifi-network-local" / "scripts"


def load_module(name: str, filename: str) -> ModuleType:
    path = SCRIPTS_DIR / filename
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.path.insert(0, str(SCRIPTS_DIR))
    try:
        spec.loader.exec_module(module)
    finally:
        sys.path.pop(0)
    return module


class UnifiRequestTests(unittest.TestCase):
    def test_http_error_body_is_written_to_stderr(self) -> None:
        module = load_module("unifi_request_test", "unifi_request.py")
        args = SimpleNamespace(
            method="GET",
            path="/proxy/network/integration/v1/sites",
            base_url="https://unifi.local",
            api_key="secret",
            query=[],
            json_body=None,
            timeout=5,
            insecure=False,
            allow_write=False,
        )
        error = urllib.error.HTTPError(
            url="https://unifi.local/proxy/network/integration/v1/sites",
            code=400,
            msg="Bad Request",
            hdrs=None,
            fp=io.BytesIO(b'{"error":"bad request"}'),
        )
        stderr = io.StringIO()
        stdout = io.StringIO()

        with mock.patch.object(module, "parse_args", return_value=args):
            with mock.patch.object(module.urllib.request, "urlopen", side_effect=error):
                with mock.patch.object(module.sys, "stderr", stderr):
                    with contextlib.redirect_stdout(stdout):
                        exit_code = module.main()

        self.assertEqual(exit_code, 1)
        self.assertEqual(stdout.getvalue(), "")
        self.assertIn("HTTP 400 Bad Request", stderr.getvalue())
        self.assertIn('"error": "bad request"', stderr.getvalue())


class CaptureSnapshotTests(unittest.TestCase):
    def test_selected_endpoints_include_expanded_defaults(self) -> None:
        module = load_module("capture_snapshot_test_defaults", "capture_snapshot.py")

        selected = list(module.selected_endpoints(None, [], "site-1"))
        names = [name for name, _ in selected]

        self.assertIn("sites", names)
        self.assertIn("pending_devices", names)
        self.assertIn("dpi_categories", names)
        self.assertIn("countries", names)
        self.assertIn("devices", names)
        self.assertIn("networks", names)
        self.assertIn("firewall_policies", names)
        self.assertIn("vpn_servers", names)

    def test_selected_endpoints_require_site_id_for_site_scoped_filters(self) -> None:
        module = load_module("capture_snapshot_test_site_required", "capture_snapshot.py")

        with self.assertRaises(SystemExit) as exc:
            list(module.selected_endpoints(["devices"], [], None))

        self.assertIn("site-scoped datasets require --site-id", str(exc.exception))

    def test_run_request_uses_script_path_relative_to_file(self) -> None:
        module = load_module("capture_snapshot_test", "capture_snapshot.py")
        completed = SimpleNamespace(returncode=0, stdout="{}", stderr="")

        with mock.patch.object(module.subprocess, "run", return_value=completed) as run_mock:
            result = module.run_request("/proxy/network/integration/v1/sites", insecure=True)

        self.assertEqual(result, {})
        cmd = run_mock.call_args.args[0]
        self.assertEqual(cmd[0], sys.executable)
        self.assertEqual(cmd[1], str(module.REQUEST_SCRIPT))
        self.assertTrue(Path(cmd[1]).is_absolute())
        self.assertIn("--insecure", cmd)


class LiveSummaryTests(unittest.TestCase):
    def test_main_requires_explicit_site_id(self) -> None:
        module = load_module("live_summary_test_missing", "live_summary.py")

        with mock.patch.object(
            module,
            "parse_args",
            return_value=SimpleNamespace(site_id=None, insecure=False),
        ):
            with mock.patch.object(module, "run_command") as run_command:
                with self.assertRaises(SystemExit) as exc:
                    module.main()

        self.assertEqual(str(exc.exception), "missing site ID: set UNIFI_SITE_ID or pass --site-id")
        run_command.assert_not_called()

    def test_main_uses_absolute_script_paths(self) -> None:
        module = load_module("live_summary_test_paths", "live_summary.py")

        with mock.patch.object(
            module,
            "parse_args",
            return_value=SimpleNamespace(site_id="site-1", insecure=True),
        ):
            with mock.patch.object(
                module,
                "run_command",
                side_effect=["/tmp/snapshot-dir", "summary output"],
            ) as run_command:
                stdout = io.StringIO()
                with contextlib.redirect_stdout(stdout):
                    exit_code = module.main()

        self.assertEqual(exit_code, 0)
        first_call = run_command.call_args_list[0].args[0]
        second_call = run_command.call_args_list[1].args[0]
        self.assertEqual(first_call[1], str(module.CAPTURE_SCRIPT))
        self.assertEqual(second_call[1], str(module.ANALYZE_SCRIPT))
        self.assertTrue(Path(first_call[1]).is_absolute())
        self.assertTrue(Path(second_call[1]).is_absolute())
        self.assertIn("--insecure", first_call)
        self.assertIn("Saved snapshot: /tmp/snapshot-dir", stdout.getvalue())


class NamedQueryTests(unittest.TestCase):
    def test_parse_query_items(self) -> None:
        module = load_module("named_query_test_parse", "named_query.py")

        items = module.parse_query_items(["offset=25", "limit=100"])

        self.assertEqual(items, [("offset", "25"), ("limit", "100")])

    def test_merge_paginated_pages(self) -> None:
        module = load_module("named_query_test_merge", "named_query.py")

        merged = module.merge_paginated_pages(
            [
                {
                    "offset": 0,
                    "limit": 2,
                    "count": 2,
                    "totalCount": 3,
                    "data": [{"id": "one"}, {"id": "two"}],
                },
                {
                    "offset": 2,
                    "limit": 2,
                    "count": 1,
                    "totalCount": 3,
                    "data": [{"id": "three"}],
                },
            ]
        )

        self.assertEqual(merged["offset"], 0)
        self.assertEqual(merged["count"], 3)
        self.assertEqual(merged["totalCount"], 3)
        self.assertEqual([item["id"] for item in merged["data"]], ["one", "two", "three"])

    def test_resolve_path_for_global_query(self) -> None:
        module = load_module("named_query_test_global", "named_query.py")
        args = SimpleNamespace(query="pending-devices")

        path = module.resolve_path(args)

        self.assertEqual(path, "/proxy/network/integration/v1/pending-devices")

    def test_resolve_path_uses_site_ref(self) -> None:
        module = load_module("named_query_test_site_ref", "named_query.py")
        args = SimpleNamespace(
            query="networks",
            site_id=None,
            site_ref="default",
            insecure=True,
        )

        with mock.patch.object(
            module,
            "load_sites",
            return_value=[{"id": "site-1", "internalReference": "default"}],
        ):
            path = module.resolve_path(args)

        self.assertEqual(path, "/proxy/network/integration/v1/sites/site-1/networks")

    def test_resolve_path_requires_site_id(self) -> None:
        module = load_module("named_query_test_site", "named_query.py")
        args = SimpleNamespace(query="networks", site_id=None, site_ref=None, insecure=True)

        with self.assertRaises(SystemExit) as exc:
            module.resolve_path(args)

        self.assertEqual(str(exc.exception), "networks requires --site-id or --site-ref")

    def test_resolve_path_for_resource_query(self) -> None:
        module = load_module("named_query_test_resource", "named_query.py")
        args = SimpleNamespace(
            query="device-stats",
            site_id="site-1",
            device_id="device-9",
        )

        path = module.resolve_path(args)

        self.assertEqual(
            path,
            "/proxy/network/integration/v1/sites/site-1/devices/device-9/statistics/latest",
        )

    def test_resolve_path_for_acl_rules(self) -> None:
        module = load_module("named_query_test_acl", "named_query.py")
        args = SimpleNamespace(query="acl-rules", site_id="site-1")

        path = module.resolve_path(args)

        self.assertEqual(path, "/proxy/network/integration/v1/sites/site-1/acl-rules")

    def test_resolve_path_for_hotspot_vouchers(self) -> None:
        module = load_module("named_query_test_vouchers", "named_query.py")
        args = SimpleNamespace(query="hotspot-vouchers", site_id="site-1")

        path = module.resolve_path(args)

        self.assertEqual(
            path,
            "/proxy/network/integration/v1/sites/site-1/hotspot/vouchers",
        )


class AnalyzeSnapshotTests(unittest.TestCase):
    def test_analyze_snapshot_includes_extended_sections(self) -> None:
        module = load_module("analyze_snapshot_test", "analyze_snapshot.py")
        snap = ROOT / "tests" / "fixtures" / "unifi_snapshot"

        with mock.patch.object(
            module,
            "parse_args",
            return_value=SimpleNamespace(snapshot_dir=str(snap)),
        ):
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                exit_code = module.main()

        output = stdout.getvalue()
        self.assertEqual(exit_code, 0)
        self.assertIn("Networks: 1", output)
        self.assertIn("WiFi broadcasts: 1", output)
        self.assertIn("Firewall policies: 1", output)
        self.assertIn("Pending devices: 1", output)
        self.assertIn("Network types:", output)
        self.assertIn("DPI categories: 1", output)


class QuerySummaryTests(unittest.TestCase):
    def test_require_site_id_uses_site_ref(self) -> None:
        module = load_module("query_summary_test_site_ref", "query_summary.py")
        args = SimpleNamespace(summary="overview", site_id=None, site_ref="default", insecure=True)

        with mock.patch.object(
            module,
            "load_named_query",
            return_value={
                "data": [{"id": "site-1", "internalReference": "default"}],
            },
        ):
            site_id = module.require_site_id(args)

        self.assertEqual(site_id, "site-1")


if __name__ == "__main__":
    unittest.main()
