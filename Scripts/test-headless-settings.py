#!/usr/bin/env python3
"""macOS subprocess contracts; isolated prefs/data, no clipboard or secret access.
Usage: python3 Scripts/test-headless-settings.py [path/to/jiantieban]
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid


def main():
    if len(sys.argv) > 2:
        raise SystemExit(__doc__)
    root = Path(__file__).resolve().parent.parent
    binary = Path(sys.argv[1]).resolve() if len(sys.argv) == 2 else root / ".build/release/jiantieban"
    assert binary.is_file(), f"Build the executable first: {binary}"
    executable = str(binary)
    suite = "rs.jiantieban.test." + uuid.uuid4().hex
    with tempfile.TemporaryDirectory(prefix="jtb-settings-test-") as root:
        home = Path(root) / "must-not-be-created"
        env = {key: value for key, value in os.environ.items()
               if not key.startswith("JIANTIEBAN_")}
        env.update(JIANTIEBAN_HOME=str(home), JIANTIEBAN_PREFERENCES_SUITE=suite,
                   JT_BIN=str(Path(root) / "no-jt"))

        def invoke(*args, success=True):
            run = subprocess.run([executable, *args], env=env, capture_output=True, text=True, timeout=10)
            if success:
                assert run.returncode == 0, (args, run.returncode, run.stderr)
                payload = json.loads(run.stdout)
                assert payload["ok"] is True
                assert payload["schema_version"] == 1
                assert payload["command"] == args[0]
                return payload["result"]
            assert run.returncode == 2, (args, run.returncode, run.stderr)
            assert not run.stdout.strip(), (args, run.stdout)

        try:
            initial = invoke("config", "get")
            assert initial["preferences_domain"] == suite
            assert initial["restart_required"] is False
            assert initial["settings"] == {
                "retentionPreset": "24h", "hardLimit": 600, "maxSaveLength": 12000,
                "favoritesPermanent": True, "imagePasteAsFile": False,
                "ocrLanguages": ["zh-Hans", "zh-Hant", "en-US"],
            }
            for key, value, expected in [
                ("retentionPreset", "7d", "7d"), ("hardLimit", "100", 100),
                ("maxSaveLength", "50000", 50000), ("favoritesPermanent", "false", False),
                ("imagePasteAsFile", "true", True), ("ocrLanguages", '["en-US"]', ["en-US"]),
            ]:
                result = invoke("config", "set", key, value)
                assert result["restart_required"] is True
                assert invoke("config", "get", key)["settings"] == {key: expected}
                reset = invoke("config", "reset", key)
                assert reset["restart_required"] is True
                assert invoke("config", "get", key)["settings"] == {key: initial["settings"][key]}
            for key, value in [
                ("hardLimit", "true"), ("hardLimit", "99"), ("hardLimit", "5001"),
                ("hardLimit", "100.5"), ("hardLimit", '"100"'),
                ("maxSaveLength", "-1"), ("favoritesPermanent", "1"),
                ("imagePasteAsFile", "yes"), ("retentionPreset", "bogus"),
                ("ocrLanguages", "[]"), ("ocrLanguages", '["en-US","en-US"]'),
                ("ocrLanguages", '["unknown"]'), ("ocrLanguages", "en-US"),
                ("plainTextPaste", "false"), ("privacyMode", "false"),
                ("launchAtLogin", "true"),
            ]:
                invoke("config", "set", key, value, success=False)
            for args in [(), ("set",), ("reset",), ("get", "unknown"),
                         ("get", "hardLimit", "extra"), ("reset", "hardLimit", "extra")]:
                invoke("config", *args, success=False)
            doctor = invoke("doctor")
            assert doctor["preferences_domain"] == suite
            assert doctor["permission_prompted"] is False
            assert doctor["database_exists"] is False
            assert doctor["capture_status"] == "unknown"
            assert doctor["interactive_session_status"] == "not_checked"
            assert isinstance(doctor["accessibility_trusted"], bool)
            invoke("doctor", "extra", success=False)
            assert not home.exists(), "config/doctor must not create data storage"
        finally:
            # Only keys created above, only in this unique test-owned preference suite.
            for key in ("retentionPreset", "hardLimit", "maxSaveLength", "favoritesPermanent",
                        "imagePasteAsFile", "ocrLanguages"):
                subprocess.run([executable, "config", "reset", key], env=env,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    print("headless settings/diagnostics contracts passed")


if __name__ == "__main__":
    main()
