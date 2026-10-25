import os
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]


@pytest.fixture(scope="session")
def db_tool() -> Path:
    """The Swift helper that runs the app's real database code."""
    tool = os.environ.get("VOICE_DB_TOOL")
    if tool:
        return Path(tool)
    package = REPO / "Packages" / "IruddVoiceKit"
    subprocess.run(["swift", "build", "--product", "voice-db-tool", "--package-path", str(package)],
                   check=True, capture_output=True)
    return package / ".build" / "debug" / "voice-db-tool"


@pytest.fixture
def app_db(tmp_path, db_tool) -> Path:
    path = tmp_path / "voice.sqlite"
    subprocess.run([db_tool, "create", path], check=True)
    return path


@pytest.fixture(autouse=True)
def no_app_database(tmp_path, monkeypatch):
    """Commands that record into the app's database by default (models
    prepare, train) must never reach the real one from a test."""
    from irudd_voice import db

    monkeypatch.setattr(db, "DEFAULT_PATH", tmp_path / "app-support" / "voice.sqlite")
