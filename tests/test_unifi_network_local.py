from __future__ import annotations

import contextlib
import importlib.util
import io
import json
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

    def test_resolve_path_for_events_uses_site_ref(self) -> None:
        module = load_module("named_query_test_events_site_ref", "named_query.py")
        args = SimpleNamespace(
            query="events",
            site_id=None,
            site_ref="default",
            insecure=True,
        )

        path = module.resolve_path(args)

        self.assertEqual(path, "/proxy/network/api/s/default/stat/event")

    def test_resolve_path_for_wlanconf_uses_site_id_to_find_site_ref(self) -> None:
        module = load_module("named_query_test_wlanconf_site_id", "named_query.py")
        args = SimpleNamespace(
            query="wlanconf",
            site_id="site-1",
            site_ref=None,
            insecure=True,
        )

        with mock.patch.object(
            module,
            "load_sites",
            return_value=[{"id": "site-1", "internalReference": "default"}],
        ):
            path = module.resolve_path(args)

        self.assertEqual(path, "/proxy/network/api/s/default/rest/wlanconf")

    def test_resolve_path_for_networkconf_requires_site_scope(self) -> None:
        module = load_module("named_query_test_networkconf_scope", "named_query.py")
        args = SimpleNamespace(query="networkconf", site_id=None, site_ref=None, insecure=True)

        with self.assertRaises(SystemExit) as exc:
            module.resolve_path(args)

        self.assertEqual(str(exc.exception), "networkconf requires --site-id or --site-ref")

    def test_sanitize_payload_redacts_sensitive_fields_recursively(self) -> None:
        module = load_module("named_query_test_sanitize", "named_query.py")

        sanitized = module.sanitize_payload(
            {
                "name": "Test",
                "x_passphrase": "secret-pass",
                "nested": {
                    "token": "abc123",
                    "private_preshared_keys": [
                        {"passphrase": "psk-secret"},
                        {"name": "guest"},
                    ],
                },
                "items": [{"x_iapp_key": "opaque"}, {"ok": True}],
            }
        )

        self.assertEqual(sanitized["x_passphrase"], "<redacted>")
        self.assertEqual(sanitized["nested"]["token"], "<redacted>")
        self.assertEqual(sanitized["nested"]["private_preshared_keys"], "<redacted>")
        self.assertEqual(sanitized["items"][0]["x_iapp_key"], "<redacted>")
        self.assertTrue(sanitized["items"][1]["ok"])

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


