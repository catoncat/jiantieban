import Core
import Foundation

// 多个测试文件共用的替身。只放被两处以上用到的。

@MainActor
final class FakePermission: PastebackPermissionChecking {
    var isTrusted: Bool
    init(_ isTrusted: Bool) { self.isTrusted = isTrusted }
}

@MainActor
final class RecordingClipboard: PastebackClipboardWriting {
    var contents: [PastebackContent] = []
    var changeCount = 0
    func write(_ content: PastebackContent) -> Bool {
        contents.append(content)
        changeCount += 1
        return true
    }
}

@MainActor
final class CountingSender: PastebackCommandSending {
    var sendCount = 0
    func sendCommandV() { sendCount += 1 }
}

@MainActor
final class ManualScheduler: PastebackScheduling {
    var scheduleCount = 0
    private var action: (@MainActor @Sendable () -> Void)?
    func schedule(_ action: @escaping @MainActor @Sendable () -> Void) {
        scheduleCount += 1
        self.action = action
    }
    func run() { action?() }
}

/// 假 jt：shell 脚本 + 临时 vault，命令与真 jt 一致（add / resolve / rm / mv / ls --json / status --json），不碰真实密钥库。
/// 每条记录一个目录 `r<n>/{value,name,preview,created,updated}`；名称唯一，mv 到已有名称报错（同真 jt）。
/// 收到的命令逐行记在 `.calls`（只记参数，真值走 stdin 不进日志），测试据此断言"没有调用 jt"与"从不 sync"。
/// 每次改动 touch 一下 `vault.json`（真 jt 的 vault 文件），App 靠它的修改时间判断要不要重读。
@MainActor
final class FakeJT {
    let vault: URL

    private init(vault: URL) { self.vault = vault }

