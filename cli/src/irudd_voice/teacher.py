"""Teacher runs: ask Claude Code or Codex what a transcript should have been.

`call` is the contained runner; `ask` uses it for labels and judge.py for
the blind votes in `eval-compare`. Each call runs from a fresh, empty temporary folder with tools, MCP servers,
hooks and session saving off. The teacher sees only the transcript and the
vocabulary. The folder name starts with TEACHER_DIR_PREFIX and the prompt
starts with the teacher prompt's marker, so `irudd-voice vocab` can skip any
log a teacher run leaves behind.
"""

from __future__ import annotations

import contextlib
import json
import os
import re
import shutil
import signal
import subprocess
import tempfile
from collections.abc import Callable
from dataclasses import dataclass
from functools import cache
from pathlib import Path

from . import prompt

TEACHER_DIR_PREFIX = "irudd-voice-teacher-"
TIMEOUT_SECONDS = 300
TEACHERS = ("claude", "codex")
CALL_FAILURES = ("teacher_error", "timeout")

# Codex event items allowed in a label run. Any other item (a command, file
# change, MCP, web, image or agent call, or a type added later) rejects the
# label as `ran_command`.
CODEX_ANSWER_ITEMS = {"agent_message", "reasoning", "todo_list", "error"}

# Codex features that give the model tools, turned off for every label run
# (`codex features list` shows them on by default in codex-cli 0.164.0).
# `features list` still shows unified_exec on after --disable, but with
# shell_tool off Codex offers no exec_command tool and answers a forced call
# with "unsupported call" (scripts/codex-teacher-probe.py checks this).
CODEX_DISABLED_FEATURES = (
    "shell_tool", "unified_exec", "view_image", "image_generation", "multi_agent", "plugins", "apps",
    "hooks", "computer_use", "browser_use", "goals",
)

# A Codex permission profile for anything that does run: system files only
# (":minimal"), no /tmp, no network. The home folder, the repo, the database
# and other temp files can't be read. Passed with -c because the user's
# config.toml is ignored. It replaces `-s read-only`: when both are given,
# -s wins and the home folder is readable again.
CODEX_PERMISSION_PROFILE = "irudd_voice_teacher"
CODEX_PERMISSIONS = (
    f'default_permissions="{CODEX_PERMISSION_PROFILE}"',
    f'permissions.{CODEX_PERMISSION_PROFILE}.filesystem={{":minimal"="read", ":slash_tmp"="none"}}',
    f"permissions.{CODEX_PERMISSION_PROFILE}.network.enabled=false",
)


@cache
def load(path: Path | None = None) -> dict:
    return json.loads((path or prompt.SHARED / "teacher-prompt.json").read_text())


def schema_path(teacher_prompt: dict | None = None) -> Path:
    return prompt.SHARED / (teacher_prompt or load())["reply_schema"]


def messages(transcript: str, terms: list[str] | tuple[str, ...] = (), teacher_prompt: dict | None = None,
             cleanup_prompt: dict | None = None) -> tuple[str, str]:
    """(system, user) for one label. The cleanup rules and vocabulary come
    from the cleanup prompt, so the teacher follows the model's rules."""
    teacher_prompt = teacher_prompt or load()
    cleanup = cleanup_prompt or prompt.load(prompt.SHARED / teacher_prompt["cleanup_prompt"])
    cleanup_system = prompt.messages(transcript, terms, cleanup)[0]["content"]
    system = teacher_prompt["system_before"] + cleanup_system + teacher_prompt["system_after"]
    user = prompt.fill(teacher_prompt["user_template"], {
        "marker": teacher_prompt["marker"],
        "input_json": prompt.input_json(transcript),
        "rule": cleanup["rule"],
    })
    return system, user


