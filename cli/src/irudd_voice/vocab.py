"""`irudd-voice vocab`: the vocabulary list, mined from coding-agent logs.

Reads only what the user typed (user messages) in:

- Claude Code: ~/.claude/projects/<project>/<session>.jsonl (lines with
  `type` "user"; tool results, meta lines, subagent sidechains and
  system-sent prompts are skipped).
- Codex: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl (`response_item`
  messages with role "user"; injected AGENTS.md and environment blocks are
  skipped).
- Cursor agent: ~/.cursor/projects/<project>/agent-transcripts/**/*.jsonl
  (lines with role "user"; the text inside <user_query>).
- Cursor app: ~/Library/Application Support/Cursor/User/globalStorage/
  state.vscdb (`cursorDiskKV` rows `bubbleId:*` with type 1 = user).

Any source that's missing is skipped. Sessions from teacher runs are
skipped: their folder starts with teacher.TEACHER_DIR_PREFIX, or a message
contains the teacher prompt's marker.

Only terms are kept, never messages: project names, tool names and
identifiers (words with dots, dashes, underscores or digits, camelCase,
PascalCase, all-caps) and lowercase words that aren't in the system
dictionary. Terms are ranked by how many sessions use them.
"""

from __future__ import annotations

import argparse
import json
import re
import sqlite3
from collections import Counter
from collections.abc import Iterator
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path

from . import prompt, teacher

VERSION = 1
DEFAULT_PATH = Path.home() / "Library" / "Application Support" / "irudd-voice" / "vocabulary.json"
DICTIONARY = Path("/usr/share/dict/words")
MAX_TERMS = 200
# A term must turn up in at least this many sessions, so one-off typos and
# pasted noise stay out.
MIN_SESSIONS = 2


@dataclass
class Session:
    source: str
    path: Path
    cwd: str = ""
    texts: list[str] = field(default_factory=list)


def load_terms(path: Path | None = None) -> list[str]:
    """The terms in a vocabulary.json, or none when it's missing."""
    path = path or DEFAULT_PATH
    if not path.exists():
        return []
    data = json.loads(path.read_text())
    return [t for t in data.get("terms", []) if isinstance(t, str)]


# ---- Reading logs ------------------------------------------------------------


def _jsonl(path: Path) -> Iterator[dict]:
    try:
        with path.open(errors="replace") as lines:
            for line in lines:
                try:
                    value = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(value, dict):
                    yield value
    except OSError:
        return


def _text_parts(content: object, kinds: tuple[str, ...] = ("text",)) -> list[str]:
    if isinstance(content, str):
        return [content]
    if isinstance(content, list):
        return [part["text"] for part in content
                if isinstance(part, dict) and part.get("type") in kinds and isinstance(part.get("text"), str)]
    return []


def claude_sessions(root: Path) -> Iterator[Session]:
    for path in sorted(root.glob("*/*.jsonl")):
        session = Session("claude", path)
        for line in _jsonl(path):
            session.cwd = session.cwd or line.get("cwd") or ""
            if line.get("type") != "user" or line.get("isSidechain") or line.get("isMeta"):
                continue
            if line.get("promptSource") == "system":
                continue
            message = line.get("message") or {}
            if message.get("role") != "user":
                continue
            session.texts += _text_parts(message.get("content"))
        session.cwd = session.cwd or path.parent.name
        yield session


def codex_sessions(root: Path) -> Iterator[Session]:
    for path in sorted(root.glob("**/*.jsonl")):
        session = Session("codex", path)
        for line in _jsonl(path):
            payload = line.get("payload") or {}
            if not isinstance(payload, dict):
                continue
            if line.get("type") == "session_meta":
                session.cwd = payload.get("cwd") or ""
            elif line.get("type") == "response_item" and payload.get("type") == "message" \
                    and payload.get("role") == "user":
                session.texts += [t for t in _text_parts(payload.get("content"), ("input_text",))
                                  if not t.lstrip().startswith(("<", "# AGENTS.md"))]
        yield session


def cursor_agent_sessions(root: Path) -> Iterator[Session]:
    for path in sorted(root.glob("*/agent-transcripts/**/*.jsonl")):
        # The project folder is the workspace path with "/" turned into "-".
        session = Session("cursor", path, cwd=path.relative_to(root).parts[0])
        for line in _jsonl(path):
            if line.get("role") != "user":
                continue
            for text in _text_parts((line.get("message") or {}).get("content")):
                query = re.search(r"<user_query>(.*?)(?:</user_query>|$)", text, flags=re.DOTALL)
                session.texts.append(query.group(1) if query else text)
        yield session


