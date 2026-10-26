#!/usr/bin/env python3
"""Black-box history CLI contracts. Never reads/writes the system clipboard or sends keys.

Run after `make build`: python3 Scripts/test-cli.py [path/to/jiantieban]
Uses a temporary database and a unique preferences suite; existing paste smoke
contracts remain in test-headless-cli.py. Requires the macOS executable.
"""
import concurrent.futures
import json
import os
import pathlib
import subprocess
import struct
import zlib
import sys
import tempfile
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent
BINARY = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / ".build/release/jiantieban"


class Contracts:
    def __init__(self, directory):
        self.home = pathlib.Path(directory) / "data"
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith("JIANTIEBAN_")}
        self.env.update(JIANTIEBAN_HOME=str(self.home),
                        JIANTIEBAN_PREFERENCES_SUITE="rs.jiantieban.cli-tests." + uuid.uuid4().hex,
                        JT_BIN=str(pathlib.Path(directory) / "no-jt"))
        self.calls = 0

    def run(self, *args, data=None, status=0):
        result = subprocess.run([str(BINARY), *map(str, args)], input=data,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env=self.env, timeout=12)
        self.calls += 1
        assert result.returncode == status, (args, result.returncode, result.stdout, result.stderr)
        if status == 0:
            assert result.stderr == b"", (args, result.stderr)
        else:
            assert result.stdout == b"", (args, result.stdout)
        return result

    def json(self, *args, data=None):
        result = self.run(*args, "--json", data=data)
        payload = json.loads(result.stdout)
        assert payload["ok"] is True, (args, payload)
        assert payload["schema_version"] == 1, (args, payload)
        assert payload["command"] == args[0], (args, payload)
        return payload["result"]

    def error(self, *args, status=2, code="invalid_arguments", data=None, json_flag=True):
        flags = ("--json",) if json_flag else ()
        result = self.run(*args, *flags, data=data, status=status)
        payload = json.loads(result.stderr)
        assert payload["ok"] is False, (args, payload)
        assert payload["code"] == code, (args, payload)
        assert payload["schema_version"] == 1, (args, payload)
        assert isinstance(payload["message"], str), (args, payload)
        return result