    /// 假 jt + 用它的 SecretManager。JT_BIN 只在 SecretManager 初始化时读，建完即还原。
    static func make(store: ClipStore) throws -> (SecretManager, FakeJT) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jtb-fakejt-\(UUID().uuidString)")
        let vault = dir.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let binary = dir.appendingPathComponent("jt")
        try script(vault: vault.path).write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        setenv("JT_BIN", binary.path, 1)
        defer { unsetenv("JT_BIN") }
        return (SecretManager(store: store), FakeJT(vault: vault))
    }

    static func makeSecretManager(store: ClipStore) throws -> SecretManager {
        try make(store: store).0
    }

    /// 收到过的命令行（不含 stdin），按顺序。
    var calls: [String] {
        let text = (try? String(contentsOf: vault.appendingPathComponent(".calls"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    /// 收到过的子命令名（add / resolve / ls …）。
    var commands: [String] { calls.map { String($0.split(separator: " ").first ?? "") } }

    func resetCalls() {
        try? FileManager.default.removeItem(at: vault.appendingPathComponent(".calls"))
    }

    /// 之后这个子命令一律失败，stderr 输出 message；nil 恢复正常。
    func failing(_ command: String, _ message: String? = "boom") {
        let file = vault.appendingPathComponent(".fail-\(command)")
        if let message {
            try? message.write(to: file, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// 直接写进假 vault：模拟终端 `jt add` 或从别处导入的记录。不记调用。
    /// updatedAt 为 nil 模拟没有时间戳的旧条目。返回引用。
    @discardableResult
    func seed(name: String, value: String = "seed-value", preview: String = "se****ue", updatedAt: String? = "2026-01-01T00:00:00Z") throws -> String {
        let counter = vault.appendingPathComponent(".n")
        let n = (Int((try? String(contentsOf: counter, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0) + 1
        try "\(n)".write(to: counter, atomically: true, encoding: .utf8)
        let record = vault.appendingPathComponent("r\(n)")
        try FileManager.default.createDirectory(at: record, withIntermediateDirectories: false)
        var files = ["value": value, "name": name, "preview": preview]
        if let updatedAt {
            files["created"] = updatedAt
            files["updated"] = updatedAt
        }
        for (file, text) in files {
            try text.write(to: record.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        touchVault()
        return "jt://secret/r\(n)"
    }

    /// 模拟在终端里 `jt mv`：不记调用。
    func renameOutside(_ reference: String, to name: String) throws {
        try name.write(to: recordDir(reference).appendingPathComponent("name"), atomically: true, encoding: .utf8)
        touchVault()
    }

    /// 模拟在终端里 `jt rm`：不记调用。
    func removeOutside(_ reference: String) throws {
        try FileManager.default.removeItem(at: recordDir(reference))
        touchVault()
    }

    /// vault 文件变了（修改时间前进）。
    func touchVault() {
        let file = vault.appendingPathComponent("vault.json")
        let stamp = Date()
        try? "\(stamp.timeIntervalSince1970)".write(to: file, atomically: false, encoding: .utf8)
        try? FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
    }

    private func recordDir(_ reference: String) -> URL {
        vault.appendingPathComponent(reference.replacingOccurrences(of: "jt://secret/", with: ""))
    }

    /// `jt status --json` 的输出；nil = 默认（不是 git 仓库）。
    func setStatus(_ json: String?) {
        let file = vault.appendingPathComponent(".status")
        if let json {
            try? json.write(to: file, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func name(of reference: String) -> String? {
        read(reference, "name")
    }

    func value(of reference: String) -> String? {
        read(reference, "value")
    }

    func preview(of reference: String) -> String? {
        read(reference, "preview")
    }

    private func read(_ reference: String, _ file: String) -> String? {
        try? String(contentsOf: recordDir(reference).appendingPathComponent(file), encoding: .utf8)
    }

    private static func script(vault: String) -> String {
        """
        #!/bin/bash
        set -e
        export LC_ALL=C
        dir="\(vault)"
        printf '%s\\n' "$*" >> "$dir/.calls"
        if [ -f "$dir/.fail-$1" ]; then cat "$dir/.fail-$1" >&2; exit 1; fi
        tick() { c=$(( $(cat "$dir/.clock" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$dir/.clock"; printf '2026-09-01T00:%02d:%02dZ' $((c/60)) $((c%60)); }
        records() { for r in "$dir"/r*; do [ -d "$r" ] && echo "$r"; done; return 0; }
        find_id() {
          key="${1#jt://secret/}"
          if [ -d "$dir/$key" ]; then echo "$key"; return; fi
          for r in $(records); do [ "$(cat "$r/name")" = "$1" ] && { basename "$r"; return; }; done
          echo "secret not found" >&2; exit 1
        }
        name_taken() { for r in $(records); do [ "$(cat "$r/name")" = "$1" ] && return 0; done; return 1; }
        changed() { date +%s.%N > "$dir/vault.json"; }
        esc() { sed 's/\\\\/\\\\\\\\/g; s/"/\\\\"/g'; }
        ts() { if [ -f "$1" ]; then printf '"%s"' "$(cat "$1")"; else printf null; fi; }
        case "$1" in
          add) value="$(cat)"
               if name_taken "$2"; then echo "name already exists: $2" >&2; exit 1; fi
               n=$(( $(cat "$dir/.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$dir/.n"
               r="$dir/r$n"; mkdir "$r"; t=$(tick)
               printf '%s' "$value" > "$r/value"; printf '%s' "$2" > "$r/name"; printf '%s' "${value:0:2}****" > "$r/preview"
               printf '%s' "$t" > "$r/created"; printf '%s' "$t" > "$r/updated"; changed
               echo "$2 jt://secret/r$n";;
          resolve) id=$(find_id "$2"); cat "$dir/$id/value"; echo;;
          rm) id=$(find_id "$2"); rm -rf "${dir:?}/$id"; changed; echo "removed jt://secret/$id";;
          mv) id=$(find_id "$2")
              if name_taken "$3"; then echo "name already exists: $3" >&2; exit 1; fi
              printf '%s' "$3" > "$dir/$id/name"; tick > "$dir/$id/updated"; changed; echo "renamed $3 jt://secret/$id";;
          ls) [ "$2" = "--json" ] && [ -z "$3" ] || { echo "fake jt: only ls --json" >&2; exit 2; }
              echo "["; first=1
              for r in $(records); do printf '%s\\t%s\\n' "$(cat "$r/name")" "$(basename "$r")"; done | sort | while IFS=$'\\t' read -r name id; do
                r="$dir/$id"; [ "$first" = 1 ] || echo ","; first=0
                printf '{"id":"%s","ref":"jt://secret/%s","name":"%s","preview":"%s","created_at":%s,"updated_at":%s}' \\
                  "$id" "$id" "$(printf '%s' "$name" | esc)" "$(esc < "$r/preview")" "$(ts "$r/created")" "$(ts "$r/updated")"
              done
              echo; echo "]";;
          status) [ "$2" = "--json" ] || { echo "fake jt: only status --json" >&2; exit 2; }
                  cat "$dir/.status" 2>/dev/null || echo '{"vault":"'"$dir"'","key":"'"$dir"'/key","git":false,"dirty":false,"ahead":null}';;
          *) echo "unknown command: $1" >&2; exit 2;;
        esac
        """
    }
}

func unwrap<T>(_ value: T?, _ message: @autoclosure () -> String = "unexpected nil") throws -> T {
    guard let value else { throw TestFailure(message()) }
    return value
}
