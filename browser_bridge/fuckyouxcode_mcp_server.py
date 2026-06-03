#!/usr/bin/env python3
"""MCP stdio server for FuckYouXcode dictionary and user data tools."""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict
from pathlib import Path
from typing import Any, BinaryIO

from dictionary_server import (
    BUILTIN_DICTIONARY_ID,
    DictionarySourceRegistry,
    UserDataRepository,
    clamp_int,
    find_default_db_path,
    find_default_user_db_path,
    parse_bool_value,
    route_quote,
)


SUPPORTED_PROTOCOL_VERSIONS = [
    "2025-11-25",
    "2025-06-18",
    "2025-03-26",
    "2024-11-05",
]


TOOLS: list[dict[str, Any]] = [
    {
        "name": "dictionary_lookup",
        "description": "Look up a word in the FuckYouXcode dictionary database.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "word": {"type": "string"},
                "dictionaryId": {"type": "string", "default": BUILTIN_DICTIONARY_ID},
            },
            "required": ["word"],
        },
    },
    {
        "name": "dictionary_suggestions",
        "description": "Return dictionary prefix or meaning suggestions.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string"},
                "dictionaryId": {"type": "string", "default": BUILTIN_DICTIONARY_ID},
                "limit": {"type": "integer", "minimum": 1, "maximum": 100, "default": 20},
            },
            "required": ["query"],
        },
    },
    {
        "name": "dictionary_list_dictionaries",
        "description": "List available built-in and imported dictionaries.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "user_list_favorites",
        "description": "List favorite words from the FuckYouXcode user database.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "limit": {"type": "integer", "minimum": 1, "maximum": 500, "default": 50},
                "offset": {"type": "integer", "minimum": 0, "default": 0},
            },
        },
    },
    {
        "name": "user_get_word_state",
        "description": "Get favorite, highlight, annotation, and word-group state for one word.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "word": {"type": "string"},
                "dictionaryId": {"type": "string", "default": BUILTIN_DICTIONARY_ID},
            },
            "required": ["word"],
        },
    },
    {
        "name": "user_set_favorite",
        "description": "Add or remove a favorite word in the FuckYouXcode user database.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "word": {"type": "string"},
                "favorite": {"type": "boolean", "default": True},
            },
            "required": ["word", "favorite"],
        },
    },
    {
        "name": "user_list_word_groups",
        "description": "List user word groups when the user database has group tables.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "user_add_word_to_group",
        "description": "Add a word to an existing user word group.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "word": {"type": "string"},
                "groupId": {"type": "integer", "minimum": 1},
            },
            "required": ["word", "groupId"],
        },
    },
]


