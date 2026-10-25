"""The app's save path (driven by voice-db-tool) and the CLI, together."""

import json
import subprocess
import threading
import time

import soundfile

from irudd_voice import cli, db


def test_audio_is_saved_first_and_readable_while_the_app_writes(app_db, db_tool, capsys):
    # 3 thoughts of 2.5 s; the fake recognizer answers 600 ms after each ends.
    app = subprocess.Popen([db_tool, "record", app_db, "3", "2.5", "600"], stdout=subprocess.PIPE, text=True)
    seen_pending = False
    readings = 0
    while app.poll() is None:
        assert cli.main(["--db", str(app_db), "stats", "--json"]) == 0
        stats = json.loads(capsys.readouterr().out)
        readings += 1
        if stats["by_status"]["pending"]:
            seen_pending = True
        time.sleep(0.05)
    assert app.returncode == 0
    assert readings > 3
    assert seen_pending, "a row should be visible as pending before its text arrives"

    con = db.connect(app_db)
    rows = con.execute(
        "SELECT status, raw_text, duration_ms, audio, audio_format, audio_sample_rate, mic_uid, "
        "schema_version, app_version, started_at, ended_at FROM chunks ORDER BY id"
    ).fetchall()
    assert len(rows) == 3
    for index, (status, text, duration_ms, audio, fmt, rate, mic, schema, app_version, started, ended) in enumerate(rows):
        assert status == "transcribed"
        assert text == f"test thought {index}"
        assert fmt == "flac" and rate == 16000
        assert mic == "TEST-MIC" and schema == 1 and app_version and started and ended
        path = app_db.parent / f"chunk{index}.flac"
        path.write_bytes(audio)
        info = soundfile.info(path)
        assert info.samplerate == 16000 and info.channels == 1
        assert abs(info.frames / info.samplerate * 1000 - duration_ms) <= 50


def test_app_and_cli_write_at_the_same_time(app_db, db_tool):
    """1,000 interleaved writes: 500 from the app's code, 500 from the CLI."""
    app = subprocess.Popen([db_tool, "write-state", app_db, "500"])
    errors = []

    def cli_writes():
        try:
            con = db.connect(app_db, write=True)
            for i in range(500):
                with db.write_transaction(con):
                    con.execute("INSERT INTO app_state (key, value, updated_at) VALUES (?, ?, datetime('now'))",
                                (f"cli-{i}", str(i)))
        except Exception as error:  # reported below
            errors.append(error)

    writer = threading.Thread(target=cli_writes)
    writer.start()
    writer.join()
    assert app.wait() == 0
    assert not errors

    con = db.connect(app_db)
    assert con.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
    assert con.execute("SELECT COUNT(*) FROM app_state WHERE key LIKE 'app-%'").fetchone()[0] == 500
    assert con.execute("SELECT COUNT(*) FROM app_state WHERE key LIKE 'cli-%'").fetchone()[0] == 500
