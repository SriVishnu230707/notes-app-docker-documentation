"""Local API request boundaries, independent of the Nginx proxy."""
import asyncio
from urllib.parse import urlsplit

from starlette.datastructures import Headers
from starlette.responses import JSONResponse

MAX_BODY_BYTES = 1024 * 1024
BODY_TIMEOUT_SECONDS = 15


def origin_key(value):
    try:
        url = urlsplit(value)
        if url.scheme not in ("http", "https") or not url.hostname or url.username or url.password or url.path or url.query or url.fragment:
            return None
        return url.scheme, url.hostname.lower(), url.port or (443 if url.scheme == "https" else 80)
    except ValueError:
        return None


class LocalApiSecurity:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        headers = Headers(scope=scope)
        method = scope["method"]

        async def secure_send(message):
            if message["type"] == "http.response.start":
                message["headers"] = list(message.get("headers", [])) + [
                    (b"x-content-type-options", b"nosniff"),
                    (b"x-frame-options", b"DENY"),
                    (b"referrer-policy", b"no-referrer"),
                    (b"cache-control", b"no-store"),
                ]
            await send(message)

        async def reject(status, detail):
            await JSONResponse({"detail": detail}, status_code=status)(scope, receive, secure_send)

        # Host is checked by the outer TrustedHostMiddleware. Retain the proxy's
        # original port so same-origin browser requests remain valid through Nginx.
        if method not in ("GET", "HEAD", "OPTIONS"):
            origin = headers.get("origin")
            expected = origin_key(f'{scope["scheme"]}://{headers.get("host", "")}')
            if headers.get("sec-fetch-site") == "cross-site" or (origin is not None and (origin_key(origin) is None or origin_key(origin) != expected)):
                return await reject(403, "Cross-origin writes are not allowed")

        if method in ("POST", "PUT", "PATCH"):
            if headers.get("content-type", "").split(";", 1)[0].strip().lower() != "application/json":
                return await reject(415, "Use application/json for note writes")
            length = headers.get("content-length")
            if length is not None:
                try:
                    size = int(length)
                    if size < 0:
                        raise ValueError()
                except ValueError:
                    return await reject(400, "Invalid Content-Length")
                if size > MAX_BODY_BYTES:
                    return await reject(413, "Request body exceeds 1 MiB")
            chunks = []
            size = 0
            deadline = asyncio.get_running_loop().time() + BODY_TIMEOUT_SECONDS
            while True:
                try:
                    remaining = max(0, deadline - asyncio.get_running_loop().time())
                    message = await asyncio.wait_for(receive(), timeout=remaining)
                except asyncio.TimeoutError:
                    return await reject(408, "Request body timed out")
                if message["type"] == "http.disconnect":
                    return
                chunk = message.get("body", b"")
                size += len(chunk)
                if size > MAX_BODY_BYTES:
                    return await reject(413, "Request body exceeds 1 MiB")
                chunks.append(chunk)
                if not message.get("more_body", False):
                    break
            body = b"".join(chunks)
            consumed = False

            async def buffered_receive():
                nonlocal consumed
                if not consumed:
                    consumed = True
                    return {"type": "http.request", "body": body, "more_body": False}
                return await receive()

            return await self.app(scope, buffered_receive, secure_send)
        await self.app(scope, receive, secure_send)