def cursor_app_sessions(database: Path) -> Iterator[Session]:
    try:
        con = sqlite3.connect(f"{database.as_uri()}?mode=ro&immutable=1", uri=True)
        rows = con.execute("SELECT key, value FROM cursorDiskKV WHERE key LIKE 'bubbleId:%'").fetchall()
        con.close()
    except sqlite3.Error:
        return
    by_composer: dict[str, Session] = {}
    for key, value in rows:
        try:
            bubble = json.loads(value)
        except (TypeError, json.JSONDecodeError):
            continue
        if not isinstance(bubble, dict) or bubble.get("type") != 1 or not isinstance(bubble.get("text"), str):
            continue
        composer = key.split(":")[1] if key.count(":") >= 2 else key
        by_composer.setdefault(composer, Session("cursor", database)).texts.append(bubble["text"])
    yield from by_composer.values()


def default_sources(home: Path) -> list[tuple[str, Path]]:
    return [
        ("claude", home / ".claude" / "projects"),
        ("codex", home / ".codex" / "sessions"),
        ("cursor", home / ".cursor" / "projects"),
        ("cursor-app", home / "Library" / "Application Support" / "Cursor" / "User" / "globalStorage" / "state.vscdb"),
    ]


READERS = {
    "claude": claude_sessions,
    "codex": codex_sessions,
    "cursor": cursor_agent_sessions,
    "cursor-app": cursor_app_sessions,
}


def is_teacher_session(session: Session) -> bool:
    marker = teacher.load()["marker"]
    return teacher.TEACHER_DIR_PREFIX in session.cwd or teacher.TEACHER_DIR_PREFIX in str(session.path) \
        or any(marker in text for text in session.texts)


# ---- Terms -------------------------------------------------------------------


# Blocks a client wraps around what the user typed (<system-reminder>,
# <runtime_info>, …). The user's own words are inside user_query/user_request.
_WRAPPERS = re.compile(r"</?(?:user_query|user_request)>")
_BLOCK = re.compile(r"<([a-zA-Z][\w-]*)(?:\s[^>]*)?>.*?</\1>", flags=re.DOTALL)
_TAG = re.compile(r"</?[a-zA-Z][\w-]*(?:\s[^>]*)?/?>")
_URL = re.compile(r"\b[a-z][a-z0-9+.-]*://\S+", flags=re.IGNORECASE)
# Absolute and home paths: their folders are often private (account names).
_ABSOLUTE_PATH = re.compile(r"(?<![\w.])[~/][^\s\"'`)]*")
_CODE_BLOCK = re.compile(r"```.*?(?:```|$)", flags=re.DOTALL)
# A candidate: letters, digits and the joiners . - _ inside it.
_TOKEN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._\-]*[A-Za-z0-9]|[A-Za-z]")
_HEX = re.compile(r"[0-9a-f]{7,}|[0-9a-f]{8}-[0-9a-f-]+", flags=re.IGNORECASE)


def user_words(text: str) -> str:
    """The text the user typed, without client wrappers, URLs, absolute
    paths or code blocks."""
    text = _WRAPPERS.sub("", text)
    text = _BLOCK.sub(" ", text)
    text = _TAG.sub(" ", text)
    text = _CODE_BLOCK.sub(" ", text)
    text = _URL.sub(" ", text)
    text = _ABSOLUTE_PATH.sub(" ", text)
    # Contractions ("doesn't", "it's") are never vocabulary; without this
    # "doesn" would look like a term.
    return re.sub(r"\b[A-Za-z]+['’][A-Za-z]{1,2}\b", " ", text)


def _english(word: str, dictionary: set[str]) -> bool:
    lower = word.lower()
    if lower in dictionary:
        return True
    for suffix, replacement in (("ies", "y"), ("ied", "y"), ("es", ""), ("s", ""), ("ed", ""), ("ed", "e"),
                                ("ing", ""), ("ing", "e"), ("ly", ""), ("er", ""), ("ers", ""), ("d", "")):
        if not lower.endswith(suffix) or len(lower) <= len(suffix) + 2:
            continue
        base = lower[: -len(suffix)]
        if base + replacement in dictionary:
            return True
        # running → run, stopped → stop
        if suffix in ("ing", "ed", "er", "ers") and len(base) > 3 and base[-1] == base[-2] and base[:-1] in dictionary:
            return True
    return False


