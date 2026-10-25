"""The unload lease and waiting for the app (shared/app-state.md)."""

import os
import signal
import subprocess
import sys
import time
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest
from labeling import rows

from irudd_voice import appstate, db


def state(path):
    return dict(rows(path, "SELECT key, value FROM app_state"))


def set_state(path, values: dict, at: datetime | None = None):
    con = db.connect(path, write=True)
    for key, value in values.items():
        appstate.write(con, key, value, at)
    con.close()


def test_lease_is_written_refreshed_and_released(app_db):
    with appstate.UnloadLease(app_db, refresh_seconds=0.05) as lease:
        first = state(app_db)[appstate.UNLOAD_UNTIL]
        until = datetime.fromisoformat(first)
        assert timedelta(seconds=115) < until - datetime.now(UTC) <= timedelta(seconds=120)
        assert first.endswith("Z") and len(first) == len("2026-10-25T10:00:00.000Z")
        deadline = time.monotonic() + 5
        while state(app_db)[appstate.UNLOAD_UNTIL] == first and time.monotonic() < deadline:
            time.sleep(0.05)
        assert state(app_db)[appstate.UNLOAD_UNTIL] > first
        assert lease.value == state(app_db)[appstate.UNLOAD_UNTIL]
    assert appstate.UNLOAD_UNTIL not in state(app_db)


def test_lease_is_released_when_the_work_fails(app_db):
    with pytest.raises(RuntimeError), appstate.UnloadLease(app_db):
        assert appstate.UNLOAD_UNTIL in state(app_db)
        raise RuntimeError("training failed")
    assert appstate.UNLOAD_UNTIL not in state(app_db)


def test_release_leaves_a_later_lease_alone(app_db):
    with appstate.UnloadLease(app_db):
        set_state(app_db, {appstate.UNLOAD_UNTIL: "2099-01-01T00:00:00.000Z"})
    assert state(app_db)[appstate.UNLOAD_UNTIL] == "2099-01-01T00:00:00.000Z"


def test_lease_is_released_on_sigterm(app_db, tmp_path):
    script = tmp_path / "hold.py"
    script.write_text(
        "import sys, time\n"
        "from pathlib import Path\n"
        "from irudd_voice import appstate\n"
        "with appstate.UnloadLease(Path(sys.argv[1])):\n"
        "    Path(sys.argv[2]).write_text('held')\n"
        "    time.sleep(60)\n")
    ready = tmp_path / "ready"
    process = subprocess.Popen([sys.executable, str(script), str(app_db), str(ready)])
    deadline = time.monotonic() + 20
    while not ready.exists() and time.monotonic() < deadline:
        time.sleep(0.05)
    assert appstate.UNLOAD_UNTIL in state(app_db)
    os.kill(process.pid, signal.SIGTERM)
    assert process.wait(timeout=20) == 143
    assert appstate.UNLOAD_UNTIL not in state(app_db)


class Clock:
    """A fake monotonic clock; sleep moves it and can run a hook."""

    def __init__(self, on_sleep=None):
        self.t = 0.0
        self.on_sleep = on_sleep

    def __call__(self):
        return self.t

    def sleep(self, seconds):
        self.t += seconds
        if self.on_sleep:
            self.on_sleep(self.t)


def wait(path, clock, now=None):
    lease = appstate.UnloadLease(path)
    return lease.wait_for_app(clock=clock, sleep=clock.sleep, now=now or (lambda: datetime.now(UTC)))


def test_no_status_means_the_app_never_loaded_a_model(app_db):
    assert wait(app_db, Clock()) == "the app has never loaded a cleanup model"


def test_confirmed_unload_goes_ahead(app_db):
    def confirm(t):
        if t >= 5:
            set_state(app_db, {appstate.STATUS: "unloaded-for-training", appstate.STATUS_AT: appstate.iso(
                datetime.now(UTC))})

    set_state(app_db, {appstate.STATUS: "loaded", appstate.STATUS_AT: appstate.iso(datetime.now(UTC))})
    clock = Clock(confirm)
    assert wait(app_db, clock) == "the app unloaded its model"
    assert clock.t == 5


def test_running_app_that_doesnt_confirm_stops_training(app_db):
    set_state(app_db, {appstate.STATUS: "loaded", appstate.STATUS_AT: appstate.iso(datetime.now(UTC))})
    clock = Clock()
    with pytest.raises(appstate.AppBusy, match="didn't unload its model within 60 s"):
        wait(app_db, clock)
    assert clock.t == 60


def test_old_unchanged_status_means_the_app_isnt_running(app_db):
    old = appstate.iso(datetime.now(UTC) - timedelta(hours=3))
    set_state(app_db, {appstate.STATUS: "loaded", appstate.STATUS_AT: old})
    clock = Clock()
    assert wait(app_db, clock) == "the app isn't running"
    assert clock.t == 60  # waited in case a running app reacts


def test_old_status_that_changes_while_waiting_is_a_running_app(app_db):
    old = appstate.iso(datetime.now(UTC) - timedelta(hours=3))
    set_state(app_db, {appstate.STATUS: "loaded", appstate.STATUS_AT: old})

    def busy(t):
        if t == 3:
            set_state(app_db, {appstate.STATUS: "loading", appstate.STATUS_AT: appstate.iso(datetime.now(UTC))})

    with pytest.raises(appstate.AppBusy):
        wait(app_db, Clock(busy))


def test_fresh_heartbeat_means_a_running_app_even_with_an_old_status(app_db):
    old = appstate.iso(datetime.now(UTC) - timedelta(hours=3))
    set_state(app_db, {appstate.STATUS: "loaded", appstate.STATUS_AT: old,
                       appstate.CHECKED_AT: appstate.iso(datetime.now(UTC))})
    with pytest.raises(appstate.AppBusy):
        wait(app_db, Clock())


def test_old_unchanged_heartbeat_means_the_app_isnt_running(app_db):
    old = appstate.iso(datetime.now(UTC) - timedelta(hours=3))
    set_state(app_db, {appstate.STATUS: "loaded", appstate.STATUS_AT: old, appstate.CHECKED_AT: old})
    assert wait(app_db, Clock()) == "the app isn't running"


def test_old_heartbeat_that_moves_while_waiting_is_a_running_app(app_db):
    old = appstate.iso(datetime.now(UTC) - timedelta(hours=3))
    set_state(app_db, {appstate.STATUS: "loaded", appstate.STATUS_AT: old, appstate.CHECKED_AT: old})

    def beat(t):
        if t == 10:
            set_state(app_db, {appstate.CHECKED_AT: appstate.iso(datetime.now(UTC))})

    with pytest.raises(appstate.AppBusy):
        wait(app_db, Clock(beat))


def test_loaded_model(app_db):
    assert appstate.loaded_model(app_db) is None
    set_state(app_db, {appstate.LOADED_MODEL: ""})
    assert appstate.loaded_model(app_db) is None
    set_state(app_db, {appstate.LOADED_MODEL: "gemma-4-e2b-ft-20261025-1"})
    assert appstate.loaded_model(Path(app_db)) == "gemma-4-e2b-ft-20261025-1"
