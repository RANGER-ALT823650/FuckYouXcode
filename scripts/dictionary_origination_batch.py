#!/usr/bin/env python3
"""Export dictionary entries for LLM batches and import generated originations.

The export step creates JSONL batch files plus matching prompt files. The import
step validates JSONL results and updates entries.origination in the SQLite DB.
"""

from __future__ import annotations

import argparse
import json
import shutil
import sqlite3
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Iterable


DEFAULT_DB = Path("Resources/dic_.db")
DEFAULT_OUT = Path("var/origination_batches")

PROMPT_TEMPLATE = """你是一名擅长英语词源、词根词缀、语义联想和词汇记忆的中文词汇老师。

请根据给定英文单词，重新生成该词的「词源与记忆说明」。这个字段现在需要同时承担两件事：
1. 帮助中文学习者记住这个单词；
2. 重新生成一组 related 相关词，并将它们自然合并到说明中，相关词需要保留可点击跳转功能。

输入信息：
- 单词：{{word}}
- 词性：{{pos}}
- 中文/英文释义：{{definition}}
- 例句：{{examples}}

注意：
- 不要复用旧的 related / hwd 字段。
- related 词必须由你根据词源、词根、词缀、语义关系、近义词、反义词、同根词、形近易混词重新生成。
- related 词应优先选择词典中常见、值得跳转学习的英文单词。
- related 词数量控制在 3 到 6 个。
- related 词不要包含当前单词本身，不要重复，不要选择过于生僻或关系牵强的词。

输出要求：
- 只输出一段中文内容，不要 Markdown，不要标题，不要编号。
- 总长度控制在 150 到 260 个汉字之间。
- 相关词必须使用固定格式 [[word]]，例如 [[rupture]]、[[disrupt]]。这个格式会被前端渲染为可点击跳转链接。
- related 词要自然嵌入解释中，不要单独机械罗列。
- 如果有可靠词源，请说明来源语言、词根/词缀拆解，以及含义如何演变到现代意思。
- 如果词源不适合记忆，不要硬编；可以改用词形联想、语义逻辑、使用场景或近义词辨析。
- 如果不确定词源事实，请避免断言，可以写成“记忆上可理解为”或“可以这样记”。

输出风格示例：
abrupt 可以从 ab- “离开” 和 rupt “断裂” 来记，底层画面是“突然断开”。所以它既能表示事情突然发生，也能形容人说话唐突、生硬，像交流被硬生生截断。可以顺带记 [[rupture]] 的“破裂”、[[disrupt]] 的“扰乱”，它们都带有 rupt “断开、破坏”的核心感觉；和 [[sudden]] 相比，abrupt 更强调来得生硬、没有过渡。
"""

BATCH_INSTRUCTIONS = """请处理同目录下的 `{batch_file}`。

这个 JSONL 文件每一行是一条词典记录，字段包括：
- id: 数据库 entries.id，必须原样返回
- word: 单词
- pos: 词性
- definition: 释义
- examples: 例句

请为每一行生成一个新的 origination，并严格输出 JSONL：
{{"id": 1, "word": "abrupt", "origination": "abrupt 可以从 ... [[rupture]] ..."}}

要求：
- 输出文件名建议为 `{result_file}`。
- 一行对应一条输入记录，不要漏行，不要多行解释，不要 Markdown 代码块。
- JSON 必须可被 Python 的 json.loads 逐行解析。
- word 如果返回，必须和输入 word 一致。
- origination 里保留 [[word]] 标记，它会在 app 中渲染为可点击跳转。
"""


@dataclass(frozen=True)
class Entry:
    id: int
    word: str
    pos: str
    definition: str
    examples: str


