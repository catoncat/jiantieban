#!/usr/bin/env python3
"""CLI process/JSON smoke tests; never paste or request Accessibility permission."""
import json
import os
import pathlib
import subprocess
import tempfile

binary = pathlib.Path(".build/release/jiantieban").resolve()
with tempfile.TemporaryDirectory(prefix="jiantieban-cli-test-") as directory:
    env = {**os.environ, "JIANTIEBAN_HOME": directory}
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
