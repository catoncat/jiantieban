import Core
import Foundation
import PastebackPlatform

@MainActor
enum HeadlessCLICommand {
    static let version = "0.3.0"
    static let help = """
    usage: jiantieban <command> [options]
      help [command] [--json] / version [--json]
      list [page] [--page N] [--page-size N] [--json]
      search <query...> [--kind text|image] [--favorite] [--secret]
             [--page N] [--page-size N] [--json]
      get <id>|--latest [--json|--raw]       full record, or exact text bytes
      copy <id>|--latest [--format default|plain|original]
      paste <id>|--latest [--format default|plain|original]
      add-text <text...>|--stdin [--json]   -- or --literal begins literal data
      add-image <path> [--json]
      fav <id> [--set true|false] [--json]
      delete <id> [--json] / clear --yes [--json] / stats [--json]
      mark-secret <id> [name] [--json]
      config get [key] / config set <key> <value> / config reset <key>
      doctor / watch / bench [n]

    IDs are positive local history IDs, not globally durable identifiers. get/copy/config/doctor
    default to JSON; existing commands opt in with --json. paste retains its prior JSON contract.
    get --raw writes exact stored UTF-8 text/reference bytes, never image paths or secret values.
    Text history has no preserved rich formatting; explicit original text returns format_unavailable.
    --stdin reads only when explicitly requested. -- ends option parsing for literal content.
    No explicit CLI command opens a panel, activates an app, or prompts for permissions.
    Secret list/rename/resolve belong to jt: jt ls / jt mv / jt resolve / jt rm.
    Exit codes: 0 success, 1 runtime failure, 2 invalid arguments. See docs/HEADLESS-CLI.md.
    """

