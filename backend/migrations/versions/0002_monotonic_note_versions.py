"""Ensure note versions advance even for simultaneous or waiting updates."""
from alembic import op

revision = "0002_monotonic_note_versions"
down_revision = "0001_create_notes"
branch_labels = None
depends_on = None


def upgrade():
    op.execute("""
        CREATE OR REPLACE FUNCTION set_notes_updated_at() RETURNS trigger
        LANGUAGE plpgsql AS $$
        BEGIN
            NEW.updated_at = GREATEST(clock_timestamp(), OLD.updated_at + interval '1 microsecond');
            RETURN NEW;
        END;
        $$
    """)


def downgrade():
    op.execute("""
        CREATE OR REPLACE FUNCTION set_notes_updated_at() RETURNS trigger
        LANGUAGE plpgsql AS $$
        BEGIN
            NEW.updated_at = statement_timestamp();
            RETURN NEW;
        END;
        $$
    """)
