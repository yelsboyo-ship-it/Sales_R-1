import socket
import unittest
import os
from unittest.mock import patch

from serve_sales_ledger import (
    SalesLedgerHandler,
    build_supabase_config,
    collect_metrics,
    create_http_server,
    inject_supabase_env,
    send_alert,
)


class ServeSalesLedgerConfigTests(unittest.TestCase):
    def test_build_supabase_config_uses_environment_values(self):
        env_values = {"SUPA_URL": "https://example.supabase.co", "SUPA_KEY": "test-anon-key"}

        self.assertEqual(
            build_supabase_config(env_values),
            {"SUPA_URL": "https://example.supabase.co", "SUPA_KEY": "test-anon-key"},
        )

    def test_build_supabase_config_returns_blank_when_values_are_missing(self):
        self.assertEqual(build_supabase_config({}), {"SUPA_URL": "", "SUPA_KEY": ""})

    def test_build_supabase_config_prefers_process_environment_for_default_loading(self):
        with patch.dict(os.environ, {"SUPA_URL": "https://env.example.supabase.co", "SUPA_KEY": "env-key"}, clear=False):
            with patch("serve_sales_ledger.ENV_VALUES", {"SUPA_URL": "https://file.example.supabase.co", "SUPA_KEY": "file-key"}):
                self.assertEqual(
                    build_supabase_config(),
                    {"SUPA_URL": "https://env.example.supabase.co", "SUPA_KEY": "env-key"},
                )

    def test_build_supabase_config_accepts_standard_environment_names(self):
        with patch.dict(os.environ, {"SUPABASE_URL": "https://env.example.supabase.co/", "SUPABASE_ANON_KEY": "env-key"}, clear=False):
            with patch("serve_sales_ledger.ENV_VALUES", {}):
                self.assertEqual(
                    build_supabase_config(),
                    {"SUPA_URL": "https://env.example.supabase.co", "SUPA_KEY": "env-key"},
                )


class ServeSalesLedgerMonitoringTests(unittest.TestCase):
    def test_public_asset_allowlist_blocks_source_and_backup_files(self):
        self.assertTrue(SalesLedgerHandler.is_public_asset_path("/Onestop_Veggies/index.html"))
        self.assertFalse(SalesLedgerHandler.is_public_asset_path("/supabase_schema.sql"))
        self.assertFalse(SalesLedgerHandler.is_public_asset_path("/Onestop_Veggies/index.backup.html"))
        self.assertFalse(SalesLedgerHandler.is_public_asset_path("/../.env"))

    def test_inject_supabase_env_places_config_before_initial_scripts(self):
        html = '<html><head><script src="/config.js"></script></head><body><script src="/app.js"></script></body></html>'

        rendered = inject_supabase_env(html, {"SUPA_URL": "https://example.supabase.co", "SUPA_KEY": "anon-key"})

        self.assertIn('window.__SUPABASE_ENV__ = {"SUPA_URL": "https://example.supabase.co", "SUPA_KEY": "anon-key"};', rendered)
        self.assertLess(rendered.index('window.__SUPABASE_ENV__'), rendered.index('/config.js'))

    def test_collect_metrics_includes_expected_fields(self):
        metrics = collect_metrics()

        self.assertEqual(metrics['service'], 'Onestop veggies ltd')
        self.assertEqual(metrics['version'], 'v1')
        self.assertIn('uptime_seconds', metrics)
        self.assertIn('request_counts', metrics)
        self.assertIsInstance(metrics['request_counts'], dict)
        self.assertGreaterEqual(metrics['request_counts'].get('total', 0), 0)

    def test_send_alert_without_webhook_does_not_raise(self):
        with patch('serve_sales_ledger.ALERT_WEBHOOK_URL', ''):
            with patch('serve_sales_ledger.MONITORING_EMAIL', ''):
                send_alert('Test Alert', 'This is a monitoring test.')

    def test_create_http_server_falls_back_to_an_available_port(self):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as occupied_socket:
            occupied_socket.bind(('127.0.0.1', 0))
            occupied_socket.listen(1)
            occupied_port = occupied_socket.getsockname()[1]

            server = create_http_server('127.0.0.1', occupied_port, SalesLedgerHandler)
            try:
                self.assertNotEqual(server.server_address[1], occupied_port)
            finally:
                server.server_close()

    def test_log_message_does_not_raise_for_http_access_logs(self):
        handler = SalesLedgerHandler.__new__(SalesLedgerHandler)
        handler.client_address = ('127.0.0.1', 12345)
        handler.requestline = 'GET /health HTTP/1.1'

        handler.log_message('"%s" %s %s', 'GET /health HTTP/1.1', 200, 123)


if __name__ == "__main__":
    unittest.main()
