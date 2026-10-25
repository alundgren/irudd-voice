"""The CLI's side of shared/app-state.md: the unload lease and the app's
cleanup status.

While `train` or `eval-compare` has a model in memory, it holds the
`cleanup.unload_until` lease so the app keeps its own model unloaded and
pastes raw text. A thread refreshes the lease every 30 s; leaving the
`with` block (finished, failed, Ctrl-C or SIGTERM) deletes it. If the CLI
is killed outright, the lease runs out by itself.
"""

from __future__ import annotations

import signal
import sys
import threading
import time
from datetime import UTC, datetime, timedelta
from pathlib import Path

from . import db
from .models import ModelError

UNLOAD_UNTIL = "cleanup.unload_until"
LOADED_MODEL = "cleanup.loaded_model"
STATUS = "cleanup.status"
STATUS_AT = "cleanup.status_at"
CHECKED_AT = "cleanup.checked_at"
UNLOADED_FOR_TRAINING = "unloaded-for-training"

LEASE_SECONDS = 120
REFRESH_SECONDS = 30
CONFIRM_SECONDS = 60
# A heartbeat older than this, which didn't change while we waited, means
# the app isn't running.
STALE_SECONDS = 120


class AppBusy(ModelError):
    """The app is running but didn't unload its model."""


def iso(at: datetime) -> str:
    """UTC ISO 8601 with milliseconds, like the app writes."""
    return at.astimezone(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def parse_iso(text: str | None) -> datetime | None:
    try:
        return datetime.fromisoformat(text) if text else None
    except ValueError:
        return None


def read(con, key: str) -> str | None:
    row = con.execute("SELECT value FROM app_state WHERE key = ?", (key,)).fetchone()
    return row[0] if row else None


def write(con, key: str, value: str, now: datetime | None = None) -> None:
    with db.write_transaction(con):
        con.execute(
            "INSERT INTO app_state (key, value, updated_at) VALUES (?, ?, ?) "
            "ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
            (key, value, iso(now or datetime.now(UTC))))


def loaded_model(path: Path) -> str | None:
    """The model the app's helper has loaded, or None (nothing loaded or
    the app never said)."""
    con = db.connect(path)
    try:
        return read(con, LOADED_MODEL) or None
    finally:
        con.close()


class UnloadLease:
    """`with UnloadLease(path) as lease: lease.wait_for_app(); ...`"""

    def __init__(self, path: Path, *, lease_seconds: float = LEASE_SECONDS, refresh_seconds: float = REFRESH_SECONDS,
                 log=print):
        self.path = path
        self.lease_seconds = lease_seconds
        self.refresh_seconds = refresh_seconds
        self.log = log
        self.value: str | None = None
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._previous_sigterm = None

    def _write(self, con) -> None:
        value = iso(datetime.now(UTC) + timedelta(seconds=self.lease_seconds))
        write(con, UNLOAD_UNTIL, value)
        self.value = value

    def _refresh(self) -> None:
        con = db.connect(self.path, write=True)
        try:
            while not self._stop.wait(self.refresh_seconds):
                try:
                    self._write(con)
                except Exception as error:  # a locked database; try again next time
                    self.log(f"couldn't refresh the unload lease: {error}")
        finally:
            con.close()

    def __enter__(self) -> UnloadLease:
        con = db.connect(self.path, write=True)
        try:
            self._write(con)
        finally:
            con.close()
        # SIGTERM normally ends Python without running `finally`; turn it
        # into SystemExit so the lease is released.
        if threading.current_thread() is threading.main_thread():
            self._previous_sigterm = signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
        self._thread = threading.Thread(target=self._refresh, name="unload-lease", daemon=True)
        self._thread.start()
        return self

    def __exit__(self, *exc) -> None:
        self.release()

    def release(self) -> None:
        self._stop.set()
        if self._thread:
            self._thread.join()
            self._thread = None
        if self._previous_sigterm is not None:
            signal.signal(signal.SIGTERM, self._previous_sigterm)
            self._previous_sigterm = None
        if self.value is None:
            return
        try:
            con = db.connect(self.path, write=True)
            try:
                with db.write_transaction(con):
                    # Only our own lease: another CLI run may have written a later one.
                    con.execute("DELETE FROM app_state WHERE key = ? AND value = ?", (UNLOAD_UNTIL, self.value))
            finally:
                con.close()
            self.value = None
        except Exception as error:
            self.log(f"couldn't remove the unload lease ({error}); the app reloads its model when it runs out")

    def wait_for_app(self, timeout: float | None = None, stale: float | None = None, poll: float = 1.0,
                     clock=time.monotonic, sleep=time.sleep, now=lambda: datetime.now(UTC)) -> str:
        """Waits for the app to confirm it unloaded its model (shared/app-state.md,
        "Starting training"). Returns why it's safe to go on, or raises AppBusy.

        The heartbeat is `cleanup.checked_at`, which a running app writes at
        least every 10 s, or `cleanup.status_at` from an app that doesn't
        write it yet. It only counts as "the app isn't running" when it's
        older than `stale` and stays unchanged for the whole wait: a running
        app that loaded its model hours ago has an old `status_at`, but it
        checks the lease at idle and would have answered.
        """
        timeout = CONFIRM_SECONDS if timeout is None else timeout
        stale = STALE_SECONDS if stale is None else stale
        con = db.connect(self.path)
        try:
            deadline = clock() + timeout
            first_beat = read(con, CHECKED_AT) or read(con, STATUS_AT)
            while True:
                status, beat = read(con, STATUS), read(con, CHECKED_AT) or read(con, STATUS_AT)
                if status == UNLOADED_FOR_TRAINING:
                    return "the app unloaded its model"
                if status is None:
                    return "the app has never loaded a cleanup model"
                if clock() >= deadline:
                    beat_at = parse_iso(beat)
                    if beat == first_beat and (beat_at is None or (now() - beat_at).total_seconds() > stale):
                        return "the app isn't running"
                    raise AppBusy(f"the app is running but didn't unload its model within {timeout:.0f} s "
                                  f"(its status is {status!r}). Wait until no thought is in progress and try "
                                  "again, or quit irudd-voice.")
                sleep(poll)
        finally:
            con.close()