def valid_reply(value: object, schema: dict) -> bool:
    """Checks a parsed reply against the reply schema. Handles what
    the reply schemas use: an object, typed properties, enums, required
    keys and no extra keys."""
    if schema.get("type") != "object" or not isinstance(value, dict):
        return False
    properties = schema.get("properties", {})
    if any(key not in value for key in schema.get("required", [])):
        return False
    if schema.get("additionalProperties") is False and set(value) - set(properties):
        return False
    types = {"string": str, "object": dict, "array": list, "boolean": bool}
    return all(isinstance(value[key], types[spec["type"]]) and value[key] in spec.get("enum", [value[key]])
               for key, spec in properties.items() if key in value)


@dataclass
class Answer:
    """What one teacher call produced. `cleaned` is the value read from the
    reply (the label, or the judge's pick), None when the reply can't be
    used; `failure` then says why. CALL_FAILURES mean the call itself
    failed, so there is no reply to judge."""

    cleaned: str | None
    failure: str | None
    model: str | None = None
    cost_usd: float | None = None
    input_tokens: int | None = None
    output_tokens: int | None = None
    detail: str | None = None


# Reads a reply: (reply text, already-parsed structured output) ->
# (value, None) or (None, failure).
Reader = Callable[[str | None, object], tuple[str | None, str | None]]


def read_object(text: str | None, structured: object, schema_file: Path) -> dict | None:
    """The reply object from its text (JSON, optionally in a ``` fence) or
    the already-parsed structured output; None unless it fits the schema."""
    value = structured
    if value is None:
        stripped = (text or "").strip()
        fence = re.fullmatch(r"```(?:json)?\s*(.*?)\s*```", stripped, flags=re.DOTALL)
        if fence:
            stripped = fence.group(1)
        try:
            value = json.loads(stripped)
        except json.JSONDecodeError:
            return None
    return value if valid_reply(value, json.loads(schema_file.read_text())) else None


def read_cleaned(text: str | None, structured: object = None) -> tuple[str | None, str | None]:
    """The label from a teacher's reply."""
    value = read_object(text, structured, schema_path())
    if value is None:
        return None, "malformed"
    cleaned = value["cleaned"].strip()
    return (cleaned, None) if cleaned else (None, "empty")


def claude_command(system: str, schema: dict, model: str | None = None, executable: str = "claude") -> list[str]:
    command = [
        executable, "-p",
        "--tools", "",
        "--strict-mcp-config",
        "--no-session-persistence",
        "--disable-slash-commands",
        "--safe-mode",
        "--settings", '{"disableAllHooks":true}',
        "--system-prompt", system,
        "--json-schema", json.dumps(schema, separators=(",", ":")),
        "--output-format", "json",
    ]
    if model:
        command += ["--model", model]
    return command


def codex_command(schema_file: Path, model: str | None = None, executable: str = "codex") -> list[str]:
    command = [
        executable, "exec",
        "--ephemeral",
        "--ignore-user-config",
        "--skip-git-repo-check",
        "--output-schema", str(schema_file),
        "--json",
        "--color", "never",
        "-c", 'web_search="disabled"',
    ]
    for setting in CODEX_PERMISSIONS:
        command += ["-c", setting]
    for feature in CODEX_DISABLED_FEATURES:
        command += ["--disable", feature]
    if model:
        command += ["-m", model]
    return command + ["-"]  # the prompt comes on stdin


