#!/usr/bin/env python3
"""Local dictionary bridge for the Atlas/Chromium extension.

This server intentionally uses only the Python standard library so it can run
without extra installation steps. It understands the app's built-in dictionary
schema, imported dictionary catalog, optional HTML entry tables, and optional
asset tables so the browser extension can get much closer to the in-app
dictionary experience.
"""

from __future__ import annotations

import argparse
import glob
import html
import json
import mimetypes
import os
import plistlib
import re
import sqlite3
import threading
from contextlib import contextmanager
from dataclasses import asdict, dataclass
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Iterable
from urllib.parse import parse_qs, quote, unquote, urlparse


BUILTIN_DICTIONARY_ID = "builtin.default"
BUILTIN_DICTIONARY_NAME = "默认词典"
APP_BUNDLE_IDENTIFIERS = {
    "project.FuckYouXcode",
    "project.FuckYouXcode-Beta",
}
LINK_PREFIX = "@@@LINK="
WORD_TRIM_RE = re.compile(r"^[^\w]+|[^\w]+$", re.UNICODE)
DICT_SCHEME_LINK_RE = re.compile(r"dict://(entry|asset)/([^\"'\\s)]+)", re.IGNORECASE)
INLINE_ENTRY_LINK_RE = re.compile(r"\[\[([^\[\]\r\n]{1,80})\]\]")


def normalize_lookup(value: str) -> str:
    trimmed = value.strip()
    trimmed = WORD_TRIM_RE.sub("", trimmed)
    return trimmed.lower()


def escape_fts(value: str) -> str:
    return value.replace('"', "")


def split_examples(text: str) -> list[str]:
    return [line.strip() for line in text.splitlines() if line.strip()]


def route_quote(value: str, safe: str = "") -> str:
    return quote(value, safe=safe)


def dictionary_catalog_path() -> Path:
    env_path = os.environ.get("FUCKYOUXCODE_DICTIONARY_CATALOG")
    if env_path:
        return Path(env_path).expanduser()

    simulator_candidate = latest_simulator_app_support_file(Path("dictionaries") / "catalog.json")
    if simulator_candidate is not None:
        return simulator_candidate

    return Path.home() / "Library" / "Application Support" / "dictionaries" / "catalog.json"


def find_default_db_path() -> Path:
    env_path = os.environ.get("FUCKYOUXCODE_DICT_DB")
    if env_path:
        candidate = Path(env_path).expanduser()
        if candidate.exists():
            return candidate

    simulator_candidate = latest_simulator_app_support_file("dic_.db")
    if simulator_candidate is not None:
        return simulator_candidate

    repo_root = Path(__file__).resolve().parents[1]
    repo_candidate = repo_root / "Resources" / "dic_.db"
    if repo_candidate.exists():
        return repo_candidate

    app_support_candidate = Path.home() / "Library" / "Application Support" / "dic_.db"
    if app_support_candidate.exists():
        return app_support_candidate

    raise FileNotFoundError(
        "Could not find dic_.db. Set FUCKYOUXCODE_DICT_DB or place the bundled DB under Resources/dic_.db."
    )


def find_default_user_db_path() -> Path:
    env_path = os.environ.get("FUCKYOUXCODE_USER_DB")
    if env_path:
        candidate = Path(env_path).expanduser()
        if candidate.exists():
            return candidate

    simulator_candidate = latest_simulator_app_support_file("user_1.db")
    if simulator_candidate is not None:
        return simulator_candidate

    repo_root = Path(__file__).resolve().parents[1]
    repo_candidate = repo_root / "Resources" / "user_1.db"
    if repo_candidate.exists():
        return repo_candidate

    app_support_candidate = Path.home() / "Library" / "Application Support" / "user_1.db"
    if app_support_candidate.exists():
        return app_support_candidate

    raise FileNotFoundError(
        "Could not find user_1.db. Set FUCKYOUXCODE_USER_DB or place the user DB under Resources/user_1.db."
    )


def latest_simulator_app_support_file(relative_path: str | Path) -> Path | None:
    simulator_root = Path.home() / "Library" / "Developer" / "CoreSimulator" / "Devices"
    if not simulator_root.exists():
        return None

    relative = Path(relative_path)
    containers = simulator_app_container_roots(simulator_root)
    preferred = [
        container
        for container in containers
        if simulator_container_bundle_id(container) in APP_BUNDLE_IDENTIFIERS
    ]

    for group in (preferred, containers):
        candidates = [
            container / "Library" / "Application Support" / relative
            for container in group
        ]
        existing = [candidate for candidate in candidates if candidate.is_file()]
        if existing:
            return max(existing, key=lambda path: path.stat().st_mtime)

    return None


def simulator_app_container_roots(simulator_root: Path) -> list[Path]:
    patterns = [
        simulator_root / "*" / "data" / "Containers" / "Data" / "Application" / "*",
        simulator_root / "*" / "Data" / "Containers" / "Data" / "Application" / "*",
    ]
    containers: list[Path] = []
    seen: set[str] = set()
    for pattern in patterns:
        for raw_path in glob.glob(str(pattern)):
            container = Path(raw_path)
            if not container.is_dir():
                continue
            key = str(container)
            if key in seen:
                continue
            seen.add(key)
            containers.append(container)
    return containers


def simulator_container_bundle_id(container: Path) -> str | None:
    metadata_path = container / ".com.apple.mobile_container_manager.metadata.plist"
    if not metadata_path.exists():
        return None
    try:
        with metadata_path.open("rb") as handle:
            metadata = plistlib.load(handle)
    except Exception:
        return None
    value = metadata.get("MCMMetadataIdentifier")
    return str(value) if value else None


def clamp_int(value: object, default: int, minimum: int, maximum: int) -> int:
    try:
        parsed = int(str(value))
    except (TypeError, ValueError):
        return default
    return max(minimum, min(maximum, parsed))


def parse_bool_value(value: object) -> bool:
    if isinstance(value, bool):
        return value
    if value is None:
        return False
    return str(value).strip().lower() in {"1", "true", "yes", "on", "favorite", "fav"}


@dataclass(frozen=True)
class DictionaryNormalizationProfile:
    strip_key: bool
    key_case_sensitive: bool

    def normalize_for_lookup(self, value: str) -> str:
        trimmed = value.strip()
        if not trimmed:
            return ""

        stripped = trimmed
        if self.strip_key:
            stripped = re.sub(r"[\W_]+", "", stripped, flags=re.UNICODE)

        cased = stripped if self.key_case_sensitive else stripped.lower()
        return cased.strip()


@dataclass(frozen=True)
class DictionaryCapabilities:
    has_lemma_map: bool
    has_fts: bool
    has_entry_html: bool
    has_mdd_asset_index: bool


@dataclass
class Entry:
    id: int
    word: str
    lemma: str | None
    pos: str | None
    phonetic: str | None
    frequency: int | None
    level: str | None
    definition: str | None
    examples: str | None
    idioms: str | None
    origination: str | None
    hwd: str | None
    html: str | None


@dataclass
class DictionarySource:
    id: str
    display_name: str
    db_path: Path
    source_kind: str
    status: str
    source_folder_path: Path | None
    mdx_file_name: str | None
    has_mdd: bool
    last_error: str | None
    capabilities: DictionaryCapabilities

    @property
    def is_selectable(self) -> bool:
        return self.status == "ready"

    def to_api_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "displayName": self.display_name,
            "dbPath": str(self.db_path),
            "sourceKind": self.source_kind,
            "status": self.status,
            "isSelectable": self.is_selectable,
            "sourceFolderPath": str(self.source_folder_path) if self.source_folder_path else None,
            "mdxFileName": self.mdx_file_name,
            "hasMDD": self.has_mdd,
            "lastError": self.last_error,
            "capabilities": asdict(self.capabilities),
        }