class AppBlockTests(unittest.TestCase):
    def test_resolve_client_prefers_exact_match(self) -> None:
        module = load_module("app_block_test_client", "app_block.py")

        client = module.resolve_client(
            "AA:BB:CC:DD:EE:FF",
            [
                {"id": "1", "name": "Office MacBook", "mac": "AA:BB:CC:DD:EE:FF"},
                {"id": "2", "name": "Office TV", "mac": "11:22:33:44:55:66"},
            ],
        )

        self.assertEqual(client["id"], "1")

    def test_resolve_apps_supports_substring_matching(self) -> None:
        module = load_module("app_block_test_apps", "app_block.py")

        apps = module.resolve_apps(
            ["zoom", "teams"],
            [
                {"id": "app-1", "name": "Zoom"},
                {"id": "app-2", "name": "Microsoft Teams"},
            ],
        )

        self.assertEqual([item["id"] for item in apps], ["app-1", "app-2"])

    def test_build_schedule_for_weekly_requires_days(self) -> None:
        module = load_module("app_block_test_schedule_error", "app_block.py")
        args = SimpleNamespace(
            schedule_mode="weekly",
            start=None,
            end=None,
            start_time="08:00",
            end_time="17:00",
            days=None,
            all_day=False,
        )

        with self.assertRaises(SystemExit) as exc:
            module.build_schedule(args)

        self.assertEqual(str(exc.exception), "--days is required for --schedule-mode weekly")

    def test_build_schedule_for_custom_maps_bundle_fields(self) -> None:
        module = load_module("app_block_test_schedule_custom", "app_block.py")
        args = SimpleNamespace(
            schedule_mode="custom",
            start="2026-03-09T20:00",
            end="2026-03-12T22:00",
            start_time="20:00",
            end_time="22:00",
            days="mon,wed,fri",
            all_day=False,
        )

        schedule = module.build_schedule(args)

        self.assertEqual(
            schedule,
            {
                "mode": "CUSTOM",
                "date_start": "2026-03-09",
                "date_end": "2026-03-12",
                "repeat_on_days": [1, 3, 5],
                "time_range_start": "20:00",
                "time_range_end": "22:00",
            },
        )

    def test_build_plan_resolves_client_apps_and_schedule(self) -> None:
        module = load_module("app_block_test_plan", "app_block.py")
        args = SimpleNamespace(
            site_id="site-1",
            site_ref=None,
            insecure=True,
            client="macbook",
            apps=["zoom", "teams"],
            categories=["streaming"],
            schedule_mode="daily",
            start=None,
            end=None,
            start_time="20:00",
            end_time="22:00",
            days=None,
            all_day=False,
            policy_name=None,
        )

        def fake_query(query: str, **_: object) -> object:
            if query == "clients":
                return {
                    "data": [
                        {
                            "id": "client-1",
                            "name": "MacBook Pro",
                            "hostname": "macbook-pro",
                            "mac": "AA:BB:CC:DD:EE:FF",
                            "ip": "192.168.1.25",
                        }
                    ]
                }
            if query == "dpi-applications":
                return {
                    "data": [
                        {"id": "app-1", "name": "Zoom"},
                        {"id": "app-2", "name": "Microsoft Teams"},
                    ]
                }
            if query == "dpi-categories":
                return {
                    "data": [
                        {"id": "3", "name": "Streaming Media"},
                        {"id": "4", "name": "Peer-to-Peer"},
                    ]
                }
            raise AssertionError(f"unexpected query: {query}")

        with mock.patch.object(module, "run_named_query", side_effect=fake_query):
            plan = module.build_plan(args)

        self.assertEqual(plan["resolved_client"]["id"], "client-1")
        self.assertEqual(
            [item["id"] for item in plan["resolved_applications"]],
            ["app-1", "app-2"],
        )
        self.assertEqual(
            [item["id"] for item in plan["resolved_categories"]],
            ["3"],
        )
        self.assertEqual(len(plan["simple_app_block_payloads"]), 2)
        self.assertEqual(
            plan["simple_app_block_payloads"][0]["target_type"],
            "APP_ID",
        )
        self.assertEqual(
            plan["simple_app_block_payloads"][0]["app_ids"],
            ["app-1", "app-2"],
        )
        self.assertEqual(
            plan["simple_app_block_payloads"][1]["app_category_ids"],
            ["3"],
        )
        self.assertEqual(
            plan["simple_app_block_payloads"][0]["client_macs"],
            ["aa:bb:cc:dd:ee:ff"],
        )
        self.assertEqual(
            plan["simple_app_block_payloads"][0]["schedule"]["mode"],
            "EVERY_DAY",
        )
        self.assertEqual(
            plan["legacy_private_api_payload_candidate"]["service"]["firewall"]["name"]["DPI_LOCAL"]["rule"]["1"]["application"],
            "Zoom",
        )
        self.assertEqual(
            plan["legacy_private_api_payload_candidate"]["service"]["firewall"]["name"]["DPI_LOCAL"]["rule"]["3"]["application"]["category"],
            "3",
        )
        self.assertEqual(plan["schedule"]["mode"], "EVERY_DAY")
        self.assertEqual(plan["schedule"]["time_range_start"], "20:00")
        self.assertEqual(plan["schedule"]["time_range_end"], "22:00")

    def test_apply_block_posts_full_collection_to_firewall_app_blocks_endpoint(self) -> None:
        module = load_module("app_block_test_apply", "app_block.py")
        args = SimpleNamespace(
            site_id=None,
            site_ref="default",
            insecure=True,
            client="macbook",
            apps=["zoom"],
            categories=[],
            schedule_mode="always",
            start=None,
            end=None,
            start_time=None,
            end_time=None,
            days=None,
            all_day=False,
            policy_name="Block Zoom for MacBook Pro",
            rule_id=None,
        )

        def fake_query(query: str, **_: object) -> object:
            if query == "clients":
                return {"data": [{"id": "client-1", "name": "MacBook Pro", "mac": "AA:BB:CC:DD:EE:FF"}]}
            if query == "dpi-applications":
                return {"data": [{"id": 39, "name": "Zoom"}]}
            if query == "dpi-categories":
                return {"data": []}
            raise AssertionError(f"unexpected query: {query}")

        with mock.patch.object(module, "run_named_query", side_effect=fake_query):
            with mock.patch.object(module, "run_unifi_request", return_value={"_id": "rule-1"}) as request_mock:
                stdout = io.StringIO()
                with contextlib.redirect_stdout(stdout):
                    exit_code = module.command_apply_block(args)

        self.assertEqual(exit_code, 0)
        self.assertGreaterEqual(request_mock.call_count, 1)
        post_call = next(call for call in request_mock.call_args_list if call.args[:2] == ("POST", "/proxy/network/v2/api/site/default/firewall-app-blocks"))
        self.assertEqual(
            post_call.args[:2],
            ("POST", "/proxy/network/v2/api/site/default/firewall-app-blocks"),
        )
        self.assertEqual(
            post_call.kwargs["body"][-1]["target_type"],
            "APP_ID",
        )
        self.assertIn('"site_ref": "default"', stdout.getvalue())

    def test_list_block_returns_matching_rules_for_client(self) -> None:
        module = load_module("app_block_test_list_block", "app_block.py")
        args = SimpleNamespace(
            site_id=None,
            site_ref="default",
            insecure=True,
            client="macbook",
        )

        def fake_query(query: str, **_: object) -> object:
            if query == "clients-all":
                return {"data": [{"id": "client-1", "name": "MacBook Pro", "mac": "A8E29161BE34"}]}
            if query == "clients":
                return {"data": [{"id": "client-1", "name": "MacBook Pro", "mac": "a8:e2:91:61:be:34"}]}
            if query == "dpi-applications":
                return {"data": [{"id": "39", "name": "Zoom"}]}
            if query == "dpi-categories":
                return {"data": [{"id": "3", "name": "Streaming Media"}]}
            raise AssertionError(f"unexpected query: {query}")

        def fake_request(method: str, path: str, **_: object) -> object:
            if method == "GET" and path == "/proxy/network/v2/api/site/default/firewall-app-blocks":
                return {
                    "data": [
                        {
                            "_id": "rule-1",
                            "name": "Block Zoom",
                            "type": "DEVICE",
                            "target_type": "APP_ID",
                            "client_macs": ["a8:e2:91:61:be:34"],
                            "app_ids": ["39"],
                            "app_category_ids": [],
                            "schedule": {"mode": "ALWAYS"},
                            "action": "BLOCK",
                        }
                    ]
                }
            if method == "GET" and path == "/proxy/network/api/s/default/stat/alluser":
                return {"data": []}
            raise AssertionError(f"unexpected request: {method} {path}")

        with mock.patch.object(module, "run_named_query", side_effect=fake_query):
            with mock.patch.object(module, "run_unifi_request", side_effect=fake_request):
                stdout = io.StringIO()
                with contextlib.redirect_stdout(stdout):
                    exit_code = module.command_list_block(args)

        payload = json.loads(stdout.getvalue())
        self.assertEqual(exit_code, 0)
        self.assertEqual(payload["kind"], "unifi_app_block_list_result")
        self.assertEqual(payload["rule_count"], 1)
        self.assertEqual(payload["rules"][0]["rule_id"], "rule-1")
        self.assertEqual(payload["rules"][0]["app_names"], ["Zoom"])

    def test_build_simple_app_block_payload_category_only(self) -> None:
        module = load_module("app_block_test_simple_category", "app_block.py")

        payload = module.build_simple_app_block_payload(
            client={"mac": "72:79:0b:7b:ed:25"},
            schedule={"mode": "ALWAYS"},
            policy_name="Block Streaming",
            target_type="APP_CATEGORY",
            ids=[3],
        )

        self.assertEqual(payload["target_type"], "APP_CATEGORY")
        self.assertEqual(payload["app_ids"], [])
        self.assertEqual(payload["app_category_ids"], [3])
        self.assertEqual(payload["client_macs"], ["72:79:0b:7b:ed:25"])
        self.assertEqual(payload["network_ids"], [])
        self.assertEqual(payload["schedule"], {"mode": "ALWAYS"})

    def test_build_simple_app_block_payload_matches_submit_shape(self) -> None:
        module = load_module("app_block_test_submit_shape", "app_block.py")

        payload = module.build_simple_app_block_payload(
            client={"mac": "a8:e2:91:61:be:34"},
            schedule={"mode": "ALWAYS"},
            policy_name="Block TikTok on Axiom",
            target_type="APP_ID",
            ids=[262392],
        )

        self.assertEqual(
            payload,
            {
                "name": "Block TikTok on Axiom",
                "type": "DEVICE",
                "target_type": "APP_ID",
                "client_macs": ["a8:e2:91:61:be:34"],
                "network_ids": [],
                "schedule": {"mode": "ALWAYS"},
                "app_ids": [262392],
                "app_category_ids": [],
            },
        )

    def test_build_plan_requires_app_or_category(self) -> None:
        module = load_module("app_block_test_requires_target", "app_block.py")
        args = SimpleNamespace(
            site_id="site-1",
            site_ref=None,
            insecure=True,
            client="macbook",
            apps=[],
            categories=[],
            schedule_mode="always",
            start=None,
            end=None,
            start_time=None,
            end_time=None,
            days=None,
            all_day=False,
            policy_name=None,
        )

        with self.assertRaises(SystemExit) as exc:
            module.build_plan(args)

        self.assertEqual(str(exc.exception), "at least one --app or --category is required")

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


