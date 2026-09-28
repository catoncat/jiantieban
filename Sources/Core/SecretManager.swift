import Foundation

/// 负责把 App 的密钥动作转发给独立 jt 引擎；本地库只保存引用、名称和遮罩。
@MainActor
public final class SecretManager {
    private let store: ClipStore
    private let jt = JTSecretClient()
    /// `<vault>/vault.json`：从 `jt status --json` 得知（jt 的 vault 位置跟环境变量走，App 不自己猜）
    private var vaultFile: URL?
    private var vaultProbed = false
    /// 上次读到的 jt 列表，和读之前 vault 文件的修改时间：vault 没变就不用重读
    private var listing: (records: [SecretRecord], stamp: Date?)?

    public init(store: ClipStore) {
        self.store = store
    }

    @discardableResult
    public func markAsSecret(id: Int64, name: String? = nil) throws -> ClipItem {
        guard let item = try store.item(id: id) else { throw StoreError.itemNotFound }
        guard item.kind == .text else { throw StoreError.notTextItem }
        if item.isSecret { return item }

        let secretName = name ?? SecretNaming.defaultName(forItemID: id)
        let reference = try jt.add(name: secretName, value: item.content)
        return try store.markAsSecret(
            id: id,
            encryptedContent: reference,
            token: reference,
            type: SecretDetector.detect(item.content)?.rawValue,
            name: secretName,
            maskedPreview: SecretMask.fixed(item.content)
        )
    }

    /// 撤销刚才的标记：真值写回原记录，删掉刚建的 jt 记录。只给面板的一次性撤销用——
    /// 没有面向用户的"取消密钥"（ADR-0001），标错了靠这个兜底。
    @discardableResult
    public func undoMark(id: Int64) throws -> UnmarkResult {
        guard let item = try store.item(id: id) else { throw StoreError.itemNotFound }
        guard item.isSecret else { return UnmarkResult(item: item, mergedDuplicateID: nil) }
        guard let reference = item.secretToken else { throw JTClientError.missingReference }
        // 顺序：取回真值 → 写库 → 库成功后才从 vault 删。任何一步失败，密钥都还完整可用。
        let plaintext = try jt.resolve(reference: reference)
        let result = try store.unmarkSecret(id: id, plaintextContent: plaintext)
        do {
            try jt.remove(reference: reference)
        } catch {
            // 明文已回到本地历史，vault 里多留一份不增加暴露面；只记日志，不让已完成的撤销变成失败
            NSLog("[jtb] undo mark: vault cleanup failed for \(reference): \(error)")
        }
        return result
    }

    /// 真值：密钥从 jt 取，普通记录就是原文。
    public func resolveValue(for item: ClipItem) throws -> String {
        guard item.isSecret else { return item.content }
        guard let reference = item.secretToken else { throw JTClientError.missingReference }
        return try jt.resolve(reference: reference)
    }

    public func resolve(token: String) throws -> String {
        try jt.resolve(reference: token)
    }

    public func secretReference(for item: ClipItem) -> String? {
        item.isSecret ? item.secretToken : nil
    }

    @discardableResult
    public func pasteAsSecret(id: Int64, name: String? = nil) throws -> String {
        let item = try markAsSecret(id: id, name: name)
        guard let token = item.secretToken else { throw StoreError.notSecret }
        return token
    }

    @discardableResult
    public func setName(id: Int64, name: String) throws -> ClipItem {
        guard let item = try store.item(id: id) else { throw StoreError.itemNotFound }
        if let reference = item.secretToken {
            try jt.rename(reference: reference, name: name)
        }
        return try store.setSecretName(id: id, name: name)
    }

    // MARK: - jt 记录（密钥视图）

    /// jt 里的全部密钥记录，按命名空间分组排好。顺手刷新引用记录的展示缓存。
    public func listRecords() throws -> [SecretRecord] {
        let stamp = vaultFile.map(Self.modificationDate)
        let records = try jt.list()
        remember(records, stamp: stamp)
        if vaultFile == nil { vaultProbed = false } // jt 又能用了：下次刷新再问 vault 在哪
        return SecretRecords.sorted(records)
    }