def connect(db_path: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    return conn


def ensure_schema(conn: sqlite3.Connection) -> None:
    columns = {
        row["name"]
        for row in conn.execute("PRAGMA table_info(entries)")
    }
    required = {"id", "word", "pos", "definition", "examples", "origination", "hwd"}
    missing = required - columns
    if missing:
        raise SystemExit(f"entries table is missing required columns: {', '.join(sorted(missing))}")


def build_where(args: argparse.Namespace) -> tuple[str, list[Any]]:
    clauses = ["definition <> ''"]
    params: list[Any] = []

    if not args.include_non_simple:
        clauses.append("word NOT GLOB '*[^A-Za-z]*'")
    if args.only_missing:
        clauses.append("(origination IS NULL OR origination = '')")
    if args.stale_origination:
        clauses.append("origination <> ''")
        clauses.append("hwd <> ''")
        clauses.append("origination NOT GLOB '*[一-龥]*'")
    if args.level:
        clauses.append("level LIKE ?")
        params.append(f"%{args.level}%")
    if args.min_frequency is not None:
        clauses.append("frequency >= ?")
        params.append(args.min_frequency)
    if args.words_file:
        words = read_words(args.words_file)
        if not words:
            raise SystemExit(f"No words found in {args.words_file}")
        placeholders = ",".join("?" for _ in words)
        clauses.append(f"word COLLATE NOCASE IN ({placeholders})")
        params.extend(words)

    return " AND ".join(clauses), params


def read_words(path: Path) -> list[str]:
    words: list[str] = []
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            word = line.strip()
            if word and not word.startswith("#"):
                words.append(word)
    return words


def fetch_entries(conn: sqlite3.Connection, args: argparse.Namespace) -> list[Entry]:
    where_sql, params = build_where(args)

    order_sql = {
        "id": "id ASC",
        "word": "word COLLATE NOCASE ASC, id ASC",
        "frequency": "frequency DESC, word COLLATE NOCASE ASC, id ASC",
        "random": "random()",
    }[args.order_by]

    limit_sql = ""
    if args.limit is not None:
        limit_sql = " LIMIT ?"
        params.append(args.limit)

    if args.dedupe_word:
        rows = conn.execute(
            f"""
            WITH ranked_entries AS (
                SELECT
                    id,
                    word,
                    pos,
                    frequency,
                    definition,
                    examples,
                    ROW_NUMBER() OVER (
                        PARTITION BY lower(word)
                        ORDER BY frequency DESC, id ASC
                    ) AS duplicate_rank
                FROM entries
                WHERE {where_sql}
            )
            SELECT id, word, pos, definition, examples, frequency
            FROM ranked_entries
            WHERE duplicate_rank = 1
            ORDER BY {order_sql}
            {limit_sql}
            """,
            params,
        ).fetchall()
    else:
        rows = conn.execute(
            f"""
            SELECT id, word, pos, definition, examples
            FROM entries
            WHERE {where_sql}
            ORDER BY {order_sql}
            {limit_sql}
            """,
            params,
        ).fetchall()

    return [
        Entry(
            id=int(row["id"]),
            word=str(row["word"] or ""),
            pos=str(row["pos"] or ""),
            definition=str(row["definition"] or ""),
            examples=str(row["examples"] or ""),
        )
        for row in rows
    ]


def chunks(items: list[Entry], size: int) -> Iterable[list[Entry]]:
    for index in range(0, len(items), size):
        yield items[index:index + size]


def export_batches(args: argparse.Namespace) -> None:
    db_path = args.db
    out_dir = args.out
    out_dir.mkdir(parents=True, exist_ok=True)

    with connect(db_path) as conn:
        ensure_schema(conn)
        entries = fetch_entries(conn, args)

    if not entries:
        print("No entries matched the export filters.")
        return

    manifest: list[dict[str, Any]] = []
    for batch_index, batch_entries in enumerate(chunks(entries, args.batch_size), start=1):
        stem = f"batch_{batch_index:04d}"
        batch_file = out_dir / f"{stem}.jsonl"
        prompt_file = out_dir / f"{stem}_prompt.md"
        result_file = f"{stem}_results.jsonl"

        with batch_file.open("w", encoding="utf-8") as handle:
            for entry in batch_entries:
                payload = {
                    "id": entry.id,
                    "word": entry.word,
                    "pos": entry.pos,
                    "definition": entry.definition,
                    "examples": entry.examples,
                }
                handle.write(json.dumps(payload, ensure_ascii=False) + "\n")

        prompt = PROMPT_TEMPLATE + "\n\n" + BATCH_INSTRUCTIONS.format(
            batch_file=batch_file.name,
            result_file=result_file,
        )
        prompt_file.write_text(prompt, encoding="utf-8")

        manifest.append(
            {
                "batch": batch_index,
                "input": str(batch_file),
                "prompt": str(prompt_file),
                "suggested_result": str(out_dir / result_file),
                "count": len(batch_entries),
                "first_id": batch_entries[0].id,
                "last_id": batch_entries[-1].id,
            }
        )

    manifest_file = out_dir / "manifest.json"
    manifest_file.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"Exported {len(entries)} entries into {len(manifest)} batch(es).")
    print(f"Output directory: {out_dir}")
    print(f"Manifest: {manifest_file}")
    print(f"First prompt: {manifest[0]['prompt']}")