class ToolExecutor:
    def __init__(
        self,
        source_registry: DictionarySourceRegistry,
        user_repository: UserDataRepository,
        default_dictionary_id: str,
    ) -> None:
        self.source_registry = source_registry
        self.user_repository = user_repository
        self.default_dictionary_id = default_dictionary_id

    def call(self, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        if name == "dictionary_lookup":
            return self._dictionary_lookup(arguments)
        if name == "dictionary_suggestions":
            return self._dictionary_suggestions(arguments)
        if name == "dictionary_list_dictionaries":
            return self._dictionary_list_dictionaries()
        if name == "user_list_favorites":
            return self._user_list_favorites(arguments)
        if name == "user_get_word_state":
            return self._user_get_word_state(arguments)
        if name == "user_set_favorite":
            return self._user_set_favorite(arguments)
        if name == "user_list_word_groups":
            return self._user_list_word_groups()
        if name == "user_add_word_to_group":
            return self._user_add_word_to_group(arguments)
        raise ValueError(f"unknown tool: {name}")

    def _dictionary_lookup(self, arguments: dict[str, Any]) -> dict[str, Any]:
        word = str(arguments.get("word", "")).strip()
        if not word:
            raise ValueError("word is required")
        dictionary_id = str(arguments.get("dictionaryId") or self.default_dictionary_id)
        source = self._source_or_default(dictionary_id)
        repository = self.source_registry.get_repository(source.id)
        entries = repository.lookup_entries(word)
        render_entry_key = repository.preferred_render_entry_key(word, entries)
        return {
            "query": word,
            "normalizedQuery": repository.normalize(word),
            "dictionary": source.to_api_dict(),
            "entries": [asdict(entry) for entry in entries],
            "htmlRenderUrl": (
                f"/render/entry/{route_quote(source.id)}/{route_quote(render_entry_key)}"
                if render_entry_key
                else None
            ),
        }

    def _dictionary_suggestions(self, arguments: dict[str, Any]) -> dict[str, Any]:
        query = str(arguments.get("query", "")).strip()
        if not query:
            raise ValueError("query is required")
        dictionary_id = str(arguments.get("dictionaryId") or self.default_dictionary_id)
        limit = clamp_int(arguments.get("limit"), default=20, minimum=1, maximum=100)
        source = self._source_or_default(dictionary_id)
        repository = self.source_registry.get_repository(source.id)
        return {
            "query": query,
            "normalizedQuery": repository.normalize(query),
            "dictionary": source.to_api_dict(),
            "suggestions": repository.suggestions(query, limit=limit),
        }

    def _dictionary_list_dictionaries(self) -> dict[str, Any]:
        return {
            "dictionaries": [
                source.to_api_dict()
                for source in self.source_registry.list_sources()
            ]
        }

    def _user_list_favorites(self, arguments: dict[str, Any]) -> dict[str, Any]:
        limit = clamp_int(arguments.get("limit"), default=50, minimum=1, maximum=500)
        offset = clamp_int(arguments.get("offset"), default=0, minimum=0, maximum=100_000)
        return {
            "userData": self.user_repository.metadata(),
            "favorites": [
                asdict(item)
                for item in self.user_repository.list_favorites(limit=limit, offset=offset)
            ],
            "limit": limit,
            "offset": offset,
        }

    def _user_get_word_state(self, arguments: dict[str, Any]) -> dict[str, Any]:
        word = str(arguments.get("word", "")).strip()
        if not word:
            raise ValueError("word is required")
        dictionary_id = str(arguments.get("dictionaryId") or self.default_dictionary_id)
        return {
            "userData": self.user_repository.metadata(),
            "state": self.user_repository.get_word_state(word, dictionary_id),
        }

    def _user_set_favorite(self, arguments: dict[str, Any]) -> dict[str, Any]:
        word = str(arguments.get("word", "")).strip()
        favorite = parse_bool_value(arguments.get("favorite", True))
        return {
            "userData": self.user_repository.metadata(),
            "result": self.user_repository.set_favorite(word, favorite),
        }

    def _user_list_word_groups(self) -> dict[str, Any]:
        return {
            "userData": self.user_repository.metadata(),
            "wordGroups": [
                asdict(item)
                for item in self.user_repository.list_word_groups()
            ],
        }

    def _user_add_word_to_group(self, arguments: dict[str, Any]) -> dict[str, Any]:
        word = str(arguments.get("word", "")).strip()
        group_id = clamp_int(arguments.get("groupId"), default=0, minimum=0, maximum=2_147_483_647)
        return {
            "userData": self.user_repository.metadata(),
            "result": self.user_repository.add_word_to_group(word, group_id),
        }

    def _source_or_default(self, dictionary_id: str):
        try:
            source = self.source_registry.get_source(dictionary_id)
        except KeyError:
            source = self.source_registry.get_source(BUILTIN_DICTIONARY_ID)
        if source.is_selectable:
            return source
        return self.source_registry.get_source(BUILTIN_DICTIONARY_ID)


class MCPServer:
    def __init__(self, executor: ToolExecutor) -> None:
        self.executor = executor

    def serve(self) -> None:
        while True:
            message = read_message(sys.stdin.buffer)
            if message is None:
                break
            response = self.handle_message(message)
            if response is not None:
                write_message(sys.stdout.buffer, response)

    def handle_message(self, message: dict[str, Any]) -> dict[str, Any] | None:
        request_id = message.get("id")
        method = message.get("method")
        params = message.get("params") if isinstance(message.get("params"), dict) else {}

        if request_id is None:
            return None

        try:
            if method == "initialize":
                return self._response(request_id, self._initialize(params))
            if method == "tools/list":
                return self._response(request_id, {"tools": TOOLS})
            if method == "tools/call":
                return self._response(request_id, self._tools_call(params))
            if method == "resources/list":
                return self._response(request_id, {"resources": []})
            if method == "prompts/list":
                return self._response(request_id, {"prompts": []})
            if method == "ping":
                return self._response(request_id, {})
            return self._error(request_id, -32601, f"Method not found: {method}")
        except Exception as error:
            return self._error(request_id, -32603, str(error))

    def _initialize(self, params: dict[str, Any]) -> dict[str, Any]:
        client_version = str(params.get("protocolVersion") or SUPPORTED_PROTOCOL_VERSIONS[0])
        protocol_version = (
            client_version
            if client_version in SUPPORTED_PROTOCOL_VERSIONS
            else SUPPORTED_PROTOCOL_VERSIONS[0]
        )
        return {
            "protocolVersion": protocol_version,
            "capabilities": {
                "tools": {"listChanged": False},
                "resources": {},
                "prompts": {},
            },
            "serverInfo": {
                "name": "fuckyouxcode",
                "version": "0.1.0",
            },
        }

    def _tools_call(self, params: dict[str, Any]) -> dict[str, Any]:
        name = str(params.get("name", ""))
        arguments = params.get("arguments")
        if not isinstance(arguments, dict):
            arguments = {}

        try:
            payload = self.executor.call(name, arguments)
            return tool_result(payload)
        except Exception as error:
            return tool_result({"error": str(error)}, is_error=True)

    @staticmethod
    def _response(request_id: Any, result: dict[str, Any]) -> dict[str, Any]:
        return {"jsonrpc": "2.0", "id": request_id, "result": result}

    @staticmethod
    def _error(request_id: Any, code: int, message: str) -> dict[str, Any]:
        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "error": {"code": code, "message": message},
        }