class NetworkRankingsTests(unittest.TestCase):
    def test_compute_rankings_returns_highest_bandwidth_client(self) -> None:
        module = load_module("network_rankings_test_bandwidth", "network_rankings.py")
        args = SimpleNamespace(
            entity_type="client",
            metric="highest_bandwidth",
            limit=5,
            site_id="site-1",
            site_ref="default",
            include_inactive=False,
            insecure=True,
        )

        def fake_query(query: str, **_: object) -> object:
            if query == "clients":
                return {
                    "data": [
                        {"name": "Axiom", "ip": "192.168.1.10", "mac": "aa:bb", "txRate": 40, "rxRate": 60},
                        {"name": "iPhone", "ip": "192.168.1.11", "mac": "cc:dd", "txRate": 10, "rxRate": 15},
                    ]
                }
            raise AssertionError(f"unexpected query: {query}")

        with mock.patch.object(module, "run_named_query", side_effect=fake_query):
            ranked = module.compute_rankings(args)

        self.assertEqual(ranked[0]["label"], "client=Axiom (192.168.1.10)")
        self.assertEqual(ranked[0]["value_text"], "100 Mbps")

    def test_compute_rankings_returns_busiest_access_point(self) -> None:
        module = load_module("network_rankings_test_ap", "network_rankings.py")
        args = SimpleNamespace(
            entity_type="access_point",
            metric="client_count",
            limit=5,
            site_id="site-1",
            site_ref="default",
            include_inactive=False,
            insecure=True,
        )

        def fake_query(query: str, **_: object) -> object:
            if query == "devices":
                return {"data": [{"id": "ap-1", "name": "Hallway AP"}, {"id": "ap-2", "name": "Office AP"}]}
            if query == "clients":
                return {
                    "data": [
                        {"name": "Axiom", "uplinkDeviceId": "ap-1"},
                        {"name": "iPhone", "uplinkDeviceId": "ap-1"},
                        {"name": "TV", "uplinkDeviceId": "ap-2"},
                    ]
                }
            raise AssertionError(f"unexpected query: {query}")

        with mock.patch.object(module, "run_named_query", side_effect=fake_query):
            ranked = module.compute_rankings(args)

        self.assertEqual(ranked[0]["label"], "access_point=Hallway AP")
        self.assertEqual(ranked[0]["value_text"], "2")

    def test_compute_rankings_returns_busiest_ssid(self) -> None:
        module = load_module("network_rankings_test_ssid", "network_rankings.py")
        args = SimpleNamespace(
            entity_type="wifi_broadcast",
            metric="client_count",
            limit=5,
            site_id="site-1",
            site_ref="default",
            include_inactive=False,
            insecure=True,
        )

        def fake_query(query: str, **_: object) -> object:
            if query == "wifi-broadcasts":
                return {"data": [{"id": "wifi-1", "name": "Main WiFi"}, {"id": "wifi-2", "name": "IoT"}]}
            if query == "clients":
                return {
                    "data": [
                        {"name": "Phone", "wifiBroadcastId": "wifi-1", "is_wired": False},
                        {"name": "Laptop", "wifiBroadcastId": "wifi-1", "is_wired": False},
                        {"name": "Sensor", "wifiBroadcastId": "wifi-2", "is_wired": False},
                    ]
                }
            raise AssertionError(f"unexpected query: {query}")

        with mock.patch.object(module, "run_named_query", side_effect=fake_query):
            ranked = module.compute_rankings(args)

        self.assertEqual(ranked[0]["label"], "wifi_broadcast=Main WiFi")
        self.assertEqual(ranked[0]["value_text"], "2")

    def test_compute_rankings_returns_shadowed_firewall_rule(self) -> None:
        module = load_module("network_rankings_test_shadow", "network_rankings.py")
        args = SimpleNamespace(
            entity_type="firewall_rule",
            metric="shadow_risk",
            limit=5,
            site_id="site-1",
            site_ref="default",
            include_inactive=False,
            insecure=True,
        )

        def fake_query(query: str, **_: object) -> object:
            if query == "firewall-policies":
                return {
                    "data": [
                        {"id": "rule-1", "name": "Allow LAN to WAN", "enabled": True, "source": {"zoneId": "lan"}, "destination": {"zoneId": "wan"}, "action": {"type": "ALLOW"}},
                        {"id": "rule-2", "name": "Later duplicate", "enabled": True, "source": {"zoneId": "lan"}, "destination": {"zoneId": "wan"}, "action": {"type": "ALLOW"}},
                    ]
                }
            raise AssertionError(f"unexpected query: {query}")

        with mock.patch.object(module, "run_named_query", side_effect=fake_query):
            ranked = module.compute_rankings(args)

        self.assertEqual(ranked[0]["label"], "firewall_rule=Later duplicate")
        self.assertEqual(ranked[0]["value_text"], "1")

    def test_compute_rankings_returns_most_referenced_network(self) -> None:
        module = load_module("network_rankings_test_network_refs", "network_rankings.py")
        args = SimpleNamespace(
            entity_type="network",
            metric="reference_count",
            limit=5,
            site_id="site-1",
            site_ref="default",
            include_inactive=False,
            insecure=True,
        )

        def fake_query(query: str, **_: object) -> object:
            if query == "networks":
                return {"data": [{"id": "net-1", "name": "LAN"}, {"id": "net-2", "name": "IoT"}]}
            if query == "wifi-broadcasts":
                return {"data": [{"id": "wifi-1", "networkId": "net-1"}]}
            if query == "dns-policies":
                return {"data": [{"id": "dns-1", "network_ids": ["net-1"]}]}
            if query == "firewall-policies":
                return {"data": [{"id": "fw-1", "source": {"networkId": "net-1"}}]}
            if query == "acl-rules":
                return {"data": [{"id": "acl-1", "destination": {"networkId": "net-2"}}]}
            raise AssertionError(f"unexpected query: {query}")

        with mock.patch.object(module, "run_named_query", side_effect=fake_query):
            ranked = module.compute_rankings(args)

        self.assertEqual(ranked[0]["label"], "network=LAN")
        self.assertEqual(ranked[0]["value_text"], "3")

    def test_compute_rankings_returns_stale_vpn_tunnel(self) -> None:
        module = load_module("network_rankings_test_vpn", "network_rankings.py")
        args = SimpleNamespace(
            entity_type="vpn_tunnel",
            metric="stale",
            limit=5,
            site_id="site-1",
            site_ref="default",
            include_inactive=False,
            insecure=True,
        )

        def fake_query(query: str, **_: object) -> object:
            if query == "site-to-site-vpn":
                return {
                    "data": [
                        {"name": "HQ Tunnel", "status": "up", "lastSeen": "2026-03-10T00:00:00Z"},
                        {"name": "Branch Tunnel", "status": "down", "lastSeen": "2026-03-01T00:00:00Z"},
                    ]
                }
            raise AssertionError(f"unexpected query: {query}")

        with mock.patch.object(module, "run_named_query", side_effect=fake_query):
            ranked = module.compute_rankings(args)

        self.assertEqual(ranked[0]["label"], "vpn_tunnel=Branch Tunnel")

    def test_compute_rankings_returns_flapping_switch_port(self) -> None:
        module = load_module("network_rankings_test_port_flap", "network_rankings.py")
        args = SimpleNamespace(
            entity_type="switch_port",
            metric="flapping",
            limit=5,
            site_id="site-1",
            site_ref="default",
            include_inactive=False,
            insecure=True,
        )

        def fake_query(query: str, **_: object) -> object:
            if query == "devices":
                return {
                    "data": [
                        {
                            "id": "sw-1",
                            "name": "Core Switch",
                            "ports": [
                                {"portIdx": "1", "linkFlaps": 2},
                                {"portIdx": "2", "linkFlaps": 9},
                            ],
                        }
                    ]
                }
            raise AssertionError(f"unexpected query: {query}")

        with mock.patch.object(module, "run_named_query", side_effect=fake_query):
            ranked = module.compute_rankings(args)

        self.assertEqual(ranked[0]["label"], "switch_port=Core Switch port 2")
        self.assertEqual(ranked[0]["value_text"], "9")

    def test_main_outputs_app_block_target_count(self) -> None:
        module = load_module("network_rankings_test_app_blocks", "network_rankings.py")
        args = SimpleNamespace(
            entity_type="app_block",
            metric="target_count",
            limit=3,
            site_id=None,
            site_ref="default",
            include_inactive=False,
            insecure=True,
        )

        with mock.patch.object(module, "parse_args", return_value=args):
            with mock.patch.object(
                module,
                "run_unifi_request",
                return_value={
                    "data": [
                        {"name": "Block TikTok", "client_macs": ["aa", "bb", "cc"]},
                        {"name": "Block YouTube", "client_macs": ["dd"]},
                    ]
                },
            ):
                stdout = io.StringIO()
                with contextlib.redirect_stdout(stdout):
                    exit_code = module.main()

        payload = json.loads(stdout.getvalue())
        self.assertEqual(exit_code, 0)
        self.assertEqual(payload["kind"], "unifi_network_rankings")
        self.assertEqual(payload["results"][0]["label"], "app_block=Block TikTok")
        self.assertEqual(payload["results"][0]["value_text"], "3")


if __name__ == "__main__":
    unittest.main()
