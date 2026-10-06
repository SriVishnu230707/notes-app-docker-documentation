"""Parameterized note queries. The caller owns the connection/transaction."""


def create_note(conn, title: str, content: str = ""):
    return conn.execute(
        "INSERT INTO notes (title, content) VALUES (%s, %s) RETURNING *",
        (title, content),
    ).fetchone()


def list_notes(conn):
    return conn.execute(
        "SELECT * FROM notes ORDER BY updated_at DESC, id DESC"
    ).fetchall()


def get_note(conn, note_id):
    return conn.execute("SELECT * FROM notes WHERE id = %s", (note_id,)).fetchone()


def update_note(conn, note_id, title: str, content: str):
    # PostgreSQL's trigger maintains updated_at for every writer.
    return conn.execute(
        "UPDATE notes SET title = %s, content = %s WHERE id = %s RETURNING *",
        (title, content, note_id),
    ).fetchone()


def delete_note(conn, note_id):
    return conn.execute(
        "DELETE FROM notes WHERE id = %s RETURNING id", (note_id,)
    ).fetchone()