def main():
    assert BINARY.is_file(), f"Build the executable first: {BINARY}"
    with tempfile.TemporaryDirectory(prefix="jiantieban-cli-contracts-") as directory:
        c = Contracts(directory)
        # Informational/parser-only commands must not create storage or launch GUI.
        c.run("help")
        c.run("version")
        c.json("version")
        c.error("not-a-command")
        assert not c.home.exists(), "Informational/invalid commands created the data directory"

        c.error("get")
        c.error("get", "--latest", "1")
        c.error("get", "1", "--raw")
        c.error("add-text", "--stdin", "extra", data=b"ignored")
        c.error("fav", "1", "--set", "yes")
        c.error("list", "--page-size", "0")
        c.error("list", "--page-size", "1001")
        c.error("list", "--page-size", "2", "--page-size", "3")
        c.error("list", "--unknown")
        c.error("clear")
        assert not c.home.exists(), "Parser failures created the data directory"
        for identifier in ("0", "-1", "+1", "1.0", " 1", "9223372036854775808"):
            c.error("get", identifier)
        assert not c.home.exists(), "Malformed IDs created the data directory"
        c.error("get", "9223372036854775807", status=1, code="item_not_found")

        c.error("add-text", "--stdin", data=b"\xff\xfe", status=1, code="invalid_encoding")
        c.error("add-text", "--stdin", data=b"x" * (17 * 1024 * 1024),
                status=1, code="input_too_large")
        c.error("add-image", str(pathlib.Path(directory) / "missing.png"),
                status=1, code="input_unavailable")
        malformed = pathlib.Path(directory) / "invalid.png"
        malformed.write_bytes(b"not an image\x00")
        c.error("add-image", str(malformed), status=1, code="invalid_image")
        assert c.json("stats")["items"] == 0
        assert not list((c.home / "images").glob("*")), "Invalid image leaked files"

        # Every byte survives stdin -> persisted history -> raw output unchanged.
        samples = [b"no final newline", "中文\nemoji 👩🏽‍💻 e\u0301\r\n\tend\n".encode(),
                   b"before\x00after", b"_debug-panel", b"_debug-scroll"]
        identifiers = []
        for raw in samples:
            added_text = c.json("add-text", "--stdin", data=raw)
            assert set(added_text["item"]) == {"id", "kind", "is_favorite", "is_secret", "was_pasted"}, added_text
            item = c.json("get", "--latest")
            identifier = item["id"]
            assert isinstance(identifier, str) and identifier.isdecimal(), item
            identifiers.append(identifier)
            assert c.run("get", identifier, "--raw").stdout == raw
            assert item["content"].encode() == raw, item
        literal = c.run("add-text", "--json", "--", "--literal-flag")
        assert json.loads(literal.stdout)["ok"] is True
        assert c.run("get", "--latest", "--raw").stdout == b"--literal-flag"

        # Marker-looking argument data must not dispatch the debug panel either.
        duplicate = c.json("add-text", "_debug-panel")
        assert duplicate["inserted"] is False, duplicate
        c.json("search", "_debug-scroll")
        page = c.json("list", "--page-size", "2")
        assert len(page["items"]) == 2 and page["page"] == 1, page
        assert page["page_size"] == 2 and page["has_more"] is True, page
        assert page["total"] == len(samples) + 1, page
        following = c.json("list", "2", "--page-size", "2")
        assert not ({i["id"] for i in page["items"]} & {i["id"] for i in following["items"]})

        assert c.run("stats").stdout.startswith(b"items=")
        assert c.run("list", "1").stdout.startswith(b"total=")
        assert c.run("search", "no final newline").stdout.startswith(b"total=")
        assert c.json("stats")["items"] == len(samples) + 1

        identifier = identifiers[0]
        for state in ("true", "true", "false"):
            c.json("fav", identifier, "--set", state)
            assert c.json("get", identifier)["is_favorite"] is (state == "true")
        c.json("fav", identifier, "--set", "true")
        favorites = c.json("search", "no final newline", "--favorite")
        assert [item["id"] for item in favorites["items"]] == [identifier], favorites
        c.json("delete", identifier)
        c.error("get", identifier, status=1, code="item_not_found")
        c.error("fav", identifier, "--set", "true", status=1, code="item_not_found")
        c.error("delete", identifier, status=1, code="item_not_found")

        # A deliberately failing, local fake helper proves external output is sanitized.
        # No installed jt executable or real vault is used.
        helper = pathlib.Path(directory) / "fake-jt"
        helper.write_text("#!/bin/sh\ncat >/dev/null\nprintf 'FAKE_HELPER_PRIVATE_SENTINEL' >&2\nexit 1\n")
        helper.chmod(0o700)
        c.env["JT_BIN"] = str(helper)
        failed = c.error("mark-secret", identifiers[1], "test/fixture", status=1,
                         code="secret_engine_error")
        assert b"FAKE_HELPER_PRIVATE_SENTINEL" not in failed.stderr
        assert c.json("get", identifiers[1])["is_secret"] is False
        c.env["JT_BIN"] = str(pathlib.Path(directory) / "no-jt")

        # Exercise real concurrent processes sharing the WAL database, never a clipboard.
        values = [f"parallel-contract-{i}" for i in range(8)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(lambda value: c.json("add-text", "--stdin", data=value.encode()), values))
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            duplicates = list(pool.map(
                lambda _: c.json("add-text", "--stdin", data=b"parallel duplicate"), range(8)))
        assert len({result["item"]["id"] for result in duplicates}) == 1, duplicates
        assert sum(result["inserted"] for result in duplicates) == 1, duplicates
        for value in values:
            found = c.json("search", value)
            assert any(item["content"] == value for item in found["items"]), found

        # Valid binary PNG fixture, created using only the standard library.
        def chunk(kind, body):
            return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))

        png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0))
               + chunk(b"IDAT", zlib.compress(b"\x00\xff\x00\x00\xff")) + chunk(b"IEND", b""))
        image = pathlib.Path(directory) / "图片 fixture.png"
        image.write_bytes(png)
        added = c.json("add-image", str(image))
        assert added["inserted"] is True and added["item"]["kind"] == "image", added
        assert set(added["item"]) == {"id", "kind", "is_favorite", "is_secret", "was_pasted"}, added
        c.error("get", added["item"]["id"], "--raw", status=1,
                code="format_unavailable", json_flag=False)
        saved_path = pathlib.Path(c.json("get", added["item"]["id"])["image_path"])
        assert saved_path.read_bytes() == png
        images = c.json("search", ":img")
        assert [item["id"] for item in images["items"]] == [added["item"]["id"]], images
        image_files = set((c.home / "images").iterdir())
        duplicate = c.json("add-image", str(image))
        assert duplicate["inserted"] is False, duplicate
        assert duplicate["item"]["id"] == added["item"]["id"]
        assert set((c.home / "images").iterdir()) == image_files, "Image dedupe leaked files"
        c.json("delete", added["item"]["id"])
        assert not saved_path.exists(), "Deleted image file survived"

        c.json("clear", "--yes")
        assert c.json("list")["total"] == 0
        c.error("get", "--latest", status=1, code="item_not_found")
        print(f"headless history CLI contracts passed ({c.calls} processes)")


if __name__ == "__main__":
    main()
