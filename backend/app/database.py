"""Shared PostgreSQL connection configuration; credentials stay in the environment."""
import os

import psycopg
from psycopg.rows import dict_row
from sqlalchemy import URL


def database():
    """Use as a context manager: commit on success, roll back on error, then close."""
    return psycopg.connect(
        row_factory=dict_row, connect_timeout=5,
        options="-c statement_timeout=10000 -c lock_timeout=5000",
    )


def migration_url() -> URL:
    # URL.create safely handles special characters in credentials.
    return URL.create(
        "postgresql+psycopg",
        username=os.environ["PGUSER"],
        password=os.environ["PGPASSWORD"],
        host=os.environ["PGHOST"],
        port=int(os.environ.get("PGPORT", "5432")),
        database=os.environ["PGDATABASE"],
    )