    /// vault 文件变过（终端里 jt add / mv / rm、jt sync 拉了别处的改动）就重读 jt，刷新引用记录的名称和"已删除"。
    /// 没变只是一次 stat；本地没有引用记录时什么都不做。返回 true 表示本地记录变了，列表要重读。
    /// 面板打开之后再调（不拖慢打开）；jt 读失败只记日志，保留旧缓存。
    public func refreshReferencesIfVaultChanged() -> Bool {
        guard (try? store.hasSecretReferences()) == true, let file = knownVaultFile() else { return false }
        let stamp = Self.modificationDate(file)
        if let listing, listing.stamp == stamp { return false }
        do {
            return remember(try jt.list(), stamp: stamp)
        } catch {
            NSLog("[jtb] refreshing secret references failed: \(error)")
            return false
        }
    }

    /// 最近用过的命名空间，给命名推荐用（ADR-0001 / 05）。vault 没变就用上次读到的列表，变了才重读 jt；
    /// 读不到返回 nil——推荐里不带命名空间，不影响标记本身。
    public func recentNamespace() -> String? {
        let stamp = knownVaultFile().map(Self.modificationDate)
        if let listing, let stamp, listing.stamp == stamp {
            return SecretNaming.recentNamespace(in: listing.records)
        }
        do {
            let records = try jt.list()
            remember(records, stamp: stamp)
            return SecretNaming.recentNamespace(in: records)
        } catch {
            NSLog("[jtb] reading jt for a name suggestion failed: \(error)")
            return nil
        }
    }

    /// vault 的同步状态（`jt status --json`）。要跑 git（约半秒），界面在后台线程调，别卡住主线程。
    /// 只读本地 git 状态；同步（`jt sync`）App 从来不做，留给用户在终端跑。
    public nonisolated func fetchVaultStatus() throws -> JTVaultStatus {
        try jt.status()
    }

    /// 改 jt 里的名字，返回改名后的记录；持有这个引用的剪贴板记录跟着改。
    public func renameRecord(_ record: SecretRecord, to name: String) throws -> SecretRecord {
        try jt.rename(reference: record.reference, name: name)
        do { try store.renameSecretReferences(token: record.reference, name: name) }
        catch { NSLog("[jtb] updating renamed references failed: \(error)") }
        var renamed = record
        renamed.name = name
        renamed.updatedAt = Date()
        return renamed
    }

    /// 从 jt 删除：已经贴到别处的引用从此解析不了，调用方负责先确认。
    public func deleteRecord(_ record: SecretRecord) throws {
        try jt.remove(reference: record.reference)
        do { try store.markSecretReferencesMissing(token: record.reference) }
        catch { NSLog("[jtb] marking deleted references failed: \(error)") }
    }

    /// vault 文件在哪：问一次 `jt status`；jt 没装时别每次打开面板都起进程（进密钥视图读列表成功后会再问）。
    private func knownVaultFile() -> URL? {
        if vaultFile == nil, !vaultProbed {
            vaultProbed = true
            do {
                vaultFile = URL(fileURLWithPath: try jt.status().vault).appendingPathComponent("vault.json")
            } catch {
                NSLog("[jtb] jt status failed: \(error)")
            }
        }
        return vaultFile
    }

    /// 记下读到的列表，顺手刷新引用记录的展示缓存；返回本地记录有没有变。
    /// stamp：读列表之前 vault 文件的修改时间（读的过程中又改了，下次还会再读）；外层 nil = 还不知道 vault 在哪，不缓存。
    @discardableResult
    private func remember(_ records: [SecretRecord], stamp: Date??) -> Bool {
        do {
            let changed = try store.syncSecretReferences(with: records)
            if let stamp { listing = (records, stamp) }
            return changed > 0
        } catch {
            NSLog("[jtb] syncing secret references failed: \(error)")
            return false
        }
    }

    private static func modificationDate(_ file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }
}

