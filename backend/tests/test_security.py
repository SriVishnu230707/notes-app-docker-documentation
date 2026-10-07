"""Exercise request boundaries using actual ASGI body chunks and stalled input."""
import asyncio
import unittest
from unittest.mock import AsyncMock, patch

from app.security import LocalApiSecurity


class RequestBodyTests(unittest.IsolatedAsyncioTestCase):
    async def run_request(self, receive):
        app = AsyncMock()
        sent = []

        async def send(message):
            sent.append(message)

        scope = {"type": "http", "method": "POST", "scheme": "http", "path": "/api/notes",
                 "headers": [(b"host", b"localhost"), (b"content-type", b"application/json")]}
        await LocalApiSecurity(app)(scope, receive, send)
        app.assert_not_called()
        return sent[0]["status"]

    async def test_chunked_body_is_limited_without_content_length(self):
        receive = AsyncMock(side_effect=[
            {"type": "http.request", "body": b"x" * 600000, "more_body": True},
            {"type": "http.request", "body": b"x" * 600000, "more_body": False},
        ])
        self.assertEqual(await self.run_request(receive), 413)

    async def test_stalled_body_times_out_before_application_runs(self):
        async def receive():
            await asyncio.sleep(1)

        with patch("app.security.BODY_TIMEOUT_SECONDS", 0.01):
            self.assertEqual(await self.run_request(receive), 408)
