"""Offline tests for the GNOME Online Accounts Tasks backend."""

import importlib.util
from importlib.machinery import SourceFileLoader
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
LOADER = SourceFileLoader("goa_tasks", str(ROOT / "bin" / "goa-tasks"))
SPEC = importlib.util.spec_from_loader("goa_tasks", LOADER)
goa_tasks = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(goa_tasks)


class GoaTasksTests(unittest.TestCase):
    def setUp(self):
        goa_tasks._tokens.clear()

    def test_records_only_google_accounts_with_safe_identities(self):
        objects = {
            "/google": {
                goa_tasks.GOA + ".Account": {
                    "ProviderType": {"data": "google"},
                    "PresentationIdentity": {"data": "google@example.com"},
                }
            },
            "/other": {
                goa_tasks.GOA + ".Account": {
                    "ProviderType": {"data": "microsoft"},
                    "PresentationIdentity": {"data": "other@example.com"},
                }
            },
            "/unsafe": {
                goa_tasks.GOA + ".Account": {
                    "ProviderType": {"data": "google"},
                    "PresentationIdentity": {"data": "bad\naccount"},
                }
            },
        }
        self.assertEqual(
            goa_tasks._records_from_objects(objects),
            [{"email": "google@example.com", "path": "/google"}],
        )

    def test_status_does_not_request_a_token(self):
        with patch.object(
            goa_tasks,
            "goa_accounts",
            return_value=[{"email": "google@example.com", "path": "/google"}],
        ), patch.object(goa_tasks, "access_token") as token:
            self.assertEqual(
                goa_tasks.main(["status"]),
                {"accounts": ["google@example.com"]},
            )
            token.assert_not_called()

    def test_tasks_api_url_is_scoped_and_authorized(self):
        with patch.object(goa_tasks, "access_token", return_value="test-token"), patch.object(
            goa_tasks, "request", return_value={"items": []}
        ) as request:
            goa_tasks.api(
                {"email": "google@example.com", "path": "/google"},
                "/users/@me/lists",
                {"maxResults": 100, "showCompleted": True},
            )
            url, token, payload, method = request.call_args.args
            self.assertEqual(token, "test-token")
            self.assertIsNone(payload)
            self.assertIsNone(method)
            self.assertEqual(
                url,
                "https://tasks.googleapis.com/tasks/v1/users/@me/lists?maxResults=100&showCompleted=true",
            )

    def test_task_pages_follow_next_page_token(self):
        pages = [
            {"items": [{"id": "a"}], "nextPageToken": "next"},
            {"items": [{"id": "b"}]},
        ]
        with patch.object(goa_tasks, "api", side_effect=pages) as api:
            result = goa_tasks._task_pages(
                {"email": "google@example.com", "path": "/google"},
                "LIST",
                {"tasklist": "LIST", "maxResults": 100},
                3,
            )
        self.assertEqual([item["id"] for page in result for item in page["items"]], ["a", "b"])
        self.assertEqual(api.call_count, 2)

    def test_api_requires_a_google_account(self):
        with patch.object(goa_tasks, "goa_accounts", return_value=[]):
            with self.assertRaisesRegex(RuntimeError, "No Google account"):
                goa_tasks._account()


if __name__ == "__main__":
    unittest.main()