class DirectoryAssetResolver:
    @staticmethod
    def sanitize_relative_path(raw_path: str) -> str:
        decoded = unquote(raw_path)
        unified = decoded.replace("\\", "/")
        parts = [part for part in unified.split("/") if part and part != "."]

        normalized: list[str] = []
        for part in parts:
            if part == "..":
                if not normalized:
                    return ""
                normalized.pop()
            else:
                normalized.append(part)
        return "/".join(normalized)

    @classmethod
    def candidate_relative_paths(cls, requested_path: str, mdx_relative_path: str | None) -> list[str]:
        ordered: list[str] = []
        seen: set[str] = set()

        canonical = cls.sanitize_relative_path(requested_path)
        if canonical and canonical not in seen:
            seen.add(canonical)
            ordered.append(canonical)

        if mdx_relative_path:
            mdx_base = str(Path(mdx_relative_path).parent)
            if mdx_base and mdx_base != ".":
                prefixed = cls.sanitize_relative_path(f"{mdx_base}/{canonical}")
                if prefixed and prefixed not in seen:
                    seen.add(prefixed)
                    ordered.append(prefixed)

        return ordered

    @staticmethod
    def mime_type_for_path(path: str) -> str:
        guessed, _ = mimetypes.guess_type(path)
        return guessed or "application/octet-stream"

    @classmethod
    def load_asset(
        cls, source_folder_path: Path | None, requested_path: str, mdx_relative_path: str | None
    ) -> tuple[str, str, bytes] | None:
        if source_folder_path is None:
            return None

        root = source_folder_path.expanduser().resolve()
        candidates = cls.candidate_relative_paths(requested_path, mdx_relative_path)
        for candidate in candidates:
            exact = cls._load_exact(root, candidate)
            if exact is not None:
                return exact

            folded = cls._load_case_insensitive(root, candidate)
            if folded is not None:
                return folded

        return None

    @classmethod
    def _safe_file_path(cls, root: Path, relative_path: str) -> Path | None:
        sanitized = cls.sanitize_relative_path(relative_path)
        if not sanitized:
            return None

        candidate = (root / sanitized).resolve()
        if candidate == root or root in candidate.parents:
            return candidate
        return None

    @classmethod
    def _load_exact(cls, root: Path, relative_path: str) -> tuple[str, str, bytes] | None:
        candidate = cls._safe_file_path(root, relative_path)
        if candidate is None or not candidate.is_file():
            return None
        return (relative_path, cls.mime_type_for_path(relative_path), candidate.read_bytes())

    @classmethod
    def _load_case_insensitive(cls, root: Path, relative_path: str) -> tuple[str, str, bytes] | None:
        sanitized = cls.sanitize_relative_path(relative_path)
        if not sanitized:
            return None

        current = root
        components = sanitized.split("/")

        for component in components:
            if not current.is_dir():
                return None

            children = list(current.iterdir())
            exact = next((child for child in children if child.name == component), None)
            if exact is not None:
                current = exact
                continue

            folded = next((child for child in children if child.name.lower() == component.lower()), None)
            if folded is None:
                return None
            current = folded

        resolved = current.resolve()
        if not resolved.is_file():
            return None
        if resolved != root and root not in resolved.parents:
            return None

        resolved_relative = str(resolved.relative_to(root)).replace(os.sep, "/")
        return (resolved_relative, cls.mime_type_for_path(resolved_relative), resolved.read_bytes())


