import json
import sqlite3
import subprocess

import pytest

from irudd_voice import cli, db


def test_reads_the_apps_schema(app_db, capsys):
    assert cli.main(["--db", str(app_db), "stats", "--json"]) == 0
    stats = json.loads(capsys.readouterr().out)
    assert stats["schema_version"] == db.SCHEMA_VERSION
    assert stats["thoughts"] == 0


def test_refuses_to_write_an_unknown_version(app_db, db_tool):
    subprocess.run([db_tool, "set-version", app_db, "2"], check=True)
    with pytest.raises(db.SchemaError, match="schema version 2.*Nothing was written"):
        db.connect(app_db, write=True)


def test_never_creates_a_database(tmp_path):
    missing = tmp_path / "voice.sqlite"
    with pytest.raises(db.SchemaError, match="No database"):
        db.connect(missing, write=True)
    assert not missing.exists()


def test_refuses_an_unmigrated_database(tmp_path):
    path = tmp_path / "voice.sqlite"
    sqlite3.connect(path).close()
    with pytest.raises(db.SchemaError, match="hasn't set up"):
        db.connect(path, write=True)


def test_stats_reports_a_missing_database(tmp_path, capsys):
    assert cli.main(["--db", str(tmp_path / "nope.sqlite"), "stats"]) == 1
    assert "No database" in capsys.readouterr().err