def terms_in(text: str, dictionary: set[str], skip: set[str] = frozenset()) -> list[str]:
    """Candidate terms in one message, in the spelling the user typed."""
    found = []
    # Path parts count on their own ("shared/cleanup-prompt.json" →
    # "shared", "cleanup-prompt.json"); whole paths never become terms.
    for token in _TOKEN.findall(user_words(text).replace("/", " ").replace("\\", " ")):
        token = token.strip("._-")
        lower = token.lower()
        if len(token) < 2 or len(token) > 40 or lower in skip:
            continue
        if token.isdigit() or _HEX.fullmatch(token) or re.fullmatch(r"[\d._\-]+", token):
            continue
        if re.fullmatch(r"\d.*", token) and not re.search(r"[A-Za-z]{2}", token):
            continue  # 10s, 3x, 2026-10-25
        joined = any(c in token for c in "._-") or (re.search(r"\d", token) and re.search(r"[A-Za-z]", token))
        humped = re.search(r"[a-z][A-Z]", token) or re.fullmatch(r"[A-Z]{2,}[a-z]*s?", token)
        if joined or humped:
            if "." in token and re.fullmatch(r"[A-Za-z]+\.[A-Za-z]+", token) and _english(token.split(".")[0], dictionary) \
                    and _english(token.split(".")[1], dictionary):
                continue  # end of sentence with no space: "done.Next"
            found.append(token)
        elif dictionary and token.isalpha() and not _english(token, dictionary):
            found.append(token)
    return found


def load_dictionary(path: Path = DICTIONARY) -> set[str]:
    try:
        return {line.strip().lower() for line in path.read_text(errors="replace").splitlines() if line.strip()}
    except OSError:
        return set()


@dataclass
class Mined:
    terms: list[str]
    sessions: Counter
    teacher_sessions: int
    candidates: int


def mine(sources: list[tuple[str, Path]], dictionary: set[str], skip: set[str] = frozenset(),
         limit: int = MAX_TERMS, min_sessions: int = MIN_SESSIONS) -> Mined:
    sessions_by_source: Counter = Counter()
    teacher_sessions = 0
    session_count: Counter = Counter()  # lowercase term → sessions using it
    uses: Counter = Counter()
    spellings: dict[str, Counter] = {}
    for name, path in sources:
        if not path.exists():
            continue
        for session in READERS[name](path):
            if not session.texts:
                continue
            if is_teacher_session(session):
                teacher_sessions += 1
                continue
            sessions_by_source[name] += 1
            seen = set()
            for text in session.texts:
                for term in terms_in(text, dictionary, skip):
                    lower = term.lower()
                    uses[lower] += 1
                    spellings.setdefault(lower, Counter())[term] += 1
                    seen.add(lower)
            session_count.update(seen)
    ranked = sorted((t for t in session_count if session_count[t] >= min_sessions),
                    key=lambda t: (-session_count[t], -uses[t], t))
    terms = [spellings[t].most_common(1)[0][0] for t in ranked[:limit]]
    return Mined(terms, sessions_by_source, teacher_sessions, len(session_count))


def write(path: Path, terms: list[str], now: datetime | None = None) -> None:
    now = now or datetime.now(UTC)
    data = {"version": VERSION, "generated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"), "terms": terms}
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    temporary.replace(path)


# ---- Command -----------------------------------------------------------------


def register(commands) -> None:
    parser = commands.add_parser("vocab", help="build the vocabulary list from Claude, Codex and Cursor logs")
    parser.add_argument("--out", type=Path, default=DEFAULT_PATH, help=f"where to write it (default: {DEFAULT_PATH})")
    parser.add_argument("--dry-run", action="store_true", help="count terms, write nothing, print no terms")
    # Tests point this at a folder of synthetic logs.
    parser.add_argument("--home", type=Path, default=Path.home(), help=argparse.SUPPRESS)
    parser.set_defaults(run=run)


def run(args) -> int:
    # The account name turns up in every path; it's not vocabulary.
    skip = {args.home.name.lower()}
    mined = mine(default_sources(args.home), load_dictionary(), skip,
                 limit=min(MAX_TERMS, prompt.load()["vocabulary_limit"]))
    read = ", ".join(f"{n} {name}" for name, n in sorted(mined.sessions.items())) or "none"
    print(f"Sessions read: {read}; teacher sessions skipped: {mined.teacher_sessions}")
    print(f"Terms: {len(mined.terms)} kept of {mined.candidates} candidates")
    if args.dry_run:
        print("Dry run: nothing written.")
        return 0
    write(args.out, mined.terms)
    print(f"Wrote {args.out}")
    return 0