def read_claude(stdout: str, read: Reader = read_cleaned) -> Answer:
    """Claude's --output-format json: one result object."""
    try:
        result = json.loads(stdout)
    except json.JSONDecodeError:
        return Answer(None, "teacher_error")
    if not isinstance(result, dict):
        return Answer(None, "teacher_error")
    usage = result.get("usage") or {}
    model_usage = result.get("modelUsage") or {}
    model = max(model_usage, key=lambda m: (model_usage[m] or {}).get("outputTokens", 0)) if model_usage else None
    input_tokens = None
    if usage:
        input_tokens = sum(usage.get(key) or 0 for key in
                           ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
    answer = Answer(None, None, model=model, cost_usd=result.get("total_cost_usd"),
                    input_tokens=input_tokens, output_tokens=usage.get("output_tokens"))
    if result.get("is_error") or result.get("subtype") not in (None, "success"):
        answer.failure = "teacher_error"
        return answer
    answer.cleaned, answer.failure = read(result.get("result"), result.get("structured_output"))
    return answer


def read_codex(stdout: str, model: str | None = None, read: Reader = read_cleaned) -> Answer:
    """Codex's --json: one event per line. The last agent message is the
    reply; any item outside CODEX_ANSWER_ITEMS rejects the label."""
    answer = Answer(None, None, model=model)
    last_message = None
    used_tool = failed = False
    input_tokens = output_tokens = None
    for line in stdout.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(event, dict):
            continue
        kind = event.get("type", "")
        item = event.get("item") or {}
        if kind.startswith("item.") and item.get("type") not in CODEX_ANSWER_ITEMS:
            used_tool = True
        if kind == "item.completed" and item.get("type") == "agent_message":
            last_message = item.get("text")
        if kind == "turn.completed":
            usage = event.get("usage") or {}
            input_tokens = (input_tokens or 0) + (usage.get("input_tokens") or 0)
            output_tokens = (output_tokens or 0) + (usage.get("output_tokens") or 0)
        if kind in ("turn.failed", "error"):
            failed = True
    answer.input_tokens, answer.output_tokens = input_tokens, output_tokens
    if used_tool:
        answer.failure = "ran_command"
    elif failed or last_message is None:
        answer.failure = "teacher_error"
    else:
        answer.cleaned, answer.failure = read(last_message, None)
    return answer


def command(teacher: str, system: str, model: str | None = None, executable: str | None = None,
            schema_file: Path | None = None) -> list[str]:
    schema_file = schema_file or schema_path()
    if teacher == "claude":
        return claude_command(system, json.loads(schema_file.read_text()), model, executable or "claude")
    return codex_command(schema_file, model, executable or "codex")


def _kill_group(process: subprocess.Popen) -> None:
    with contextlib.suppress(ProcessLookupError):
        os.killpg(process.pid, signal.SIGKILL)
    with contextlib.suppress(Exception):
        process.communicate(timeout=10)


def ask(teacher: str, transcript: str, terms: list[str] | tuple[str, ...] = (), model: str | None = None,
        timeout: float | None = None) -> Answer:
    """One label."""
    system, user = messages(transcript, terms)
    return call(teacher, system, user, schema_path(), read_cleaned, model, timeout)


def call(teacher: str, system: str, user: str, schema_file: Path, read: Reader, model: str | None = None,
         timeout: float | None = None) -> Answer:
    """One contained teacher call: `user` must start with the teacher
    prompt's marker; the reply has to fit `schema_file` and is read with
    `read`."""
    timeout = timeout or TIMEOUT_SECONDS
    executable = shutil.which(teacher)
    if executable is None:
        raise FileNotFoundError(f"`{teacher}` isn't on PATH.")
    with tempfile.TemporaryDirectory(prefix=TEACHER_DIR_PREFIX) as folder:
        # Codex has no system-prompt flag, so both parts go in its prompt.
        stdin = user if teacher == "claude" else system + "\n\n" + user
        # claude and codex are shims that start the real CLI as a child, so
        # each call gets its own process group and a timeout kills all of it.
        process = subprocess.Popen(command(teacher, system, model, executable, schema_file), stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd=folder,
                                   start_new_session=True)
        try:
            stdout, stderr = process.communicate(stdin, timeout=timeout)
        except subprocess.TimeoutExpired:
            _kill_group(process)
            return Answer(None, "timeout", model=model, detail=f"no answer after {timeout:.0f} s")
        except BaseException:
            # Ctrl-C reaches only this process (the teacher has its own
            # session), so stop the teacher before passing it on.
            _kill_group(process)
            raise
    answer = read_claude(stdout, read) if teacher == "claude" else read_codex(stdout, model, read)
    if process.returncode != 0 and answer.failure is None:
        answer.cleaned, answer.failure = None, "teacher_error"
    if answer.failure == "teacher_error":
        lines = (stderr or "").strip().splitlines()
        answer.detail = f"exit code {process.returncode}" + (f": {lines[-1][:200]}" if lines else "")
    return answer
