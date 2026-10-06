"""Create durable notes storage with database-enforced validation."""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision = "0001_create_notes"
down_revision = None
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "notes",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True,
                  server_default=sa.text("gen_random_uuid()")),
        sa.Column("title", sa.String(200), nullable=False),
        sa.Column("content", sa.Text(), nullable=False, server_default=""),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False,
                  server_default=sa.text("now()")),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False,
                  server_default=sa.text("now()")),
        sa.CheckConstraint("title ~ '[^[:space:]]'", name="notes_title_not_blank"),
        sa.CheckConstraint("char_length(content) <= 50000", name="notes_content_length"),
    )
    op.execute("CREATE INDEX notes_updated_order_idx ON notes (updated_at DESC, id DESC)")
    op.execute("""
        CREATE FUNCTION set_notes_updated_at() RETURNS trigger
        LANGUAGE plpgsql AS $$
        BEGIN
            NEW.updated_at = statement_timestamp();
            RETURN NEW;
        END;
        $$
    """)
    op.execute("""
        CREATE TRIGGER notes_set_updated_at
        BEFORE UPDATE ON notes
        FOR EACH ROW EXECUTE FUNCTION set_notes_updated_at()
    """)


def downgrade():
    # Explicit downgrade is destructive: the caller must back up notes first.
    op.drop_table("notes")
    op.execute("DROP FUNCTION set_notes_updated_at()")