/// `jt status --json`：vault 目录、是否 git 仓库、有没有没提交 / 没推送的改动。
public struct JTVaultStatus: Decodable, Equatable, Sendable {
    public let vault: String
    public let git: Bool
    public let dirty: Bool
    /// 本地领先远端的提交数；没有上游时为 nil
    public let ahead: Int?

    public init(vault: String, git: Bool, dirty: Bool, ahead: Int?) {
        self.vault = vault
        self.git = git
        self.dirty = dirty
        self.ahead = ahead
    }

    /// 有改动还没同步到别的机器（不是 git 仓库的 vault 没有"同步"这回事）。
    public var hasUnsyncedChanges: Bool { git && (dirty || (ahead ?? 0) > 0) }
}

/// 同步调用 jt CLI，真值只通过 stdin/stdout 在当前进程和子进程之间流动。没有可变状态，哪个线程都能调。
private final class JTSecretClient: Sendable {
    private let binary: String

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        binary = ProcessInfo.processInfo.environment["JT_BIN"] ?? "\(home)/.local/bin/jt"
    }

    func add(name: String, value: String) throws -> String {
        let output = try run(["add", name], stdin: Data(value.utf8))
        guard let reference = output.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("jt://secret/") || $0.contains(" jt://secret/") })?.split(separator: " ").last,
              reference.hasPrefix("jt://secret/") else {
            throw JTClientError.invalidOutput
        }
        return String(reference)
    }

    func resolve(reference: String) throws -> String {
        try run(["resolve", reference]).trimmingCharacters(in: .newlines)
    }

    func remove(reference: String) throws {
        _ = try run(["rm", reference])
    }

    func rename(reference: String, name: String) throws {
        _ = try run(["mv", reference, name])
    }

    func status() throws -> JTVaultStatus {
        let output = try run(["status", "--json"])
        do {
            return try JSONDecoder().decode(JTVaultStatus.self, from: Data(output.utf8))
        } catch {
            throw JTClientError.invalidOutput
        }
    }

    func list() throws -> [SecretRecord] {
        let output = try run(["ls", "--json"])
        do {
            return try SecretRecords.decode(Data(output.utf8))
        } catch {
            throw JTClientError.invalidOutput
        }
    }

    private func run(_ arguments: [String], stdin: Data? = nil) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let input = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = input
        if FileManager.default.isExecutableFile(atPath: binary) {
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [binary] + arguments
        }
        // 等退出用信号量，不用 waitUntilExit：后者在主线程上转嵌套 RunLoop，等待中会插进去跑别的界面代码
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        // 先读完输出再等退出：输出超过管道缓冲（64KB）时，子进程写不出去就永远不退出。
        // stderr 在另一条线程读，两路谁先写满都不会互相卡住。
        let errorBox = DataBox()
        let errorDone = DispatchGroup()
        errorDone.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errorBox.data = stderr.fileHandleForReading.readDataToEndOfFile()
            errorDone.leave()
        }
        if let stdin { try input.fileHandleForWriting.write(contentsOf: stdin) }
        try input.fileHandleForWriting.close()
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        errorDone.wait()
        exited.wait()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let error = String(data: errorBox.data, encoding: .utf8) ?? ""
        // 走 /usr/bin/env 兜底时 127 = 找不到 jt
        if process.terminationStatus == 127, process.executableURL?.path == "/usr/bin/env" {
            throw JTClientError.notInstalled(binary)
        }
        guard process.terminationStatus == 0 else {
            throw JTClientError.commandFailed(error.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }
}

/// 后台线程读完 stderr 后交回；DispatchGroup.wait() 之后才读，不会并发访问。
private final class DataBox: @unchecked Sendable {
    var data = Data()
}

private enum JTClientError: Error, LocalizedError {
    case invalidOutput
    case missingReference
    case notInstalled(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidOutput: return "jt returned unexpected output"
        case .notInstalled(let binary): return "没找到 jt（\(binary)）"
        case .missingReference: return "secret has no jt reference"
        case .commandFailed(let error): return error.isEmpty ? "jt command failed" : "jt command failed: \(error)"
        }
    }
}
