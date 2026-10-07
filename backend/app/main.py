"""FastAPI routes over the migrated PostgreSQL repository."""
import logging
import os
from contextlib import asynccontextmanager
from datetime import datetime
from uuid import UUID

import psycopg
from fastapi import FastAPI, Header, HTTPException, Request, Response
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field, field_validator
from redis import Redis
from redis.exceptions import RedisError
from starlette.middleware.trustedhost import TrustedHostMiddleware

from app import repository
from app.database import database
from app.security import LocalApiSecurity

logger = logging.getLogger(__name__)


class NoteInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    title: str = Field(min_length=1, max_length=200)
    content: str = Field(default="", max_length=50000)

    @field_validator("title", "content")
    @classmethod
    def reject_null_character(cls, value: str) -> str:
        if "\x00" in value:
            raise ValueError("Null characters are not allowed")
        return value

    @field_validator("title")
    @classmethod
    def clean_title(cls, value: str) -> str:
        if not value.strip():
            raise ValueError("Title cannot be blank")
        return value.strip()


class Note(BaseModel):
    id: UUID
    title: str
    content: str
    created_at: datetime
    updated_at: datetime


class Stats(BaseModel):
    writes: int | None
    redis_available: bool


def create_app(connection_factory=database, redis_client=None) -> FastAPI:
    owns_redis = redis_client is None
    activity = redis_client if redis_client is not None else Redis.from_url(
        os.environ.get("REDIS_URL", "redis://redis:6379/0"),
        socket_connect_timeout=2,
        socket_timeout=2,
    )

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        # Compose runs Alembic before startup; routes never modify the schema.
        try:
            yield
        finally:
            if owns_redis:
                activity.close()

    app = FastAPI(
        title="Notes API", version="1.0.0",
        description="Local notes stored in PostgreSQL, with Redis write activity.",
        lifespan=lifespan,
    )
    app.add_middleware(LocalApiSecurity)
    app.add_middleware(TrustedHostMiddleware, allowed_hosts=["localhost", "127.0.0.1", "api"], www_redirect=False)

    def expected_version(value):
        if value is None:
            return None
        try:
            if not (value.startswith('"') and value.endswith('"')):
                raise ValueError()
            version = datetime.fromisoformat(value[1:-1].replace("Z", "+00:00"))
            if version.tzinfo is None:
                raise ValueError()
            return version
        except ValueError:
            raise HTTPException(400, "Invalid note version")

    def set_etag(response, note):
        timestamp = Note.model_validate(note).model_dump(mode="json")["updated_at"]
        response.headers["ETag"] = f'"{timestamp}"'

    @app.exception_handler(psycopg.Error)
    async def database_error(request: Request, exc: psycopg.Error):
        # Return stable messages without disclosing SQL, credentials or note text.
        logger.error("Database request failed (%s)", type(exc).__name__)
        if isinstance(exc, (psycopg.OperationalError, psycopg.InterfaceError)):
            return JSONResponse(status_code=503, content={"detail": "Database is unavailable"})
        return JSONResponse(status_code=500, content={"detail": "Database operation failed"})

    def record_write():
        try:
            activity.incr("notes:write_count")
        except RedisError:
            # Called after commit. Metrics failure cannot undo a stored note.
            logger.warning("Redis write activity unavailable")

    @app.get("/api/health", tags=["system"])
    def health():
        try:
            with connection_factory() as conn:
                conn.execute("SELECT id FROM notes LIMIT 0")
            activity.ping()
        except (psycopg.Error, RedisError):
            raise HTTPException(503, "A dependency is unavailable")
        return {"status": "ok", "postgres": "ok", "redis": "ok"}

    @app.get("/api/stats", response_model=Stats, tags=["system"])
    def stats():
        try:
            writes = int(activity.get("notes:write_count") or 0)
            if writes < 0:
                raise ValueError("Invalid activity counter")
            return {"writes": writes, "redis_available": True}
        except (RedisError, ValueError):
            return {"writes": None, "redis_available": False}

    @app.get("/api/notes", response_model=list[Note], tags=["notes"])
    def list_notes():
        with connection_factory() as conn:
            return repository.list_notes(conn)

    @app.get("/api/notes/{note_id}", response_model=Note, tags=["notes"])
    def get_note(note_id: UUID, response: Response):
        with connection_factory() as conn:
            result = repository.get_note(conn, note_id)
        if result is None:
            raise HTTPException(404, "Note not found")
        set_etag(response, result)
        return result

    @app.post("/api/notes", response_model=Note, status_code=201, tags=["notes"])
    def create_note(note: NoteInput, response: Response):
        with connection_factory() as conn:
            result = repository.create_note(conn, note.title, note.content)
        record_write()
        response.headers["Location"] = f"/api/notes/{result['id']}"
        set_etag(response, result)
        return result

    @app.put("/api/notes/{note_id}", response_model=Note, tags=["notes"])
    def update_note(note_id: UUID, note: NoteInput, response: Response, if_match: str | None = Header(default=None)):
        version = expected_version(if_match)
        with connection_factory() as conn:
            result = repository.update_note(conn, note_id, note.title, note.content) if version is None else repository.update_note(conn, note_id, note.title, note.content, version)
            if result is None and version is not None and repository.get_note(conn, note_id) is not None:
                raise HTTPException(412, "This note changed elsewhere. Reload notes before saving or deleting.")
        if result is None:
            raise HTTPException(404, "Note not found")
        record_write()
        set_etag(response, result)
        return result

    @app.delete("/api/notes/{note_id}", status_code=204, tags=["notes"])
    def delete_note(note_id: UUID, if_match: str | None = Header(default=None)):
        version = expected_version(if_match)
        with connection_factory() as conn:
            result = repository.delete_note(conn, note_id) if version is None else repository.delete_note(conn, note_id, version)
            if result is None and version is not None and repository.get_note(conn, note_id) is not None:
                raise HTTPException(412, "This note changed elsewhere. Reload notes before saving or deleting.")
        if result is None:
            raise HTTPException(404, "Note not found")
        record_write()
        return Response(status_code=204)

    return app


app = create_app()
