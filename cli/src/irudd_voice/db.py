"""Opening the app's database.

The Swift app is the only process that creates or migrates the schema
(PRAGMA user_version). The CLI checks the version: it refuses to write to a
version it doesn't know, and warns when reading one.
"""

from __future__ import annotations

import contextlib
import sqlite3
import sys
from collections.abc import Iterator
from pathlib import Path

SCHEMA_VERSION = 1
DEFAULT_PATH = Path.home() / "Library" / "Application Support" / "irudd-voice" / "voice.sqlite"
BUSY_TIMEOUT_MS = 10_000


class SchemaError(Exception):
    """The database is missing or has a schema version this CLI can't use."""


def connect(path: Path | str = DEFAULT_PATH, *, write: bool = False) -> sqlite3.Connection:
    path = Path(path)
    if not path.exists():
        raise SchemaError(f"No database at {path} yet. Open irudd-voice and dictate once.")
    if write:
        con = sqlite3.connect(path, timeout=BUSY_TIMEOUT_MS / 1000, isolation_level=None)
    else:
        con = sqlite3.connect(f"{path.as_uri()}?mode=ro", uri=True, timeout=BUSY_TIMEOUT_MS / 1000,
                              isolation_level=None)
    con.execute(f"PRAGMA busy_timeout = {BUSY_TIMEOUT_MS}")
    con.execute("PRAGMA foreign_keys = ON")
    version = con.execute("PRAGMA user_version").fetchone()[0]
    if version == 0:
        con.close()
        raise SchemaError("The app hasn't set up this database yet. Open irudd-voice once.")
    if version != SCHEMA_VERSION:
        message = (
            f"The database is schema version {version}, but this CLI knows version {SCHEMA_VERSION}. "
            "Update the CLI and the app to the same version."
        )
        if write:
            con.close()
            raise SchemaError(message + " Nothing was written.")
        print(f"warning: {message}", file=sys.stderr)
    return con


@contextlib.contextmanager
def write_transaction(con: sqlite3.Connection) -> Iterator[sqlite3.Connection]:
    """BEGIN IMMEDIATE: take the write lock up front (waiting up to the busy
    timeout while the app writes), so the transaction can't fail halfway."""
    con.execute("BEGIN IMMEDIATE")
    try:
        yield con
    except BaseException:
        con.execute("ROLLBACK")
        raise
    else:
        con.execute("COMMIT")


def size_on_disk(path: Path | str = DEFAULT_PATH) -> int:
    """The database file plus its write-ahead log, like the app shows."""
    path = Path(path)
    return sum(p.stat().st_size for p in (path, Path(f"{path}-wal")) if p.exists())
