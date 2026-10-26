#!/usr/bin/env python3
"""CLI process/JSON smoke tests; never paste or request Accessibility permission.

Usage: python3 Scripts/test-headless-cli.py [path/to/jiantieban]
Uses isolated history/preferences. The empty-history --latest case reads the
system pasteboard for freshness comparison but never writes it or sends keys.
"""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import uuid

if len(sys.argv) > 2:
    raise SystemExit(__doc__)
root = pathlib.Path(__file__).resolve().parent.parent
binary = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) == 2 else root / ".build/release/jiantieban"
assert binary.is_file(), f"Build the executable first: {binary}"
with tempfile.TemporaryDirectory(prefix="jiantieban-cli-test-") as directory:
    env = {key: value for key, value in os.environ.items()
           if not key.startswith("JIANTIEBAN_")}
    env.update(JIANTIEBAN_HOME=directory,
               JIANTIEBAN_PREFERENCES_SUITE="rs.jiantieban.paste-tests." + uuid.uuid4().hex,
               JT_BIN=str(pathlib.Path(directory) / "no-jt"))
    for args, exit_code, code in [
        (["paste"], 2, "invalid_arguments"),
        (["paste", "_debug-panel"], 2, "invalid_arguments"),
        (["paste", "--latest"], 1, "history_empty"),
        (["paste", "--latest", "1"], 2, "invalid_arguments"),
        (["paste", "-1"], 2, "invalid_arguments"),
        (["paste", "1", "--format", "unknown"], 2, "invalid_arguments"),
        (["paste", "9223372036854775807"], 1, "item_not_found"),
    ]:
        result = subprocess.run([str(binary), *args], env=env, capture_output=True,
                                text=True, timeout=8)
        assert result.returncode == exit_code, (args, result)
        assert result.stdout == "", (args, result.stdout)
        payload = json.loads(result.stderr)
        assert payload["ok"] is False and payload["code"] == code, (args, payload)
        assert payload["clipboard_changed"] is False, (args, payload)
print("headless CLI process contracts passed")
