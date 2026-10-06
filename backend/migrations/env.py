"""Run explicit migrations using the same PG environment as the application."""
from alembic import context
from sqlalchemy import create_engine, pool

from app.database import migration_url


if context.is_offline_mode():
    context.configure(
        url=migration_url(), literal_binds=True, dialect_opts={"paramstyle": "named"}
    )
    with context.begin_transaction():
        context.run_migrations()
else:
    engine = create_engine(
        migration_url(), poolclass=pool.NullPool, connect_args={"connect_timeout": 5}
    )
    with engine.connect() as connection:
        context.configure(connection=connection)
        with context.begin_transaction():
            # Serialize concurrent migration runners before reading the revision.
            connection.exec_driver_sql("SELECT pg_advisory_xact_lock(7310262007)")
            context.run_migrations()
    engine.dispose()
