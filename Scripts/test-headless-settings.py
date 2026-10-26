#!/usr/bin/env python3
"""macOS subprocess contracts; isolated prefs/data, no clipboard or secret access.
Usage: python3 Scripts/test-headless-settings.py [path/to/jiantieban]
"""
import json
import os
from pathlib import Path
import plistlib
import shutil
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

        # Exercise the actual bundle-identity branch without writing rs.jiantieban.
        # An override unrelated to Bundle.main.bundleIdentifier hides this regression.
        bundle_suite = "rs.jiantieban.bundle-test." + uuid.uuid4().hex
        app = Path(root) / "SettingsTest.app"
        contents = app / "Contents"
        bundled_binary = contents / "MacOS" / "jiantieban"
        bundled_binary.parent.mkdir(parents=True)
        shutil.copy2(binary, bundled_binary)
        with (contents / "Info.plist").open("wb") as info:
            plistlib.dump({"CFBundleIdentifier": bundle_suite,
                          "CFBundleExecutable": "jiantieban",
                          "CFBundlePackageType": "APPL"}, info)
        # Only this temporary fixture is ad-hoc signed; no identity/keychain changes.
        subprocess.run(["codesign", "--force", "--sign", "-", str(app)],
                       check=True, capture_output=True, text=True, timeout=10)
        executable = str(bundled_binary)
        bundle_home = Path(root) / "bundle-data"
        env.update(JIANTIEBAN_HOME=str(bundle_home), JIANTIEBAN_PREFERENCES_SUITE=bundle_suite)
        try:
            initial = invoke("config", "get", "maxSaveLength")
            assert initial["preferences_domain"] == bundle_suite
            assert initial["settings"] == {"maxSaveLength": 12000}
            invoke("config", "set", "maxSaveLength", "1000")
            assert invoke("config", "get", "maxSaveLength")["settings"] == {"maxSaveLength": 1000}
            assert not bundle_home.exists(), "Bundled config commands created storage"
            # add-text initializes the same AppSettings.shared used by GUI startup.
            added = invoke("add-text", "x" * 1001, "--json")
            assert added["truncated"] is True
            assert invoke("get", added["item"]["id"])["content"] == "x" * 1000
            invoke("config", "reset", "maxSaveLength")
            assert invoke("config", "get", "maxSaveLength")["settings"] == {"maxSaveLength": 12000}
        finally:
            subprocess.run([executable, "config", "reset", "maxSaveLength"], env=env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    print("headless settings/diagnostics contracts passed")


if __name__ == "__main__":
    main()