def iter_result_files(path: Path) -> list[Path]:
    if path.is_file():
        return [path]
    if not path.is_dir():
        raise SystemExit(f"Results path does not exist: {path}")

    files = sorted(path.glob("*.jsonl"))
    return [
        file
        for file in files
        if not file.name.startswith("batch_") or file.name.endswith("_results.jsonl")
    ]


def parse_json_records(path: Path) -> list[dict[str, Any]]:
    text = path.read_text(encoding="utf-8").strip()
    if not text:
        return []

    if text.startswith("["):
        data = json.loads(text)
        if not isinstance(data, list):
            raise ValueError(f"{path} contains JSON but not a list")
        return data

    records: list[dict[str, Any]] = []
    for line_no, line in enumerate(text.splitlines(), start=1):
        stripped = line.strip()
        if not stripped:
            continue
        try:
            record = json.loads(stripped)
        except json.JSONDecodeError as exc:
            raise ValueError(f"{path}:{line_no}: invalid JSON: {exc}") from exc
        if not isinstance(record, dict):
            raise ValueError(f"{path}:{line_no}: expected a JSON object")
        records.append(record)
    return records


def load_results(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    files = iter_result_files(path)
    if not files:
        raise SystemExit(f"No JSONL result files found under {path}")

    for file in files:
        records.extend(parse_json_records(file))

    return records


def normalize_record(raw: dict[str, Any]) -> tuple[int, str | None, str]:
    if "id" not in raw:
        raise ValueError(f"Missing id in result record: {raw}")
    if "origination" not in raw:
        raise ValueError(f"Missing origination in result record id={raw.get('id')}")

    entry_id = int(raw["id"])
    word = str(raw["word"]).strip() if raw.get("word") is not None else None
    origination = str(raw["origination"]).strip()

    if not origination:
        raise ValueError(f"Empty origination for id={entry_id}")
    if len(origination) > 1000:
        raise ValueError(f"Origination is too long for id={entry_id}: {len(origination)} chars")

    return entry_id, word, origination


def backup_db(db_path: Path, backup_dir: Path) -> Path:
    backup_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    backup_path = backup_dir / f"{db_path.name}.{stamp}.bak"

    with sqlite3.connect(str(db_path)) as source, sqlite3.connect(str(backup_path)) as target:
        source.backup(target)

    return backup_path


def import_results(args: argparse.Namespace) -> None:
    db_path = args.db
    records = load_results(args.results)
    normalized = [normalize_record(record) for record in records]

    seen: set[int] = set()
    duplicates: set[int] = set()
    for entry_id, _, _ in normalized:
        if entry_id in seen:
            duplicates.add(entry_id)
        seen.add(entry_id)
    if duplicates:
        raise SystemExit(f"Duplicate ids in results: {', '.join(map(str, sorted(duplicates)[:20]))}")

    with connect(db_path) as conn:
        ensure_schema(conn)
        existing = {
            int(row["id"]): str(row["word"] or "")
            for row in conn.execute(
                f"SELECT id, word FROM entries WHERE id IN ({','.join('?' for _ in normalized)})",
                [entry_id for entry_id, _, _ in normalized],
            )
        } if normalized else {}

        for entry_id, word, _ in normalized:
            if entry_id not in existing:
                raise SystemExit(f"Result id does not exist in DB: {entry_id}")
            if word and word.casefold() != existing[entry_id].casefold():
                raise SystemExit(
                    f"Word mismatch for id={entry_id}: result has {word!r}, DB has {existing[entry_id]!r}"
                )

        if args.dry_run:
            print(f"Dry run OK. Would update {len(normalized)} row(s).")
            return

        backup_path = backup_db(db_path, args.backup_dir)
        print(f"Backup written: {backup_path}")

        update_sql = (
            "UPDATE entries SET origination = ?, hwd = '' WHERE id = ?"
            if args.clear_hwd
            else "UPDATE entries SET origination = ? WHERE id = ?"
        )
        with conn:
            conn.executemany(
                update_sql,
                [(origination, entry_id) for entry_id, _, origination in normalized],
            )

        print(f"Updated {len(normalized)} row(s) in {db_path}.")
        if args.clear_hwd:
            print("Cleared hwd for updated rows.")


def make_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Export dictionary origination batches and import generated results.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""Examples:
  # Show this help
  ./scripts/dictionary_origination_batch.py -h

  # Export high-frequency words in batches of 15
  ./scripts/dictionary_origination_batch.py export --batch-size 15 --order-by frequency

  # Export only CET-4 entries
  ./scripts/dictionary_origination_batch.py export --level 四级 --batch-size 15

  # Validate generated results without changing the DB
  ./scripts/dictionary_origination_batch.py import --results var/origination_batches --dry-run

  # Import generated results and clear old hwd related words
  ./scripts/dictionary_origination_batch.py import --results var/origination_batches --clear-hwd
""",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    export = subparsers.add_parser("export", help="Create JSONL batches and prompts")
    export.add_argument("--db", type=Path, default=DEFAULT_DB, help="Dictionary DB to export from")
    export.add_argument("--out", type=Path, default=DEFAULT_OUT, help="Directory for generated JSONL batches and prompts")
    export.add_argument("--batch-size", type=int, default=50, help="Number of entries per batch")
    export.add_argument("--limit", type=int, help="Maximum number of entries to export")
    export.add_argument("--only-missing", action="store_true", help="Only export rows whose origination is empty")
    export.add_argument(
        "--stale-origination",
        action="store_true",
        help="Only export old English originations that still have hwd/Related",
    )
    export.add_argument("--level", help="Filter by level text, e.g. 四级 or 雅思")
    export.add_argument("--min-frequency", type=int)
    export.add_argument("--words-file", type=Path, help="One word per line")
    export.add_argument(
        "--dedupe-word",
        action="store_true",
        help="Export at most one row for each case-insensitive word",
    )
    export.add_argument(
        "--include-non-simple",
        action="store_true",
        help="Include phrases, slashed forms, punctuation, and non-letter headwords",
    )
    export.add_argument(
        "--order-by",
        choices=["id", "word", "frequency", "random"],
        default="frequency",
    )
    export.set_defaults(func=export_batches)

    import_cmd = subparsers.add_parser("import", help="Validate JSONL results and update DB")
    import_cmd.add_argument("--db", type=Path, default=DEFAULT_DB, help="Dictionary DB to update")
    import_cmd.add_argument("--results", type=Path, required=True, help="Result JSONL file or directory of *_results.jsonl files")
    import_cmd.add_argument("--backup-dir", type=Path, default=Path("var/db_backups"), help="Directory for automatic DB backups")
    import_cmd.add_argument("--dry-run", action="store_true", help="Validate results without writing to DB")
    import_cmd.add_argument("--clear-hwd", action="store_true", help="Clear old hwd related words for updated rows")
    import_cmd.set_defaults(func=import_results)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = make_parser()
    args = parser.parse_args(argv)
    if args.command == "export" and args.batch_size <= 0:
        parser.error("--batch-size must be positive")

    try:
        args.func(args)
    except (sqlite3.Error, OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
