# Headless paste — first CLI increment

`paste` is a program/script-facing command, not a shortcut API. It does not create a
panel, select a UI row, register keys, activate an application, or prompt for permission.
It posts paste events to the application that was foreground when this process began.
A caller that takes focus before launching the command changes that target; the CLI
cannot infer a formerly focused window. No `open -a` wrapper is required.

```sh
/Applications/jiantieban.app/Contents/MacOS/jiantieban paste 42
/Applications/jiantieban.app/Contents/MacOS/jiantieban paste --latest
/Applications/jiantieban.app/Contents/MacOS/jiantieban paste 42 --format plain
```

Exactly one selector is required: a positive history ID (visible in `list`), or
`--latest`, ordered by last-copy time and then ID, not favorites or panel state.
`--latest` waits up to 1.2 seconds for the running app/monitor to capture the current
clipboard. If a supported new copy does not match persisted history, it fails with
`history_not_current` rather than pasting an older record. The command never ingests
clipboard contents itself, bypasses privacy exclusions, or resurrects deleted data.
Text matching uses the app’s configured storage truncation limit; the stored text,
not discarded characters, is pasted.
Self-marked, empty, or unsupported clipboard contents do not count as a new capture.
Explicit IDs work without the app running; capturing new history still needs the app
or `watch` process.

## Format and settings

The CLI and app use the `rs.jiantieban` preferences domain and the same history directory
(`JIANTIEBAN_HOME` overrides data only, not preferences).

| Record | `default` (omitted) | `plain` | `original` |
| --- | --- | --- | --- |
| Text | Stored plain text, same as panel | Stored plain text only | `format_unavailable` |
| Image | App's image/file preference | `format_unavailable` | Image data |
| Reference clip | Reference token | Reference token | Reference token |

**Existing text history retains no RTF/HTML.** Although the app has a `plainTextPaste`
preference, its existing panel always writes stored plain text. Default preserves that
behavior, including its plain fallback when the preference is disabled. Explicit
`original` fails honestly rather than claiming formatting was restored. This increment
does not add rich-history storage or resolve secret references. Secret management stays
in `jt`; formatting is not permission to expose secret values.

## Process contract

Success: one JSON object on stdout, exit 0. Failure: one JSON object on stderr, nonzero
exit; no clipboard text is included in either output. Exit 2 means invalid arguments;
exit 1 means runtime failure. Other existing CLI commands retain their previous output.

```json
{"ok":true,"status":"event_sent","id":42,"format":"plain","retained":true,"clipboard_changed":true}
```

`event_sent` means the key events were posted, **not** that the target accepted them.
`retained:false` means posting succeeded but marking the record as pasted failed; do not
retry the paste just to fix retention. Successful posting follows panel retention rules.

Errors have `ok:false`, stable `code`, human `message`, and `clipboard_changed`. Codes
include `invalid_arguments`, `item_not_found`, `history_empty`, `history_not_current`,
`format_unavailable`, `content_unavailable`, `accessibility_required`, `target_changed`,
`clipboard_changed`, `modifiers_timeout`, `modifiers_changed`, `event_unavailable`,
`paste_busy`, `lock_unavailable`, and `storage_error`.
`clipboard_changed:true` means failure occurred after a write, or pasteboard ownership
changed during a failed write attempt (possibly due to another app). It does not prove
that this process caused the change or that a paste event was sent. There is no
silent copy-only success or automatic retry.

The process must already have macOS Accessibility permission; the command neither
requests nor grants it. macOS may attribute permission to the invoking program. It
waits at most 2 seconds for held command/shift/control/option keys to be released,
checks the foreground application and clipboard ownership again immediately before
posting, and exits only after synchronous dispatch. A changed target or clipboard
cancels the request. No API can make the final OS focus/event-delivery boundary atomic.
Concurrent paste requests sharing a history directory fail fast with `paste_busy`;
SQLite uses a bounded busy timeout for ordinary app/CLI overlap.

## Verification / release gate

`make test` includes parser, selection, format policy and injected lifecycle failure
cases. `make bundle && python3 Scripts/test-headless-cli.py` verifies actual process
exit and JSON failures without posting events or changing Accessibility grants.
The macOS workflow runs both; it does not sign or claim interactive acceptance.

Before publishing a release, complete the headless section of [ACCEPTANCE.md](ACCEPTANCE.md)
on an authorized Mac, plus the existing [distribution gates](DISTRIBUTION.md).