    static func run(_ arguments: [String]) -> Int32 {
        let command = arguments.first ?? "help"
        var json = CLIRequest.wantsJSON(arguments)
        // Preserve the released paste output/error contract without wrapping it.
        if command == "paste" && !(arguments.count == 2 && ["--help", "-h"].contains(arguments[1])) { return HeadlessPasteCommand.run(Array(arguments.dropFirst())) }
        do {
            let request = try CLIRequest.parse(arguments)
            json = request.json
            switch request.command {
            case "help":
                if json { try emit(request, ["usage": help, "commands": CLIRequest.commands.sorted()]) }
                else { print(help) }
                return 0
            case "version":
                if json { try emit(request, ["version": version]) } else { print("jiantieban \(version)") }
                return 0
            case "config":
                var value = try HeadlessSettings.run(request.positional)
                value.removeValue(forKey: "ok")
                try emit(request, value)
                return 0
            case "doctor":
                var value = HeadlessDiagnostics.snapshot()
                value.removeValue(forKey: "ok")
                try emit(request, value)
                return 0
            default: break
            }
            let (store, pipeline, secrets) = try makeEngine()
            switch request.command {
            case "list", "search":
                var query = request.command == "list" ? SearchQuery() : SearchQuery(parsing: request.positional.joined(separator: " "))
                if let kind = request.kind { query.kindFilter = kind }
                query.favoritesOnly = query.favoritesOnly || request.favorite
                query.secretsOnly = query.secretsOnly || request.secret
                let page = try store.search(query, page: request.page, pageSize: request.pageSize)
                if json {
                    try emit(request, ["items": try CLIOutput.object(page.items.map(CLIRecord.init)), "total": page.total,
                        "page": page.page, "page_size": page.pageSize,
                        "has_more": page.page <= (page.total == 0 ? 0 : (page.total - 1) / page.pageSize)])
                } else { printPage(page) }
            case "get":
                let item = try selected(request.selector, store: store)
                if request.raw {
                    guard item.kind == .text else { throw CLIError("format_unavailable", "Image records have no raw text representation.") }
                    if item.isSecret && (item.secretToken?.isEmpty ?? true) {
                        throw CLIError("content_unavailable", "The reference token is unavailable.")
                    }
                    FileHandle.standardOutput.write(Data((item.isSecret ? item.secretToken! : item.content).utf8))
                } else { try emit(request, CLIOutput.object(CLIRecord(item))) }
            case "copy":
                guard let paste = request.paste else { throw CLIError("invalid_arguments", "A record selector is required.", exitCode: 2) }
                let item = try paste.select(from: store)
                let settings = AppSettings.shared
                let content = try paste.content(for: item, defaultPlainText: settings.plainTextPaste, imageAsFile: settings.imagePasteAsFile)
                let clipboard = SystemPastebackClipboard()
                let previousCount = clipboard.changeCount
                guard clipboard.write(content) else { throw CLIError("content_unavailable", "Clipboard write failed; no paste event was sent.", clipboardChanged: clipboard.changeCount != previousCount) }
                let format: String
                switch content {
                case .text, .secretPlaintext: format = "plain"
                case .secretReference: format = "reference"
                case let .image(_, asFile): format = asFile ? "file" : "image"
                }
                try emit(request, ["id": String(item.id), "status": "copied", "format": format, "clipboard_changed": true])
            case "add-text":
                let text: String
                if request.stdin {
                    var data = Data()
                    while let chunk = try FileHandle.standardInput.read(upToCount: 65536), !chunk.isEmpty {
                        guard data.count + chunk.count <= 16 * 1024 * 1024 else {
                            throw CLIError("input_too_large", "stdin exceeds the 16 MiB input limit.")
                        }
                        data.append(chunk)
                    }
                    guard let decoded = String(data: data, encoding: .utf8) else { throw CLIError("invalid_encoding", "stdin must contain valid UTF-8.") }
                    text = decoded
                } else { text = request.positional.joined(separator: " ") }
                let (item, inserted) = try store.upsertText(text)
                if json { try emit(request, ["item": try CLIOutput.object(CLIMutationRecord(item)), "inserted": inserted,
                                            "truncated": text.count > store.config.maxSaveLength]) }
                else { print("\(inserted ? "inserted" : "deduped") id=\(item.id)") }
            case "add-image":
                guard let bytes = FileManager.default.contents(atPath: request.positional[0]) else { throw CLIError("input_unavailable", "Image input is missing or unreadable.") }
                let images = try ImageStore(directory: dataDir().appendingPathComponent("images"))
                let saved: SavedImage
                do { saved = try images.save(pngData: bytes) }
                catch { throw CLIError("invalid_image", "Image input could not be decoded or saved.") }
                let item: ClipItem
                let inserted: Bool
                do { (item, inserted) = try store.upsertImage(imagePath: saved.imagePath, thumbPath: saved.thumbPath, hash: saved.hash) }
                catch { images.removeFiles([saved.imagePath, saved.thumbPath]); throw error }
                if !inserted { images.removeFiles([saved.imagePath, saved.thumbPath]) }
                if json { try emit(request, ["item": try CLIOutput.object(CLIMutationRecord(item)), "inserted": inserted]) }
                else { print("\(inserted ? "inserted" : "deduped") id=\(item.id)") }
            case "fav":
                guard case let .id(id)? = request.selector else { throw StoreError.itemNotFound }
                let favorite: Bool
                let item: ClipItem
                if let value = request.setFavorite { item = try store.setFavorite(value, id: id); favorite = value }
                else { item = try store.toggleFavoriteItem(id: id); favorite = item.isFavorite }
                if json { try emit(request, ["item": try CLIOutput.object(CLIMutationRecord(item))]) }
                else { print("favorite=\(favorite)") }
            case "delete":
                guard case let .id(id)? = request.selector, let removed = try store.delete(id: id) else { throw StoreError.itemNotFound }
                ImageStore.removeFiles([removed.imagePath, removed.thumbPath].compactMap { $0 })
                if json { try emit(request, ["id": String(id), "deleted": true]) } else { print("deleted \(id)") }
            case "clear":
                let files = try store.clear()
                ImageStore.removeFiles(files)
                if json { try emit(request, ["cleared": true, "image_cleanup_candidates": files.count, "image_cleanup": "best_effort"]) }
                else { print("cleared, image cleanup attempted for \(files.count) paths") }
            case "stats":
                let count = try store.count()
                if json { try emit(request, ["items": count]) } else { print("items=\(count)") }
            case "mark-secret":
                guard case let .id(id)? = request.selector else { throw StoreError.itemNotFound }
                let item: ClipItem
                do { item = try secrets.markAsSecret(id: id, name: request.positional.count == 2 ? request.positional[1] : nil) }
                catch let error as StoreError { throw error }
                catch { throw CLIError("secret_engine_error", "jt could not complete the operation. No external stderr or secret value is included.") }
                if json { try emit(request, ["item": try CLIOutput.object(CLIMutationRecord(item))]) }
                else { print("marked \(item.id) token=\(item.secretToken ?? "")") }
            case "watch":
                let monitor = ClipboardMonitor(pasteboard: SystemPasteboard()) { snapshot in pipeline.handle(snapshot) }
                // CLI settings are loaded once. In privacy mode do not even read
                // clipboard snapshots; restart watch after changing that preference.
                if !AppSettings.shared.privacyMode { monitor.start() }
                print("watching clipboard (0.8s interval), Ctrl+C to stop; saved privacy settings apply")
                RunLoop.main.run()
            case "bench": try runBench(store: store, arguments: request.positional)
            default: throw CLIError("invalid_arguments", "Unsupported command.", exitCode: 2)
            }
            return 0
        } catch let error as CLIError { return fail(command, error, json: json) }
        catch let error as HeadlessPasteError { return fail(command, CLIError(error.code, error.message, exitCode: error.exitCode, clipboardChanged: command == "copy" ? error.clipboardChanged : nil), json: true) }
        catch let error as HeadlessSettingsError { return fail(command, CLIError("invalid_arguments", error.message, exitCode: 2), json: true) }
        catch let error as StoreError {
            let code: String
            switch error {
            case .itemNotFound: code = "item_not_found"
            case .notTextItem: code = "wrong_record_type"
            case .alreadySecret: code = "already_secret"
            case .notSecret: code = "not_secret"
            case .restoreConflict: code = "conflict"
            case .itemChanged: code = "conflict"
            case .invalidPagination: code = "invalid_arguments"
            }
            return fail(command, CLIError(code, error.description), json: json)
        } catch is SQLiteError { return fail(command, CLIError("storage_error", "The history database operation failed."), json: json) }
        catch { return fail(command, CLIError("operation_failed", "The requested operation failed; no external output is included."), json: json) }
    }

    private static func selected(_ selector: HeadlessPasteSelector?, store: ClipStore) throws -> ClipItem {
        let item: ClipItem?
        switch selector {
        case .id(let id): item = try store.item(id: id)
        case .latest: item = try store.latestItem()
        case nil: item = nil
        }
        guard let item else { throw StoreError.itemNotFound }
        return item
    }
    private static func emit(_ request: CLIRequest, _ result: Any) throws {
        FileHandle.standardOutput.write(try CLIOutput.success(command: request.command, result: result))
        FileHandle.standardOutput.write(Data([10]))
    }
    private static func fail(_ command: String, _ error: CLIError, json: Bool) -> Int32 {
        if json { FileHandle.standardError.write(CLIOutput.failure(command: command, code: error.code, message: error.message, clipboardChanged: error.clipboardChanged)); FileHandle.standardError.write(Data([10])) }
        else { FileHandle.standardError.write(Data("jiantieban: \(error.message)\n".utf8)) }
        return error.exitCode
    }
}
