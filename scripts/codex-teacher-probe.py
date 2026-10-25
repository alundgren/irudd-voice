"""Checks, offline, that a Codex label run can't read your files.

    uv run --project cli python scripts/codex-teacher-probe.py

Uses the exact command `irudd-voice label --teacher codex` builds
(cli/src/irudd_voice/teacher.py) and makes no model call:

1. `codex sandbox` with the teacher's permission profile must fail to read
   this repo's README.md (in your home folder) and a file in $TMPDIR, and
   still read /etc/hosts (so the sandbox did run the command).
2. `codex exec` talks to a fake model server on 127.0.0.1 instead of
   OpenAI, with an empty CODEX_HOME. The fake model asks to run
   `head -c 20 README.md`:
   - with the label flags, Codex must offer no shell tool and run nothing;
   - with the --disable flags removed (only the profile left), the command
     runs but reading README.md must fail.

Exit code 0 when every check passes.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import ClassVar

from irudd_voice import teacher

REPO = Path(__file__).resolve().parents[1]
SECRET = REPO / "README.md"
SHELL_TOOLS = {"exec_command", "write_stdin", "shell", "local_shell", "view_image"}


def sandbox_check() -> list[str]:
    problems = []
    with tempfile.TemporaryDirectory(prefix=teacher.TEACHER_DIR_PREFIX) as folder, \
            tempfile.NamedTemporaryFile(prefix="irudd-voice-probe-", dir=os.environ.get("TMPDIR")) as other:
        overrides = [arg for setting in teacher.CODEX_PERMISSIONS for arg in ("-c", setting)]
        for path, readable in ((SECRET, False), (Path(other.name), False), (Path("/etc/hosts"), True)):
            run = subprocess.run(["codex", "sandbox", *overrides, "--", "/bin/sh", "-c", f'head -c 1 "{path}"'],
                                 capture_output=True, cwd=folder, check=False)
            ok = (run.returncode == 0) == readable
            print(f"sandbox: {'read' if run.returncode == 0 else 'denied'} {path.name}  {'OK' if ok else 'FAIL'}")
            if not ok:
                problems.append(f"codex sandbox {'could not read' if readable else 'read'} {path}")
    return problems


class FakeModel(BaseHTTPRequestHandler):
    """A Responses API endpoint: first asks for a shell command, then answers."""

    requests: ClassVar[list[dict]] = []

    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))) or b"{}")
        outputs = [i for i in body.get("input", []) if isinstance(i, dict) and i.get("type") == "function_call_output"]
        FakeModel.requests.append({"tools": [t.get("name") or t.get("type") for t in body.get("tools", [])],
                                   "outputs": [str(o.get("output")) for o in outputs]})
        if outputs:
            item = {"type": "message", "id": "msg_1", "role": "assistant", "status": "completed",
                    "content": [{"type": "output_text", "text": '{"cleaned": "done"}', "annotations": []}]}
        else:
            # Asked for even when Codex doesn't offer the tool.
            item = {"type": "function_call", "id": "fc_1", "call_id": "call_1", "name": "exec_command",
                    "arguments": json.dumps({"cmd": f'head -c 20 "{SECRET}" | wc -c'})}
        usage = {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2,
                 "input_tokens_details": {"cached_tokens": 0}, "output_tokens_details": {"reasoning_tokens": 0}}
        events = [
            {"type": "response.created", "response": {"id": f"resp_{len(outputs)}"}},
            {"type": "response.output_item.added", "output_index": 0, "item": item},
            {"type": "response.output_item.done", "output_index": 0, "item": item},
            {"type": "response.completed", "response": {"id": f"resp_{len(outputs)}", "usage": usage}},
        ]
        data = "".join(f"event: {e['type']}\ndata: {json.dumps(e)}\n\n" for e in events).encode()
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def exec_run(port: int, keep_disabled_features: bool) -> tuple[list[dict], list[dict]]:
    command = teacher.codex_command(teacher.schema_path())
    if not keep_disabled_features:
        command = [arg for i, arg in enumerate(command)
                   if arg != "--disable" and (i == 0 or command[i - 1] != "--disable")]
    local_model = ["-c", 'model_provider="probe"', "-c", 'model_providers.probe.name="probe"',
                   "-c", f'model_providers.probe.base_url="http://127.0.0.1:{port}/v1"',
                   "-c", 'model_providers.probe.wire_api="responses"',
                   "-c", "model_providers.probe.requires_openai_auth=false", "-c", 'model="probe-model"']
    command = command[:-1] + local_model + command[-1:]
    FakeModel.requests = []
    with tempfile.TemporaryDirectory(prefix="irudd-voice-probe-home-") as home, \
            tempfile.TemporaryDirectory(prefix=teacher.TEACHER_DIR_PREFIX) as folder:
        env = {k: v for k, v in os.environ.items() if k not in ("OPENAI_API_KEY", "CODEX_API_KEY")}
        env["CODEX_HOME"] = home
        run = subprocess.run(command, input="probe", capture_output=True, text=True, cwd=folder, env=env,
                             timeout=120, check=False)
    events = [json.loads(line) for line in run.stdout.splitlines() if line.startswith("{")]
    return events, list(FakeModel.requests)


def exec_checks() -> list[str]:
    problems = []
    server = HTTPServer(("127.0.0.1", 0), FakeModel)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        events, requests = exec_run(server.server_port, keep_disabled_features=True)
        offered = {tool for request in requests for tool in request["tools"]}
        ran = [e for e in events if (e.get("item") or {}).get("type") == "command_execution"]
        refused = any("unsupported call" in output for request in requests for output in request["outputs"])
        print(f"exec, label flags: tools offered {sorted(offered)}; commands run {len(ran)}; "
              f"forced call refused {refused}")
        if not requests:
            problems.append("codex exec never reached the fake model")
        if offered & SHELL_TOOLS or ran or not refused:
            problems.append("with the label flags Codex offered or ran a shell tool")

        events, requests = exec_run(server.server_port, keep_disabled_features=False)
        outputs = " ".join(e["item"].get("aggregated_output", "") for e in events
                           if (e.get("item") or {}).get("type") == "command_execution")
        denied = "Operation not permitted" in outputs
        print(f"exec, profile only (tools on): command ran {bool(outputs)}; README.md read denied {denied}")
        if not outputs or not denied:
            problems.append("with only the permission profile, the command could read README.md")
    finally:
        server.shutdown()
    return problems


def main() -> int:
    problems = sandbox_check() + exec_checks()
    for problem in problems:
        print(f"FAIL: {problem}", file=sys.stderr)
    print("All checks passed." if not problems else f"{len(problems)} check(s) failed.")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