class DictionaryRepository:
    def __init__(self, source: DictionarySource) -> None:
        self.source = source
        self.db_path = source.db_path
        self.capabilities = source.capabilities
        self.normalization_profile = self._load_normalization_profile()
        self._local = threading.local()

    def connection(self) -> sqlite3.Connection:
        connection = getattr(self._local, "connection", None)
        if connection is None:
            uri = f"file:{self.db_path}?mode=ro&immutable=1"
            connection = sqlite3.connect(uri, uri=True, check_same_thread=False)
            connection.row_factory = sqlite3.Row
            self._local.connection = connection
        return connection

    def lookup_entries(self, raw_input: str) -> list[Entry]:
        form = self.normalize(raw_input)
        if not form:
            return []

        results: list[Entry] = []
        seen_ids: set[int] = set()

        def append_unique(rows: Iterable[sqlite3.Row]) -> None:
            for row in rows:
                entry = self._entry_from_row(row)
                if entry.id in seen_ids:
                    continue
                seen_ids.add(entry.id)
                results.append(entry)

        append_unique(self._fetch_exact_words(form))

        if self.capabilities.has_lemma_map:
            lemma = self._resolve_lemma_if_needed(form)
            if lemma and lemma != form:
                append_unique(self._fetch_exact_words(lemma))

        if not results and self.capabilities.has_fts:
            best = self._fetch_best_by_fts(form)
            if best is not None:
                append_unique([best])

        if not results:
            best = self._fetch_best_by_fallback_search(form)
            if best is not None:
                append_unique([best])

        return results

    def suggestions(self, raw_input: str, limit: int = 20) -> list[str]:
        form = self.normalize(raw_input)
        if not form:
            return []

        conn = self.connection()
        if self.capabilities.has_fts:
            query = f"word:{escape_fts(form)}*"
            rows = conn.execute(
                """
                SELECT DISTINCT word
                FROM entries_fts
                WHERE entries_fts MATCH ?
                LIMIT ?
                """,
                (query, limit),
            ).fetchall()
            return [str(row["word"]) for row in rows]

        rows = conn.execute(
            """
            SELECT DISTINCT word
            FROM entries
            WHERE word LIKE ?
            ORDER BY word COLLATE NOCASE ASC
            LIMIT ?
            """,
            (f"{form}%", limit),
        ).fetchall()
        return [str(row["word"]) for row in rows]

    def fetch_entry_html(self, entry_key: str) -> str | None:
        if not self.capabilities.has_entry_html:
            return None

        conn = self.connection()
        visited: set[str] = set()
        max_link_depth = 8

        def resolve_html(key: str, depth: int) -> str | None:
            html_value = self._fetch_raw_entry_html(key, conn)
            if html_value is None:
                return None

            target = self._link_target(html_value)
            if target is None or depth >= max_link_depth:
                return html_value

            identity = self._lookup_identity(target)
            if not identity or identity in visited:
                return html_value

            visited.add(identity)
            return resolve_html(target, depth + 1) or html_value

        start_identity = self._lookup_identity(entry_key)
        if start_identity:
            visited.add(start_identity)

        return resolve_html(entry_key, 0)

    def fetch_asset(self, raw_path: str) -> tuple[str, str, bytes] | None:
        if not raw_path:
            return None

        local_asset = DirectoryAssetResolver.load_asset(
            source_folder_path=self.source.source_folder_path,
            requested_path=raw_path,
            mdx_relative_path=self.source.mdx_file_name,
        )
        if local_asset is not None:
            return local_asset

        if not self.capabilities.has_mdd_asset_index:
            return None

        canonical = self._canonical_path(raw_path)
        if not canonical:
            return None

        normalized = self._normalized_lookup_path(canonical)
        conn = self.connection()
        exact = conn.execute(
            """
            SELECT original_key, mime, data
            FROM mdd_asset_index
            WHERE original_key = ?
            LIMIT 1
            """,
            (canonical,),
        ).fetchone()
        if exact is not None:
            return (
                str(exact["original_key"]),
                str(exact["mime"]),
                bytes(exact["data"]),
            )

        insensitive = conn.execute(
            """
            SELECT original_key, mime, data
            FROM mdd_asset_index
            WHERE path_norm = ?
            LIMIT 1
            """,
            (normalized,),
        ).fetchone()
        if insensitive is not None:
            return (
                str(insensitive["original_key"]),
                str(insensitive["mime"]),
                bytes(insensitive["data"]),
            )

        return None

    def render_entry_document(self, entry_key: str) -> str:
        raw_html = self.fetch_entry_html(entry_key)
        if raw_html:
            return self._prepare_html_document(raw_html, entry_key)

        entries = self.lookup_entries(entry_key)
        return self._render_plain_entry_document(entry_key, entries)

    def preferred_render_entry_key(self, query: str, entries: list[Entry]) -> str | None:
        if not self.capabilities.has_entry_html:
            return None

        for entry in entries:
            if entry.html:
                return entry.word

        if self.fetch_entry_html(query):
            return query.strip()

        if entries:
            return entries[0].word

        return None

    def normalize(self, value: str) -> str:
        return self.normalization_profile.normalize_for_lookup(value)

    def _load_normalization_profile(self) -> DictionaryNormalizationProfile:
        conn = sqlite3.connect(f"file:{self.db_path}?mode=ro&immutable=1", uri=True)
        conn.row_factory = sqlite3.Row
        try:
            if not self._table_exists(conn, "dictionary_meta"):
                return DictionaryNormalizationProfile(strip_key=False, key_case_sensitive=False)

            strip_raw = conn.execute(
                "SELECT value FROM dictionary_meta WHERE key = 'strip_key' LIMIT 1"
            ).fetchone()
            case_raw = conn.execute(
                "SELECT value FROM dictionary_meta WHERE key = 'key_case_sensitive' LIMIT 1"
            ).fetchone()
            return DictionaryNormalizationProfile(
                strip_key=self._bool_value(strip_raw["value"] if strip_raw else None),
                key_case_sensitive=self._bool_value(case_raw["value"] if case_raw else None),
            )
        finally:
            conn.close()

    @staticmethod
    def inspect_capabilities(db_path: Path) -> DictionaryCapabilities:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro&immutable=1", uri=True)
        try:
            return DictionaryCapabilities(
                has_lemma_map=DictionaryRepository._table_exists(conn, "lemma_map"),
                has_fts=DictionaryRepository._table_exists(conn, "entries_fts"),
                has_entry_html=DictionaryRepository._table_exists(conn, "entry_html"),
                has_mdd_asset_index=DictionaryRepository._table_exists(conn, "mdd_asset_index"),
            )
        finally:
            conn.close()

    @staticmethod
    def _table_exists(connection: sqlite3.Connection, name: str) -> bool:
        row = connection.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name = ? LIMIT 1", (name,)
        ).fetchone()
        return row is not None

    @staticmethod
    def _bool_value(value: object) -> bool:
        if value is None:
            return False
        return str(value).strip().lower() in {"1", "true", "yes", "on"}

    def _lookup_identity(self, key: str) -> str:
        normalized = self.normalize(key)
        if normalized:
            return normalized
        return key.strip().lower()

    def _fetch_raw_entry_html(self, entry_key: str, conn: sqlite3.Connection) -> str | None:
        exact = conn.execute(
            """
            SELECT h.html
            FROM entry_html h
            WHERE h.entry_key = ? COLLATE NOCASE
            LIMIT 1
            """,
            (entry_key,),
        ).fetchone()
        if exact is not None:
            return str(exact["html"])

        by_word = conn.execute(
            """
            SELECT h.html
            FROM entry_html h
            JOIN entries e ON e.id = h.entry_id
            WHERE e.word = ? COLLATE NOCASE
            LIMIT 1
            """,
            (entry_key,),
        ).fetchone()
        if by_word is not None:
            return str(by_word["html"])

        normalized = self.normalize(entry_key)
        if normalized and normalized != entry_key:
            by_normalized = conn.execute(
                """
                SELECT h.html
                FROM entry_html h
                JOIN entries e ON e.id = h.entry_id
                WHERE e.word = ? COLLATE NOCASE
                LIMIT 1
                """,
                (normalized,),
            ).fetchone()
            if by_normalized is not None:
                return str(by_normalized["html"])

        return None

    @staticmethod
    def _link_target(raw_html: str) -> str | None:
        trimmed = raw_html.strip()
        if not trimmed.startswith(LINK_PREFIX):
            return None
        target = trimmed[len(LINK_PREFIX) :].strip()
        return target or None

    def _fetch_exact_words(self, word: str) -> list[sqlite3.Row]:
        conn = self.connection()
        select_columns = self._select_columns_sql()
        from_clause = self._from_clause_sql()
        return conn.execute(
            f"""
            SELECT {select_columns}
            FROM {from_clause}
            WHERE e.word = ? COLLATE NOCASE
            ORDER BY CASE e.pos
                WHEN 'verb' THEN 1
                WHEN 'noun' THEN 2
                WHEN 'adjective' THEN 3
                WHEN 'adverb' THEN 4
                WHEN 'pronoun' THEN 5
                WHEN 'preposition' THEN 6
                WHEN 'conjunction' THEN 7
                WHEN 'interjection' THEN 8
                WHEN 'determiner' THEN 9
                WHEN 'numeral' THEN 10
                WHEN 'phrase' THEN 11
                WHEN 'other' THEN 12
                ELSE 99
            END, e.id ASC
            """,
            (word,),
        ).fetchall()

    def _resolve_lemma_if_needed(self, form: str) -> str | None:
        conn = self.connection()
        row = conn.execute("SELECT lemma FROM lemma_map WHERE form = ? LIMIT 1", (form,)).fetchone()
        if row is None:
            return None
        lemma = str(row["lemma"]).strip()
        return self.normalize(lemma)

    def _fetch_best_by_fts(self, word: str) -> sqlite3.Row | None:
        conn = self.connection()
        select_columns = self._select_columns_sql()
        join_clause = "LEFT JOIN entry_html h ON h.entry_id = e.id" if self.capabilities.has_entry_html else ""
        query = f"word:{escape_fts(word)}*"
        return conn.execute(
            f"""
            SELECT {select_columns}
            FROM entries_fts f
            JOIN entries e ON e.id = f.rowid
            {join_clause}
            WHERE f MATCH ?
            LIMIT 1
            """,
            (query,),
        ).fetchone()

    def _fetch_best_by_fallback_search(self, form: str) -> sqlite3.Row | None:
        conn = self.connection()
        like = f"%{form}%"
        select_columns = self._select_columns_sql()
        from_clause = self._from_clause_sql()
        return conn.execute(
            f"""
            SELECT {select_columns}
            FROM {from_clause}
            WHERE e.word LIKE ? COLLATE NOCASE
               OR e.lemma LIKE ? COLLATE NOCASE
               OR e.definition LIKE ? COLLATE NOCASE
               OR e.hwd LIKE ? COLLATE NOCASE
            ORDER BY
                CASE
                    WHEN e.word = ? COLLATE NOCASE THEN 0
                    WHEN e.lemma = ? COLLATE NOCASE THEN 1
                    WHEN e.word LIKE ? COLLATE NOCASE THEN 2
                    ELSE 3
                END,
                e.frequency DESC,
                e.word COLLATE NOCASE ASC
            LIMIT 1
            """,
            (like, like, like, like, form, form, f"{form}%"),
        ).fetchone()

    def _select_columns_sql(self) -> str:
        html_select = "h.html AS html" if self.capabilities.has_entry_html else "NULL AS html"
        return f"""
        e.id,
        e.word,
        e.lemma,
        e.pos,
        e.phonetic,
        e.frequency,
        e.level,
        e.definition,
        e.examples,
        e.idioms,
        e.origination,
        e.hwd,
        {html_select}
        """

    def _from_clause_sql(self) -> str:
        if self.capabilities.has_entry_html:
            return "entries e LEFT JOIN entry_html h ON h.entry_id = e.id"
        return "entries e"

    @staticmethod
    def _canonical_path(raw_path: str) -> str:
        if not raw_path:
            return ""
        decoded_path = unquote(raw_path).replace("\\", "/")
        parts = [part for part in decoded_path.split("/") if part and part != "."]

        normalized: list[str] = []
        for part in parts:
            if part == "..":
                if normalized:
                    normalized.pop()
                continue
            normalized.append(part)

        return "/".join(normalized)

    @classmethod
    def _normalized_lookup_path(cls, raw_path: str) -> str:
        return cls._canonical_path(raw_path).lower()

    def _entry_from_row(self, row: sqlite3.Row) -> Entry:
        def empty_to_none(value: object) -> object | None:
            if value is None:
                return None
            if isinstance(value, str) and not value.strip():
                return None
            return value

        return Entry(
            id=int(row["id"]),
            word=str(row["word"]),
            lemma=empty_to_none(row["lemma"]),
            pos=empty_to_none(row["pos"]),
            phonetic=empty_to_none(row["phonetic"]),
            frequency=empty_to_none(row["frequency"]),
            level=empty_to_none(row["level"]),
            definition=empty_to_none(row["definition"]),
            examples=empty_to_none(row["examples"]),
            idioms=empty_to_none(row["idioms"]),
            origination=empty_to_none(row["origination"]),
            hwd=empty_to_none(row["hwd"]),
            html=empty_to_none(row["html"]),
        )

    def _prepare_html_document(self, raw_html: str, entry_key: str) -> str:
        document = raw_html.strip()
        if not document:
            document = "<html><body></body></html>"
        elif "<html" not in document.lower():
            document = f"""
            <html>
              <head>
                <meta charset="utf-8" />
                <meta name="viewport" content="width=device-width, initial-scale=1" />
              </head>
              <body>{document}</body>
            </html>
            """

        document = self._rewrite_dict_scheme_links(document)
        base_href = f"/render/entry/{route_quote(self.source.id)}/{route_quote(entry_key)}/"
        shell_style = """
        <style id="fuckyouxcode-bridge-shell">
          :root { color-scheme: light; }
          body {
            margin: 0;
            padding: 14px 16px 24px;
            font-family: 'Iowan Old Style', 'Palatino Linotype', Georgia, serif;
            color: #231b15;
            background: #fffdf8;
            line-height: 1.6;
          }
          img, video, audio, iframe { max-width: 100%; }
        </style>
        """

        if "<head" in document.lower():
            document = re.sub(
                r"(?is)<head([^>]*)>",
                lambda match: (
                    f"<head{match.group(1)}>"
                    f"<base href=\"{html.escape(base_href, quote=True)}\" />"
                    f"{shell_style}"
                ),
                document,
                count=1,
            )
        else:
            document = f"<head><base href=\"{html.escape(base_href, quote=True)}\" />{shell_style}</head>{document}"

        return document

    def _rewrite_dict_scheme_links(self, html_text: str) -> str:
        def replace(match: re.Match[str]) -> str:
            kind = match.group(1).lower()
            raw_suffix = match.group(2)
            suffix = unquote(raw_suffix)
            parts = [part for part in suffix.split("/") if part]
            if len(parts) < 2:
                return match.group(0)

            dictionary_id = parts[0]
            remainder = parts[1:]
            if kind == "entry":
                entry_key = remainder[0]
                return f"/render/entry/{route_quote(dictionary_id)}/{route_quote(entry_key)}"
            asset_path = "/".join(remainder)
            return f"/render/asset/{route_quote(dictionary_id)}/{route_quote(asset_path, safe='/')}"

        return DICT_SCHEME_LINK_RE.sub(replace, html_text)

    def _render_plain_entry_document(self, query: str, entries: list[Entry]) -> str:
        title = html.escape(query or "Dictionary Entry")
        sections: list[str] = []

        for entry in entries:
            badges: list[str] = []
            if entry.frequency:
                badges.append(f"<span class='badge'>Frequency {entry.frequency}</span>")
            if entry.level:
                badges.append(f"<span class='badge'>{html.escape(entry.level)}</span>")

            meta_bits = [bit for bit in [entry.phonetic, entry.pos] if bit]
            article_sections: list[str] = []

            if entry.definition:
                article_sections.append(
                    f"<section><h3>Definition</h3><p>{html.escape(entry.definition)}</p></section>"
                )
            if entry.idioms:
                article_sections.append(
                    f"<section><h3>Idioms</h3><p>{html.escape(entry.idioms)}</p></section>"
                )
            if entry.examples:
                items = "".join(f"<li>{html.escape(line)}</li>" for line in split_examples(entry.examples))
                article_sections.append(f"<section><h3>Examples</h3><ol>{items}</ol></section>")
            if entry.origination:
                article_sections.append(
                    f"<section><h3>Origination</h3><p>{self._render_inline_entry_links(entry.origination)}</p></section>"
                )

            sections.append(
                f"""
                <article class="entry-card">
                  <header class="entry-header">
                    <div>
                      <h2>{html.escape(entry.word)}</h2>
                      <p class="meta">{html.escape(" · ".join(meta_bits))}</p>
                    </div>
                    <div class="badges">{''.join(badges)}</div>
                  </header>
                  {''.join(article_sections)}
                </article>
                """
            )

        if not sections:
            sections.append(
                f"""
                <article class="empty-card">
                  <h2>没有查到结果</h2>
                  <p>当前没有找到 “{title}” 的词条。</p>
                </article>
                """
            )

        return f"""
        <html>
          <head>
            <meta charset="utf-8" />
            <meta name="viewport" content="width=device-width, initial-scale=1" />
            <title>{title}</title>
            <style>
              body {{
                margin: 0;
                padding: 16px;
                font-family: "Iowan Old Style", "Palatino Linotype", Georgia, serif;
                background: #fffdf8;
                color: #231b15;
              }}
              .entry-card, .empty-card {{
                border: 1px solid rgba(120, 86, 52, 0.14);
                border-radius: 16px;
                padding: 16px;
                background: #fff8f0;
                box-shadow: 0 16px 32px rgba(76, 48, 27, 0.08);
              }}
              .entry-card + .entry-card {{
                margin-top: 14px;
              }}
              .entry-header {{
                display: flex;
                justify-content: space-between;
                gap: 12px;
                align-items: flex-start;
              }}
              h2 {{
                margin: 0;
                font-size: 28px;
              }}
              h3 {{
                margin: 0 0 6px;
                font-size: 12px;
                letter-spacing: 0.12em;
                text-transform: uppercase;
                color: #92471d;
              }}
              .meta {{
                color: #6f6155;
              }}
              .badge {{
                display: inline-block;
                margin-left: 8px;
                border-radius: 999px;
                padding: 6px 10px;
                background: rgba(182, 92, 45, 0.12);
                color: #92471d;
                font-size: 12px;
              }}
              section {{
                margin-top: 14px;
              }}
              a.inline-dict-link {{
                color: #8f3f17;
                text-decoration: underline;
                text-underline-offset: 2px;
              }}
            </style>
          </head>
          <body>{''.join(sections)}</body>
        </html>
        """

    def _render_inline_entry_links(self, text: str) -> str:
        pieces: list[str] = []
        cursor = 0
        for match in INLINE_ENTRY_LINK_RE.finditer(text):
            pieces.append(html.escape(text[cursor:match.start()]))
            word = match.group(1).strip()
            if word:
                href = f"/render/entry/{route_quote(self.source.id)}/{route_quote(word)}"
                pieces.append(
                    f"<a class='inline-dict-link' href='{html.escape(href, quote=True)}'>{html.escape(word)}</a>"
                )
            else:
                pieces.append(html.escape(match.group(0)))
            cursor = match.end()

        pieces.append(html.escape(text[cursor:]))
        return "".join(pieces)