def tool_result(payload: dict[str, Any], is_error: bool = False) -> dict[str, Any]:
    return {
        "content": [
            {
                "type": "text",
                "text": json.dumps(payload, ensure_ascii=False, indent=2),
            }
        ],
        "structuredContent": payload,
        "isError": is_error,
    }


def read_message(stream: BinaryIO) -> dict[str, Any] | None:
    while True:
        first_line = stream.readline()
        if first_line == b"":
            return None
        if first_line.strip():
            break

    if first_line.lower().startswith(b"content-length:"):
        length = parse_content_length(first_line)
        while True:
            header = stream.readline()
            if header in (b"", b"\r\n", b"\n"):
                break
            if header.lower().startswith(b"content-length:"):
                length = parse_content_length(header)
        if length <= 0:
            raise ValueError("Missing Content-Length")
        body = stream.read(length)
        if len(body) != length:
            return None
        return json.loads(body.decode("utf-8"))

    return json.loads(first_line.decode("utf-8"))


def parse_content_length(header: bytes) -> int:
    _, _, value = header.partition(b":")
    return int(value.strip())


def write_message(stream: BinaryIO, message: dict[str, Any]) -> None:
    body = json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    stream.write(f"Content-Length: {len(body)}\r\n\r\n".encode("ascii"))
    stream.write(body)
    stream.flush()


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="FuckYouXcode MCP stdio server")
    parser.add_argument("--db", type=Path, help="Explicit path to the built-in dic_.db")
    parser.add_argument("--user-db", type=Path, help="Explicit path to user_1.db")
    parser.add_argument(
        "--dictionary-id",
        default=BUILTIN_DICTIONARY_ID,
        help="Default dictionary ID for tool calls that omit dictionaryId",
    )
    return parser


def main() -> None:
    args = build_arg_parser().parse_args()
    builtin_db_path = (args.db.expanduser() if args.db else find_default_db_path()).resolve()
    user_db_path = (args.user_db.expanduser() if args.user_db else find_default_user_db_path()).resolve()
    executor = ToolExecutor(
        source_registry=DictionarySourceRegistry(builtin_db_path),
        user_repository=UserDataRepository(user_db_path),
        default_dictionary_id=args.dictionary_id,
    )
    MCPServer(executor).serve()


if __name__ == "__main__":
    main()