@dataclass
class FavoriteWord:
    word: str
    createdAt: int | None


@dataclass
class UserHighlight:
    id: int
    word: str
    dictionaryId: str | None
    entryId: int | None
    field: str | None
    start: int | None
    length: int | None
    color: str | None
    note: str | None
    createdAt: int | None
    updatedAt: int | None


@dataclass
class UserAnnotation:
    id: int
    word: str
    dictionaryId: str | None
    entryId: int | None
    field: str | None
    start: int | None
    length: int | None
    content: str | None
    createdAt: int | None
    updatedAt: int | None


@dataclass
class UserWordGroup:
    id: int
    name: str
    wordCount: int
    kind: str
    parentGroupId: int | None
    createdAt: int | None
    lastModifiedAt: int | None


class UserDataRepository:
    def __init__(self, db_path: Path) -> None:
        self.db_path = db_path
        self._schema_lock = threading.Lock()
        self._schema_cache: dict[str, set[str]] = {}

    @property
    def available(self) -> bool:
        return self.db_path.exists()

    def metadata(self) -> dict[str, Any]:
        return {
            "dbPath": str(self.db_path),
            "available": self.available,
        }

    def list_favorites(self, limit: int = 50, offset: int = 0) -> list[FavoriteWord]:
        limit = clamp_int(limit, default=50, minimum=1, maximum=500)
        offset = clamp_int(offset, default=0, minimum=0, maximum=100_000)
        self._require_table("favorites")

        with self._connect(readonly=True) as conn:
            rows = conn.execute(
                """
                SELECT word, created_at
                FROM favorites
                ORDER BY created_at DESC, word COLLATE NOCASE ASC
                LIMIT ? OFFSET ?
                """,
                (limit, offset),
            ).fetchall()
        return [
            FavoriteWord(word=str(row["word"]), createdAt=self._optional_int(row["created_at"]))
            for row in rows
        ]

    def is_favorite(self, word: str) -> bool:
        normalized = normalize_lookup(word)
        if not normalized:
            return False
        self._require_table("favorites")

        with self._connect(readonly=True) as conn:
            row = conn.execute(
                "SELECT 1 FROM favorites WHERE word = ? COLLATE NOCASE LIMIT 1",
                (normalized,),
            ).fetchone()
        return row is not None

    def set_favorite(self, word: str, favorite: bool) -> dict[str, Any]:
        normalized = normalize_lookup(word)
        if not normalized:
            raise ValueError("word is required")
        self._require_table("favorites")

        with self._connect(readonly=False) as conn:
            if favorite:
                conn.execute("INSERT OR IGNORE INTO favorites(word) VALUES (?)", (normalized,))
            else:
                conn.execute("DELETE FROM favorites WHERE word = ? COLLATE NOCASE", (normalized,))
            conn.commit()

        return {
            "word": normalized,
            "favorite": self.is_favorite(normalized),
        }

    def get_word_state(self, word: str, dictionary_id: str | None = None) -> dict[str, Any]:
        normalized = normalize_lookup(word)
        if not normalized:
            raise ValueError("word is required")

        return {
            "word": normalized,
            "dictionaryId": dictionary_id,
            "favorite": self.is_favorite(normalized) if self._table_exists("favorites") else False,
            "highlights": [asdict(item) for item in self.list_highlights(normalized, dictionary_id)],
            "annotations": [asdict(item) for item in self.list_annotations(normalized, dictionary_id)],
            "wordGroups": [asdict(item) for item in self.list_groups_containing_word(normalized)],
        }

    def list_highlights(self, word: str, dictionary_id: str | None = None) -> list[UserHighlight]:
        if not self._table_exists("highlights"):
            return []

        columns = self._columns("highlights")
        clauses = ["word = ? COLLATE NOCASE"]
        params: list[Any] = [normalize_lookup(word)]
        if dictionary_id and "dictionary_id" in columns:
            clauses.append("dictionary_id = ?")
            params.append(dictionary_id)

        with self._connect(readonly=True) as conn:
            rows = conn.execute(
                f"""
                SELECT *
                FROM highlights
                WHERE {' AND '.join(clauses)}
                ORDER BY updated_at DESC, id DESC
                LIMIT 200
                """,
                params,
            ).fetchall()

        return [
            UserHighlight(
                id=self._optional_int(row["id"]) or 0,
                word=str(row["word"]),
                dictionaryId=self._row_value(row, "dictionary_id"),
                entryId=self._optional_int(self._row_value(row, "entry_id")),
                field=self._row_value(row, "field"),
                start=self._optional_int(self._row_value(row, "start")),
                length=self._optional_int(self._row_value(row, "length")),
                color=self._row_value(row, "color"),
                note=self._row_value(row, "note"),
                createdAt=self._optional_int(self._row_value(row, "created_at")),
                updatedAt=self._optional_int(self._row_value(row, "updated_at")),
            )
            for row in rows
        ]

    def list_annotations(self, word: str, dictionary_id: str | None = None) -> list[UserAnnotation]:
        if not self._table_exists("annotations"):
            return []

        columns = self._columns("annotations")
        clauses = ["word = ? COLLATE NOCASE"]
        params: list[Any] = [normalize_lookup(word)]
        if dictionary_id and "dictionary_id" in columns:
            clauses.append("dictionary_id = ?")
            params.append(dictionary_id)

        with self._connect(readonly=True) as conn:
            rows = conn.execute(
                f"""
                SELECT *
                FROM annotations
                WHERE {' AND '.join(clauses)}
                ORDER BY updated_at DESC, id DESC
                LIMIT 200
                """,
                params,
            ).fetchall()

        return [
            UserAnnotation(
                id=self._optional_int(row["id"]) or 0,
                word=str(row["word"]),
                dictionaryId=self._row_value(row, "dictionary_id"),
                entryId=self._optional_int(self._row_value(row, "entry_id")),
                field=self._row_value(row, "field"),
                start=self._optional_int(self._row_value(row, "start")),
                length=self._optional_int(self._row_value(row, "length")),
                content=self._row_value(row, "content"),
                createdAt=self._optional_int(self._row_value(row, "created_at")),
                updatedAt=self._optional_int(self._row_value(row, "updated_at")),
            )
            for row in rows
        ]

    def list_word_groups(self) -> list[UserWordGroup]:
        if not self._table_exists("word_groups"):
            return []

        columns = self._columns("word_groups")
        kind_expr = "wg.kind" if "kind" in columns else "'group'"
        parent_expr = "wg.parent_group_id" if "parent_group_id" in columns else "NULL"
        created_expr = "wg.created_at" if "created_at" in columns else "NULL"
        words_table_exists = self._table_exists("word_group_words")
        count_expr = (
            "(SELECT COUNT(*) FROM word_group_words wgw WHERE wgw.group_id = wg.id)"
            if words_table_exists
            else "0"
        )
        modified_expr = (
            "(SELECT MAX(wgw.created_at) FROM word_group_words wgw WHERE wgw.group_id = wg.id)"
            if words_table_exists
            else created_expr
        )

        with self._connect(readonly=True) as conn:
            rows = conn.execute(
                f"""
                SELECT
                  wg.id AS id,
                  wg.name AS name,
                  {count_expr} AS word_count,
                  {kind_expr} AS kind,
                  {parent_expr} AS parent_group_id,
                  {created_expr} AS created_at,
                  COALESCE({modified_expr}, {created_expr}) AS last_modified_at
                FROM word_groups wg
                ORDER BY kind ASC, name COLLATE NOCASE ASC
                """
            ).fetchall()
        return [self._word_group_from_row(row) for row in rows]

    def list_groups_containing_word(self, word: str) -> list[UserWordGroup]:
        if not self._table_exists("word_groups") or not self._table_exists("word_group_words"):
            return []

        columns = self._columns("word_groups")
        kind_expr = "wg.kind" if "kind" in columns else "'group'"
        parent_expr = "wg.parent_group_id" if "parent_group_id" in columns else "NULL"
        created_expr = "wg.created_at" if "created_at" in columns else "NULL"

        with self._connect(readonly=True) as conn:
            rows = conn.execute(
                f"""
                SELECT
                  wg.id AS id,
                  wg.name AS name,
                  (SELECT COUNT(*) FROM word_group_words count_words WHERE count_words.group_id = wg.id) AS word_count,
                  {kind_expr} AS kind,
                  {parent_expr} AS parent_group_id,
                  {created_expr} AS created_at,
                  COALESCE(wgw.created_at, {created_expr}) AS last_modified_at
                FROM word_groups wg
                JOIN word_group_words wgw ON wgw.group_id = wg.id
                WHERE wgw.word = ? COLLATE NOCASE
                ORDER BY wg.name COLLATE NOCASE ASC
                """,
                (normalize_lookup(word),),
            ).fetchall()
        return [self._word_group_from_row(row) for row in rows]

    def add_word_to_group(self, word: str, group_id: int) -> dict[str, Any]:
        normalized = normalize_lookup(word)
        if not normalized:
            raise ValueError("word is required")
        group_id = clamp_int(group_id, default=0, minimum=1, maximum=2_147_483_647)
        self._require_table("word_groups")
        self._require_table("word_group_words")

        with self._connect(readonly=False) as conn:
            group = conn.execute("SELECT id, name FROM word_groups WHERE id = ? LIMIT 1", (group_id,)).fetchone()
            if group is None:
                raise ValueError(f"word group not found: {group_id}")
            conn.execute(
                "INSERT OR IGNORE INTO word_group_words(group_id, word) VALUES (?, ?)",
                (group_id, normalized),
            )
            conn.commit()

        return {
            "word": normalized,
            "groupId": group_id,
            "groupName": str(group["name"]),
            "inGroup": True,
        }

    @contextmanager
    def _connect(self, readonly: bool):
        if not self.available:
            raise ValueError(f"user database not found: {self.db_path}")
        connection = sqlite3.connect(str(self.db_path), timeout=5)
        try:
            connection.execute("PRAGMA foreign_keys = ON")
            if readonly:
                connection.execute("PRAGMA query_only = ON")
            connection.row_factory = sqlite3.Row
            yield connection
        finally:
            connection.close()

    def _require_table(self, name: str) -> None:
        if not self._table_exists(name):
            raise ValueError(f"user database table not found: {name}")

    def _table_exists(self, name: str) -> bool:
        if not self.available:
            return False
        with self._connect(readonly=True) as conn:
            row = conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table' AND name = ? LIMIT 1",
                (name,),
            ).fetchone()
        return row is not None

    def _columns(self, table: str) -> set[str]:
        with self._schema_lock:
            cached = self._schema_cache.get(table)
            if cached is not None:
                return cached

        if not self._table_exists(table):
            return set()
        with self._connect(readonly=True) as conn:
            rows = conn.execute(f"PRAGMA table_info({table})").fetchall()
        columns = {str(row["name"]) for row in rows}

        with self._schema_lock:
            self._schema_cache[table] = columns
        return columns

    @staticmethod
    def _row_value(row: sqlite3.Row, key: str) -> Any:
        if key not in row.keys():
            return None
        return row[key]

    @staticmethod
    def _optional_int(value: object) -> int | None:
        if value is None:
            return None
        try:
            return int(value)
        except (TypeError, ValueError):
            return None

    def _word_group_from_row(self, row: sqlite3.Row) -> UserWordGroup:
        return UserWordGroup(
            id=self._optional_int(row["id"]) or 0,
            name=str(row["name"]),
            wordCount=self._optional_int(row["word_count"]) or 0,
            kind=str(row["kind"] or "group"),
            parentGroupId=self._optional_int(row["parent_group_id"]),
            createdAt=self._optional_int(row["created_at"]),
            lastModifiedAt=self._optional_int(row["last_modified_at"]),
        )


class DictionarySourceRegistry:
    def __init__(self, builtin_db_path: Path) -> None:
        self.builtin_db_path = builtin_db_path
        self.catalog_path = dictionary_catalog_path()
        self._lock = threading.Lock()
        self._repository_cache: dict[tuple[str, str], DictionaryRepository] = {}

    def list_sources(self) -> list[DictionarySource]:
        builtin = self._build_source(
            id=BUILTIN_DICTIONARY_ID,
            display_name=BUILTIN_DICTIONARY_NAME,
            db_path=self.builtin_db_path,
            source_kind="builtin",
            status="ready",
            source_folder_path=None,
            mdx_file_name=None,
            has_mdd=False,
            last_error=None,
        )

        sources = [builtin]
        for record in self._load_catalog_records():
            db_path = Path(str(record.get("dbPath", ""))).expanduser()
            source_folder = str(record.get("sourceFolderPath", "")).strip()
            source_folder_path = Path(source_folder).expanduser() if source_folder else None
            status = str(record.get("status", "failed"))
            last_error = record.get("lastError")

            if status == "ready" and not db_path.exists():
                status = "failed"
                last_error = last_error or f"词典索引数据库不存在：{db_path}"

            sources.append(
                self._build_source(
                    id=str(record.get("id", "")),
                    display_name=str(record.get("displayName", "Imported Dictionary")),
                    db_path=db_path,
                    source_kind=str(record.get("sourceKind", "imported")),
                    status=status,
                    source_folder_path=source_folder_path,
                    mdx_file_name=record.get("mdxFileName"),
                    has_mdd=bool(record.get("hasMDD", False)),
                    last_error=last_error,
                )
            )

        sources.sort(key=lambda source: (source.source_kind != "builtin", source.display_name.lower()))
        return sources

    def get_source(self, dictionary_id: str | None) -> DictionarySource:
        target = dictionary_id or BUILTIN_DICTIONARY_ID
        for source in self.list_sources():
            if source.id == target:
                return source
        raise KeyError(f"Dictionary not found: {target}")

    def get_repository(self, dictionary_id: str | None) -> DictionaryRepository:
        source = self.get_source(dictionary_id)
        if not source.is_selectable:
            raise ValueError(f"Dictionary is not ready: {source.display_name}")

        cache_key = (source.id, str(source.db_path))
        with self._lock:
            repository = self._repository_cache.get(cache_key)
            if repository is None:
                repository = DictionaryRepository(source)
                self._repository_cache[cache_key] = repository
            return repository

    def _build_source(
        self,
        id: str,
        display_name: str,
        db_path: Path,
        source_kind: str,
        status: str,
        source_folder_path: Path | None,
        mdx_file_name: str | None,
        has_mdd: bool,
        last_error: str | None,
    ) -> DictionarySource:
        if status == "ready" and db_path.exists():
            capabilities = DictionaryRepository.inspect_capabilities(db_path)
        else:
            capabilities = DictionaryCapabilities(
                has_lemma_map=False,
                has_fts=False,
                has_entry_html=False,
                has_mdd_asset_index=False,
            )

        return DictionarySource(
            id=id,
            display_name=display_name,
            db_path=db_path,
            source_kind=source_kind,
            status=status,
            source_folder_path=source_folder_path,
            mdx_file_name=mdx_file_name,
            has_mdd=has_mdd,
            last_error=last_error,
            capabilities=capabilities,
        )

    def _load_catalog_records(self) -> list[dict[str, Any]]:
        if not self.catalog_path.exists():
            return []
        try:
            data = json.loads(self.catalog_path.read_text(encoding="utf-8"))
        except Exception:
            return []
        if isinstance(data, list):
            return [record for record in data if isinstance(record, dict)]
        return []


class DictionaryRequestHandler(BaseHTTPRequestHandler):
    source_registry: DictionarySourceRegistry
    user_repository: UserDataRepository
    server_version = "FuckYouXcodeDictionaryBridge/0.3"

    def do_OPTIONS(self) -> None:  # noqa: N802
        self.send_response(HTTPStatus.NO_CONTENT)
        self._write_cors_headers()
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)

        if parsed.path == "/health":
            sources = self.source_registry.list_sources()
            self._send_json(
                {
                    "ok": True,
                    "builtinDbPath": str(self.source_registry.builtin_db_path),
                    "catalogPath": str(self.source_registry.catalog_path),
                    "userData": self.user_repository.metadata(),
                    "dictionaryCount": len(sources),
                }
            )
            return

        if parsed.path == "/api/dictionaries":
            self._send_json({"dictionaries": [source.to_api_dict() for source in self.source_registry.list_sources()]})
            return

        if parsed.path == "/api/lookup":
            params = parse_qs(parsed.query)
            dictionary_id = params.get("dictionaryId", [BUILTIN_DICTIONARY_ID])[0]
            raw_word = params.get("word", [""])[0]
            word = raw_word.strip()
            source = self._require_source(dictionary_id)
            repository = self._require_repository(dictionary_id)
            entries = repository.lookup_entries(word)
            render_entry_key = repository.preferred_render_entry_key(word, entries)
            render_url = (
                f"/render/entry/{route_quote(source.id)}/{route_quote(render_entry_key)}"
                if render_entry_key
                else None
            )
            self._send_json(
                {
                    "query": word,
                    "normalizedQuery": repository.normalize(word),
                    "dictionary": source.to_api_dict(),
                    "entries": [asdict(entry) for entry in entries],
                    "htmlRenderUrl": render_url,
                }
            )
            return

        if parsed.path == "/api/suggestions":
            params = parse_qs(parsed.query)
            dictionary_id = params.get("dictionaryId", [BUILTIN_DICTIONARY_ID])[0]
            raw_query = params.get("q", [""])[0]
            source = self._require_source(dictionary_id)
            repository = self._require_repository(dictionary_id)
            suggestions = repository.suggestions(raw_query, limit=20)
            self._send_json(
                {
                    "query": raw_query,
                    "normalizedQuery": repository.normalize(raw_query),
                    "dictionary": source.to_api_dict(),
                    "suggestions": suggestions,
                }
            )
            return

        if parsed.path == "/api/user/favorites":
            params = parse_qs(parsed.query)
            limit = clamp_int(params.get("limit", [50])[0], default=50, minimum=1, maximum=500)
            offset = clamp_int(params.get("offset", [0])[0], default=0, minimum=0, maximum=100_000)
            favorites = self.user_repository.list_favorites(limit=limit, offset=offset)
            self._send_json(
                {
                    "userData": self.user_repository.metadata(),
                    "favorites": [asdict(item) for item in favorites],
                    "limit": limit,
                    "offset": offset,
                }
            )
            return

        if parsed.path == "/api/user/word-state":
            params = parse_qs(parsed.query)
            word = params.get("word", [""])[0]
            dictionary_id = params.get("dictionaryId", [None])[0]
            self._send_json(
                {
                    "userData": self.user_repository.metadata(),
                    "state": self.user_repository.get_word_state(word, dictionary_id),
                }
            )
            return

        if parsed.path == "/api/user/word-groups":
            groups = self.user_repository.list_word_groups()
            self._send_json(
                {
                    "userData": self.user_repository.metadata(),
                    "wordGroups": [asdict(item) for item in groups],
                }
            )
            return

        if parsed.path.startswith("/render/entry/"):
            self._handle_render_entry(parsed.path)
            return

        if parsed.path.startswith("/render/asset/"):
            self._handle_render_asset(parsed.path)
            return

        self._send_json(
            {
                "ok": False,
                "error": "Not found",
                "availableRoutes": [
                    "/health",
                    "/api/dictionaries",
                    "/api/lookup?word=hello&dictionaryId=builtin.default",
                    "/api/suggestions?q=hel&dictionaryId=builtin.default",
                    "/api/user/favorites?limit=50",
                    "/api/user/word-state?word=hello&dictionaryId=builtin.default",
                    "/api/user/word-groups",
                ],
            },
            status=HTTPStatus.NOT_FOUND,
        )

    def do_POST(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        body = self._read_json_body()

        if parsed.path == "/api/user/set-favorite":
            word = str(body.get("word", ""))
            favorite = parse_bool_value(body.get("favorite", True))
            self._send_json(
                {
                    "userData": self.user_repository.metadata(),
                    "result": self.user_repository.set_favorite(word, favorite),
                }
            )
            return

        if parsed.path == "/api/user/add-word-to-group":
            word = str(body.get("word", ""))
            group_id = clamp_int(body.get("groupId"), default=0, minimum=0, maximum=2_147_483_647)
            self._send_json(
                {
                    "userData": self.user_repository.metadata(),
                    "result": self.user_repository.add_word_to_group(word, group_id),
                }
            )
            return

        self._send_json({"ok": False, "error": "Not found"}, status=HTTPStatus.NOT_FOUND)

    def log_message(self, format: str, *args: object) -> None:
        return

    def _handle_render_entry(self, path: str) -> None:
        parts = path.split("/")
        if len(parts) < 5:
            self._send_text("Bad entry render path", status=HTTPStatus.BAD_REQUEST)
            return

        dictionary_id = unquote(parts[3])
        entry_key = unquote(parts[4])
        asset_path = "/".join(unquote(part) for part in parts[5:] if part)

        repository = self._require_repository(dictionary_id)

        if asset_path:
            asset = repository.fetch_asset(asset_path)
            if asset is None:
                self._send_text(f"Asset not found: {asset_path}", status=HTTPStatus.NOT_FOUND)
                return
            _, mime_type, data = asset
            self._send_bytes(data, mime_type=mime_type)
            return

        document = repository.render_entry_document(entry_key)
        self._send_bytes(document.encode("utf-8"), mime_type="text/html; charset=utf-8")

    def _handle_render_asset(self, path: str) -> None:
        parts = path.split("/")
        if len(parts) < 5:
            self._send_text("Bad asset render path", status=HTTPStatus.BAD_REQUEST)
            return

        dictionary_id = unquote(parts[3])
        asset_path = "/".join(unquote(part) for part in parts[4:] if part)
        repository = self._require_repository(dictionary_id)
        asset = repository.fetch_asset(asset_path)
        if asset is None:
            self._send_text(f"Asset not found: {asset_path}", status=HTTPStatus.NOT_FOUND)
            return

        _, mime_type, data = asset
        self._send_bytes(data, mime_type=mime_type)

    def _require_source(self, dictionary_id: str) -> DictionarySource:
        try:
            return self.source_registry.get_source(dictionary_id)
        except KeyError:
            return self.source_registry.get_source(BUILTIN_DICTIONARY_ID)

    def _require_repository(self, dictionary_id: str) -> DictionaryRepository:
        source = self._require_source(dictionary_id)
        if source.is_selectable:
            return self.source_registry.get_repository(source.id)

        if source.id != BUILTIN_DICTIONARY_ID:
            return self.source_registry.get_repository(BUILTIN_DICTIONARY_ID)

        try:
            return self.source_registry.get_repository(BUILTIN_DICTIONARY_ID)
        except (KeyError, ValueError) as error:
            raise ValueError(str(error)) from error

    def _send_json(self, payload: dict[str, Any], status: HTTPStatus = HTTPStatus.OK) -> None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self._write_cors_headers()
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _read_json_body(self) -> dict[str, Any]:
        length = clamp_int(self.headers.get("Content-Length"), default=0, minimum=0, maximum=1_000_000)
        if length == 0:
            return {}
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError as error:
            raise ValueError(f"Invalid JSON request body: {error}") from error
        if not isinstance(payload, dict):
            raise ValueError("JSON request body must be an object")
        return payload

    def _send_text(self, text: str, status: HTTPStatus = HTTPStatus.OK) -> None:
        self._send_bytes(text.encode("utf-8"), mime_type="text/plain; charset=utf-8", status=status)

    def _send_bytes(
        self, data: bytes, mime_type: str, status: HTTPStatus = HTTPStatus.OK
    ) -> None:
        self.send_response(status)
        self._write_cors_headers()
        self.send_header("Content-Type", mime_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _write_cors_headers(self) -> None:
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def handle_one_request(self) -> None:
        try:
            super().handle_one_request()
        except ValueError as error:
            self._send_json({"ok": False, "error": str(error)}, status=HTTPStatus.BAD_REQUEST)


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="FuckYouXcode local dictionary server")
    parser.add_argument("--host", default="127.0.0.1", help="Host to bind to")
    parser.add_argument("--port", default=8765, type=int, help="Port to bind to")
    parser.add_argument("--db", type=Path, help="Explicit path to the built-in dic_.db")
    parser.add_argument("--user-db", type=Path, help="Explicit path to user_1.db")
    parser.add_argument(
        "--dictionary-id",
        default=BUILTIN_DICTIONARY_ID,
        help="Dictionary ID to use for one-off CLI operations",
    )
    parser.add_argument("--lookup", help="Run one lookup and exit as JSON")
    parser.add_argument("--list-dictionaries", action="store_true", help="Print available dictionaries as JSON")
    parser.add_argument("--render-entry", help="Print rendered HTML for an entry and exit")
    parser.add_argument("--list-favorites", action="store_true", help="Print favorite words as JSON")
    parser.add_argument("--word-state", help="Print favorite/highlight/annotation/group state for a word as JSON")
    parser.add_argument(
        "--set-favorite",
        nargs=2,
        metavar=("WORD", "TRUE_OR_FALSE"),
        help="Set favorite state for a word and exit as JSON",
    )
    parser.add_argument("--list-word-groups", action="store_true", help="Print word groups as JSON")
    parser.add_argument(
        "--add-word-to-group",
        nargs=2,
        metavar=("WORD", "GROUP_ID"),
        help="Add a word to a group and exit as JSON",
    )
    return parser


def main() -> None:
    parser = build_arg_parser()
    args = parser.parse_args()

    builtin_db_path = (args.db.expanduser() if args.db else find_default_db_path()).resolve()
    user_db_path = (args.user_db.expanduser() if args.user_db else find_default_user_db_path()).resolve()
    source_registry = DictionarySourceRegistry(builtin_db_path)
    user_repository = UserDataRepository(user_db_path)

    if args.list_dictionaries:
        payload = {"dictionaries": [source.to_api_dict() for source in source_registry.list_sources()]}
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return

    if args.lookup:
        repository = source_registry.get_repository(args.dictionary_id)
        source = source_registry.get_source(args.dictionary_id)
        entries = repository.lookup_entries(args.lookup)
        render_entry_key = repository.preferred_render_entry_key(args.lookup, entries)
        payload = {
            "query": args.lookup,
            "normalizedQuery": repository.normalize(args.lookup),
            "dictionary": source.to_api_dict(),
            "entries": [asdict(entry) for entry in entries],
            "htmlRenderUrl": (
                f"/render/entry/{route_quote(source.id)}/{route_quote(render_entry_key)}"
                if render_entry_key
                else None
            ),
        }
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return

    if args.render_entry:
        repository = source_registry.get_repository(args.dictionary_id)
        print(repository.render_entry_document(args.render_entry))
        return

    if args.list_favorites:
        favorites = user_repository.list_favorites(limit=200)
        payload = {
            "userData": user_repository.metadata(),
            "favorites": [asdict(item) for item in favorites],
        }
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return

    if args.word_state:
        payload = {
            "userData": user_repository.metadata(),
            "state": user_repository.get_word_state(args.word_state, args.dictionary_id),
        }
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return

    if args.set_favorite:
        word, favorite_raw = args.set_favorite
        payload = {
            "userData": user_repository.metadata(),
            "result": user_repository.set_favorite(word, parse_bool_value(favorite_raw)),
        }
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return

    if args.list_word_groups:
        payload = {
            "userData": user_repository.metadata(),
            "wordGroups": [asdict(item) for item in user_repository.list_word_groups()],
        }
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return

    if args.add_word_to_group:
        word, group_id_raw = args.add_word_to_group
        payload = {
            "userData": user_repository.metadata(),
            "result": user_repository.add_word_to_group(
                word,
                clamp_int(group_id_raw, default=0, minimum=0, maximum=2_147_483_647),
            ),
        }
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return

    handler = type(
        "BoundDictionaryRequestHandler",
        (DictionaryRequestHandler,),
        {
            "source_registry": source_registry,
            "user_repository": user_repository,
        },
    )
    server = ThreadingHTTPServer((args.host, args.port), handler)
    print(f"Serving FuckYouXcode dictionary bridge on http://{args.host}:{args.port}")
    print(f"Built-in dictionary DB: {builtin_db_path}")
    print(f"Catalog path: {source_registry.catalog_path}")
    print(f"User database: {user_db_path}")
    server.serve_forever()


if __name__ == "__main__":
    main()
