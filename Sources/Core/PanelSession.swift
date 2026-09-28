import Foundation

/// ⌘R 挂在标题下面的正文：图片大图，或密钥明文 + 引用。
public enum ExpandedBody: Equatable, Sendable {
    case text(String)
    case image(path: String)
}

/// 一行怎么展开。
public enum RowUnfold: Equatable, Sendable {
    /// 选中停下后：标题原地往下展开，最多这么多行（1 行放得下的不变高）
    case lines(Int)
    /// ⌘R：标题原地展开全部，界面按列表可见高度封顶
    case all
    /// ⌘R：密钥明文 + 引用 / 图片大图，挂在标题下面
    case body(ExpandedBody)
}

/// 列表里一行是谁。剪贴板视图里是剪贴板记录；密钥视图里是 jt 的密钥记录——两种 id 不混用。
public enum RowID: Hashable, Sendable {
    case clip(Int64)
    case secret(String)
}

/// 列表的一行：剪贴板记录（含引用记录），或 jt 里的一条密钥记录（只在密钥视图出现）。
public enum PanelRow: Equatable, Sendable {
    case clip(ClipItem)
    case secret(SecretRecord)

    public var id: RowID {
        switch self {
        case .clip(let item): return .clip(item.id)
        case .secret(let record): return .secret(record.id)
        }
    }

    public var clip: ClipItem? {
        if case .clip(let item) = self { return item }
        return nil
    }

    public var record: SecretRecord? {
        if case .secret(let record) = self { return record }
        return nil
    }

    /// 引用记录或 jt 记录：贴出去默认是引用，能改名、能临时查看明文
    public var isSecret: Bool {
        switch self {
        case .clip(let item): return item.isSecret
        case .secret: return true
        }
    }
}

/// 用户对一行下的命令。键盘、右键菜单、双击、⌘1-9 都翻译成它，由 PanelSession 统一执行。按什么键见 Keymap。
public enum PanelCommand: Equatable, Sendable {
    case paste           // 贴回 / 双击 / ⌘1-9：密钥行贴引用，其余贴原文
    case pasteAsSecret   // 明文加密后贴引用；密钥行贴引用
    case pastePlaintext  // 密钥行显式贴明文；其余同贴回
    case markSecret      // 标记为密钥（随后进入改名），可撤销（undo）
    case rename
    case toggleExpand
    case toggleFavorite
    case openInEditor
    case openSource      // 回到复制时的浏览器页面
    case delete          // 剪贴板记录：立即删除，可撤销（undo）；jt 记录：再按一次确认后从 jt 删除，不可撤销
}

/// 命令执行后要界面做的事。列表怎么刷新不在这里：界面比对 PanelSession 的状态自己刷。
public enum PanelEffect: Equatable {
    case hide
    case toast(String)
    case beep
    /// suggestion：命名推荐（光标停在它后面）；已有名字时为 nil，输入框显示原名并全选。
    case beginRename(row: RowID, suggestion: String? = nil)
    case openInEditor(ClipItem)
    case openSource(BrowserSource)
    /// 贴回发现没有辅助功能权限：界面刷新模式提示
    case pastebackModeChanged
}

/// 面板的状态与规则：查询、选中、展开、命令执行。不碰 AppKit——界面只负责画出来、把事件翻译成这里的调用。
///
/// 两种视图：剪贴板视图（全部 / 文本 / 图片 / 收藏）列 `items`；密钥视图列 jt 的全部密钥记录 `secretRecords`
/// （ADR-0001）。同一时刻只有一个非空，界面画 `rows`。只有密钥视图和密钥动作调用 jt，剪贴板视图的路径不碰它。
///
/// 不变量：`selectedIndex` 在 `rows` 非空时总是有效行；展开的行总是选中行，选中离开即收起；
/// 改动一条记录后原地替换那一行，不重跑搜索（内容变成遮罩后可能不再匹配关键词，重跑会让它从结果里消失）。
///
/// 展开分两层：选中"停下"后普通文本自动展开 N 行（`settle()`，何时算停下由界面计时）；⌘R 是上面一层
/// （普通文本展开全部，密钥 / 图片挂正文），再按一次回到停下时的样子。选中换到别的条目，两层都收起。
@MainActor
public final class PanelSession {
    public struct Expanded: Equatable {
        public let row: RowID
        public let unfold: RowUnfold

        public init(row: RowID, unfold: RowUnfold) {
            self.row = row
            self.unfold = unfold
        }
    }

    /// 剪贴板视图的行；密钥视图下为空
    public private(set) var items: [ClipItem] = []
    /// 密钥视图的行：jt 记录按命名空间分组排好、按关键词筛过；剪贴板视图下为空
    public private(set) var secretRecords: [SecretRecord] = []
    /// 密钥视图读不到 jt（没装、主密钥缺失、命令失败）时的原因；界面显示它而不是"没有密钥"
    public private(set) var secretListError: String?
    /// 密钥视图顶部的一行提示：vault 有没提交 / 没推送的改动时提醒去终端 `jt sync`（App 自己从不 sync）。其余时候 nil
    public private(set) var vaultNotice: String?
    public private(set) var query = SearchQuery()
    public private(set) var selectedIndex = 0
    /// ⌘R 那一层
    public private(set) var expanded: Expanded?
    /// 键位表：键盘分派、提示条、右键菜单都读它。
    /// 面板每次打开时从设置重新读（设置页开着时面板是收起的）
    public var keymap: Keymap

    /// 还能撤销的最近一次动作。只撤销最近一次：再删 / 再标记一条、打开、改搜索词、切筛选、关闭面板都让它失效。
    private enum PendingUndo {
        /// 刚删掉的那条：库里已删，图片文件留到撤销失效时才删。
        case deletion(item: ClipItem, index: Int)
        /// 刚手动标记的那条：真值已交给 jt，撤销时取回写回。
        case mark(itemId: Int64)
    }
    private var pendingUndo: PendingUndo?
    /// 密钥视图里按过一次删除、等再按一次确认的那条 jt 记录。换行、别的命令、改搜索、关面板都取消。
    private var armedRecordDeletion: String?
    /// 这次进入密钥视图时从 jt 读到的全部记录：改关键词只在本地筛，不再调 jt。离开视图就丢掉。
    private var secretSnapshot: [SecretRecord]?
    /// 该（重新）问一次 jt status 了：进密钥视图、在里面改名 / 删除之后。界面取走请求、在后台问完交回
    private var vaultStatusWanted = false
    /// 最近一次交出去的请求编号：比它旧的回答作废（问的时候之后又改过）
    private var vaultStatusRequest = 0

    /// 选中停下的那一条。选中一换条目就清掉（见 dropStaleSettle）：翻走再翻回来也要重新等停下。
    private var settledRow: RowID?

    private let store: ClipStore
    private let secrets: SecretManager
    private let pasteback: PastebackCoordinator
    private let imagePasteAsFile: @MainActor () -> Bool
    /// 停下后自动展开的行数，0 = 不自动展开
    private let autoUnfoldLines: @MainActor () -> Int
    /// 全量加载：历史有保留上限（默认 600），一次拿完，滚动不翻页
    private static let pageSize = 100_000

    public init(
        store: ClipStore,
        secrets: SecretManager,
        pasteback: PastebackCoordinator,
        imagePasteAsFile: @escaping @MainActor () -> Bool = { false },
        keymap: Keymap = .defaults,
        autoUnfoldLines: @escaping @MainActor () -> Int = { 4 }
    ) {
        self.keymap = keymap
        self.store = store
        self.secrets = secrets
        self.pasteback = pasteback
        self.imagePasteAsFile = imagePasteAsFile
        self.autoUnfoldLines = autoUnfoldLines
    }

    /// 此刻是密钥视图（列 jt 记录）
    public var isSecretView: Bool { query.secretsOnly }

    /// 界面要画的行
    public var rows: [PanelRow] { isSecretView ? secretRecords.map(PanelRow.secret) : items.map(PanelRow.clip) }
    public var rowCount: Int { isSecretView ? secretRecords.count : items.count }

    public var selectedRow: PanelRow? { row(at: selectedIndex) }
    public var selectedItem: ClipItem? { items.indices.contains(selectedIndex) ? items[selectedIndex] : nil }
    public var selectedRecord: SecretRecord? { secretRecords.indices.contains(selectedIndex) ? secretRecords[selectedIndex] : nil }

    public func row(at index: Int) -> PanelRow? {
        if isSecretView { return secretRecords.indices.contains(index) ? .secret(secretRecords[index]) : nil }
        return items.indices.contains(index) ? .clip(items[index]) : nil
    }

    public func index(of id: RowID) -> Int? {
        switch id {
        case .clip(let itemId): return isSecretView ? nil : items.firstIndex { $0.id == itemId }
        case .secret(let recordId): return isSecretView ? secretRecords.firstIndex { $0.id == recordId } : nil
        }
    }

    /// 密钥视图里第 index 行上方的组标题（每组第一行才有）；剪贴板视图没有分组。
    public func groupHeader(at index: Int) -> String? {
        isSecretView ? SecretRecords.groupHeader(at: index, in: secretRecords) : nil
    }

    /// 选中行已停下（界面不用再等计时器）
    public var isSettled: Bool { settledRow != nil && settledRow == selectedRow?.id }

    /// 此刻要画出来的展开：⌘R 那层优先；否则停下的普通文本自动展开 N 行。密钥、图片不自动展开。
    public var unfolded: Expanded? {
        if let expanded { return expanded }
        guard isSettled, let item = selectedItem, item.kind == .text, !item.isSecret else { return nil }
        let lines = autoUnfoldLines()
        return lines > 0 ? Expanded(row: .clip(item.id), unfold: .lines(lines)) : nil
    }

    public var mode: PastebackIntent { pasteback.mode }

    /// 按住 ⌘ 时当前行的快捷键提示
    public var hints: [KeyHint] {
        guard let row = selectedRow else { return [] }
        return ItemActions.hints(for: row, expanded: expanded?.row == row.id, copyOnly: mode == .copyOnly, keymap: keymap)
    }

    // MARK: - 列表

    /// 打开面板：清空搜索，选中第一条，收起展开；第一条也要等停下才展开。
    public func open() {
        commitPendingUndo()
        query = SearchQuery()
        expanded = nil
        settledRow = nil
        reload(anchor: nil)
    }

    /// 面板开着时剪贴板变了。有搜索词时不动（别打断搜索）；列表头变了（新拷贝或去重顶上来）就选回第一条。
    /// 返回 true 表示选中回到了第一条，界面应滚回顶部。
    @discardableResult
    public func clipboardDidChange() -> Bool {
        guard query.isEmpty else { return false }
        let previousFirst = items.first?.id
        reload(anchor: selectedRow?.id)
        guard items.first?.id != previousFirst else { return false }
        select(0)
        return true
    }

    /// 搜索框文字（已防抖）。打了冒号前缀以它为准并切换筛选；否则保留当前筛选。
    public func setSearchText(_ text: String) {
        commitPendingUndo() // 列表换了，"放回原位置"没有意义
        query = SearchQuery.resolving(field: text, chip: query.typeChip).query
        reload(anchor: nil)
    }

    /// 切换筛选，保留关键词。返回 nil 表示没有变化；否则返回搜索框应显示的文字（剥掉前缀的关键词）。
    public func setChip(_ chip: SearchTypeChip, fieldText: String) -> String? {
        let keyword = SearchQuery(parsing: fieldText).keyword
        if chip == query.typeChip, fieldText == keyword { return nil }
        commitPendingUndo()
        query = SearchQuery(keyword: keyword, chip: chip)
        reload(anchor: nil)
        return keyword
    }

    /// ←/→ 循环切换筛选。
    public func cycleChip(_ delta: Int, fieldText: String) -> String? {
        let all = SearchTypeChip.allCases
        guard let index = all.firstIndex(of: query.typeChip) else { return nil }
        return setChip(all[(index + delta + all.count) % all.count], fieldText: fieldText)
    }

    // MARK: - 选中

    /// 选中某行（点击、滚动跟随、键盘）。选中离开展开行时收起。
    public func select(_ index: Int) {
        guard let row = row(at: index) else { return }
        selectedIndex = index
        if let expanded, expanded.row != row.id { self.expanded = nil }
        if let armed = armedRecordDeletion, row.id != .secret(armed) { armedRecordDeletion = nil }
        dropStaleSettle()
    }

    public func move(_ delta: Int) {
        guard rowCount > 0 else { return }
        select(max(0, min(rowCount - 1, selectedIndex + delta)))
    }

    /// 选中停下了：最后一次移动后过了按键重复的间隔（界面计时），或鼠标点选。停下的普通文本自动展开。
    public func settle() {
        settledRow = selectedRow?.id
    }

    // MARK: - 命令

    /// 执行命令。`row` 为 nil 时作用于选中行。对这一行不可用的命令什么都不做——图片按 ⌘L 是没有这个功能，不是错误。
    public func perform(_ command: PanelCommand, row: Int? = nil) -> [PanelEffect] {
        let index = row ?? selectedIndex
        if isSecretView {
            guard secretRecords.indices.contains(index) else { return [] }
            return perform(command, record: secretRecords[index], at: index)
        }
        guard items.indices.contains(index) else { return [] }
        let item = items[index]
        if item.isSecret, item.secretMissing, command != .delete {
            // 说一声，别让 ⌘↩ 看起来没反应；收藏 / 打开之类本来就没有的动作照旧不响应
            let wantsSecret: [PanelCommand] = [.paste, .pasteAsSecret, .pastePlaintext, .toggleExpand, .rename]
            return wantsSecret.contains(command) ? [.beep, .toast("这条密钥已从 jt 删除 · 只能删除这条记录")] : []
        }
        switch command {
        case .paste:
            return paste(item)

        case .pasteAsSecret:
            if item.isSecret { return execute(.secretReference(item.secretToken ?? item.content), itemID: item.id) }
            guard ItemActions.can(.pasteAsSecret, item) else { return [] }
            commitPendingUndo() // 也是一次标记：之前那次标记不能再撤销；它自己关面板，不提供撤销
            return attempt {
                let token = try secrets.pasteAsSecret(id: item.id)
                return execute(.secretReference(token), itemID: item.id)
            }

        case .pastePlaintext:
            guard item.isSecret else { return paste(item) }
            guard ItemActions.can(.pastePlaintext, item) else { return [] }
            return attempt { execute(.secretPlaintext(try secrets.resolveValue(for: item)), itemID: item.id) }

        case .markSecret:
            // 引用记录上没有这个动作：没有"取消密钥"（ADR-0001）
            guard ItemActions.can(.markSecret, item) else { return [] }
            commitPendingUndo()
            return attempt {
                // 推荐要在标记之前算：标记后本地只剩引用，明文交给了 jt
                let suggestion = SecretNaming.suggestion(forPlaintext: item.content, namespace: secrets.recentNamespace())
                replaceInPlace(try secrets.markAsSecret(id: item.id))
                pendingUndo = .mark(itemId: item.id)
                // 刚标记的密钥直接进入改名；Esc 就保持"未命名密钥"。改名框里的 ⌘Z 是文字撤销，不走这里
                return [.toast("已存为密钥" + undoHint), .beginRename(row: .clip(item.id), suggestion: suggestion)]
            }

        case .rename:
            guard ItemActions.can(.rename, item) else { return [] }
            let suggestion = item.userFacingSecretName == nil
                ? SecretNaming.suggestion(for: item.secretType.flatMap(SecretType.init(rawValue:)), namespace: secrets.recentNamespace())
                : nil
            return [.beginRename(row: .clip(item.id), suggestion: suggestion)]

        case .toggleExpand:
            select(index)
            settle() // 按 ⌘R 就是停在这一行了；再按一次回到停下时的展开
            return toggleExpand(item)

        case .toggleFavorite:
            return attempt {
                items[index].isFavorite = try store.toggleFavorite(id: item.id)
                return []
            }

        case .openInEditor:
            guard ItemActions.can(.openInEditor, item) else { return [] }
            return [.hide, .openInEditor(item)]

        case .openSource:
            guard ItemActions.can(.openSource, item), let source = item.browserSource else { return [] }
            return [.openSource(source)]

        case .delete:
            // 右键删除非选中行时，选中先移到这一行，删完停在同一位置
            select(index)
            // 只撤销最近一次：再删一条，上一条就真删了
            commitPendingUndo()
            return attempt {
                // 密钥行只删本地记录，不动 jt 里的真值：引用可能已经贴到别处在用
                let removed = try store.delete(id: item.id) ?? item
                items.remove(at: index)
                if expanded?.row == .clip(item.id) { expanded = nil }
                selectedIndex = max(0, min(selectedIndex, items.count - 1))
                pendingUndo = .deletion(item: removed, index: index)
                dropStaleSettle()
                return [.toast("已删除" + undoHint)]
            }
        }
    }

    /// 密钥视图里的命令：都落到 jt。收藏、打开、原页、标记对 jt 记录没有意义，什么都不做。
    private func perform(_ command: PanelCommand, record: SecretRecord, at index: Int) -> [PanelEffect] {
        if command != .delete { armedRecordDeletion = nil }
        switch command {
        case .paste, .pasteAsSecret:
            return execute(.secretReference(record.reference), itemID: nil)

        case .pastePlaintext:
            return attempt { execute(.secretPlaintext(try secrets.resolve(token: record.reference)), itemID: nil) }

        case .rename:
            guard record.userFacingName == nil else { return [.beginRename(row: .secret(record.id))] }
            // 默认名记录：命名空间取刚读到的列表；类型只有在本地还留着引用记录时才知道
            let type = (try? store.item(bySecretToken: record.reference))?.secretType.flatMap(SecretType.init(rawValue:))
            let namespace = SecretNaming.recentNamespace(in: secretSnapshot ?? secretRecords)
            return [.beginRename(row: .secret(record.id), suggestion: SecretNaming.suggestion(for: type, namespace: namespace))]

        case .toggleExpand:
            select(index)
            settle()
            if expanded?.row == .secret(record.id) {
                expanded = nil
                return []
            }
            return attempt {
                let value = try secrets.resolve(token: record.reference)
                expanded = Expanded(row: .secret(record.id), unfold: .body(.text(value + "\n\n" + record.reference)))
                return []
            }

        case .delete:
            select(index)
            // 从 jt 删掉就回不来了，贴到别处的引用也跟着失效：先要再按一次
            guard armedRecordDeletion == record.id else {
                armedRecordDeletion = record.id
                let again = keymap.combo(for: .delete).map { "再按 \($0.display)" } ?? "再删一次"
                return [.toast("\(again) 从 jt 删除「\(record.name)」· 已贴到别处的引用将无法再解析")]
            }
            armedRecordDeletion = nil
            return attempt {
                try secrets.deleteRecord(record)
                secretSnapshot?.removeAll { $0.id == record.id }
                vaultStatusWanted = true
                removeRow(.secret(record.id))
                return [.toast("已从 jt 删除「\(record.name)」")]
            }

        case .markSecret, .toggleFavorite, .openInEditor, .openSource:
            return []
        }
    }

    /// 有可以撤销的删除或标记。
    public var canUndo: Bool { pendingUndo != nil }

    /// 撤销最近一次删除或标记。没有可撤销的动作时返回 nil（未处理）：按键应交给搜索框做文字撤销。
    public func undo() -> [PanelEffect]? {
        guard let pending = pendingUndo else { return nil }
        pendingUndo = nil
        switch pending {
        case .deletion(let item, let index):
            return undoDeletion(item, at: index)
        case .mark(let itemId):
            return undoMark(itemId)
        }
    }

    /// 面板已经显示出来之后调：vault 变过就按 jt 刷新引用记录的名称和"已删除"。
    /// 返回 true 表示列表变了要重画。密钥视图不用：它自己就是 jt 的列表。
    @discardableResult
    public func refreshReferences() -> Bool {
        guard !isSecretView, secrets.refreshReferencesIfVaultChanged() else { return false }
        reload(anchor: selectedRow?.id)
        return true
    }

    /// 界面每次画完调：该问 vault 状态了就返回这次请求的编号，界面在后台问 `jt status`（要跑 git，约半秒），
    /// 问完用 `setVaultStatus` 交回。一次请求只交出一次。
    public func takeVaultStatusRequest() -> Int? {
        guard vaultStatusWanted, isSecretView else { return nil }
        vaultStatusWanted = false
        vaultStatusRequest += 1
        return vaultStatusRequest
    }

    /// 后台问到的 vault 状态；nil = 没问到（jt 报错），不提示。过期的回答、离开密钥视图后才到的回答丢掉。
    /// 返回 true 表示提示变了要重画。
    @discardableResult
    public func setVaultStatus(_ status: JTVaultStatus?, request: Int) -> Bool {
        guard request == vaultStatusRequest, isSecretView else { return false }
        let notice = status?.hasUnsyncedChanges == true ? "有未同步的改动 · 在终端运行 jt sync" : nil
        guard notice != vaultNotice else { return false }
        vaultNotice = notice
        return true
    }

    /// 面板关闭：撤销失效，被删记录的图片文件这时才真正删除。
    public func close() {
        commitPendingUndo()
        armedRecordDeletion = nil
    }

    /// 行内改名提交（名字已 trim、非空）。
    public func rename(row: RowID, to name: String) -> [PanelEffect] {
        switch row {
        case .clip(let itemId):
            return attempt {
                replaceInPlace(try secrets.setName(id: itemId, name: name))
                return []
            }
        case .secret(let recordId):
            guard let index = secretRecords.firstIndex(where: { $0.id == recordId }) else { return [] }
            let record = secretRecords[index]
            // jt mv 到自己现在的名字会报"名字已存在"：没改就不调
            guard name != record.name else { return [] }
            return attempt {
                let renamed = try secrets.renameRecord(record, to: name)
                if let i = secretSnapshot?.firstIndex(where: { $0.id == recordId }) { secretSnapshot?[i] = renamed }
                vaultStatusWanted = true
                // 原地换掉再重排：命名空间变了就挪到新组，选中跟着它走。不重跑筛选——改完不匹配关键词也别让它消失
                secretRecords[index] = renamed
                secretRecords = SecretRecords.sorted(secretRecords)
                selectedIndex = secretRecords.firstIndex { $0.id == recordId } ?? selectedIndex
                dropStaleSettle()
                return []
            }
        }
    }

    // MARK: - 内部

    private var undoHint: String {
        keymap.combo(for: .undo).map { " · \($0.display) 撤销" } ?? ""
    }

    private func commitPendingUndo() {
        guard let pending = pendingUndo else { return }
        pendingUndo = nil
        if case .deletion(let item, _) = pending { removeImageFiles(of: item) }
    }

    /// 按原字段放回库里、放回列表原位置并选中。
    private func undoDeletion(_ item: ClipItem, at index: Int) -> [PanelEffect] {
        do {
            try store.restore(item)
        } catch {
            // 放不回去就按删除处理，别让图片文件变成孤儿
            removeImageFiles(of: item)
            return failure(error)
        }
        let row = min(index, items.count)
        items.insert(item, at: row)
        select(row)
        return []
    }

    /// 取回真值写回原记录并删掉 jt 里刚建的那条；失败时密钥原样可用（见 SecretManager.undoMark）。
    private func undoMark(_ itemId: Int64) -> [PanelEffect] {
        attempt {
            let result = try secrets.undoMark(id: itemId)
            // 撤销窗口内同一明文又被复制进历史时两条合并，被并掉的那行也要从列表拿走
            if let merged = result.mergedDuplicateID { removeRow(.clip(merged)) }
            replaceInPlace(result.item)
            if let row = items.firstIndex(where: { $0.id == itemId }) { select(row) }
            return []
        }
    }

    private func removeImageFiles(of item: ClipItem) {
        ImageStore.removeFiles([item.imagePath, item.thumbPath].compactMap { $0 })
    }

    private func reload(anchor: RowID?) {
        armedRecordDeletion = nil
        if isSecretView {
            items = []
            reloadSecretRecords()
        } else {
            secretSnapshot = nil
            secretRecords = []
            secretListError = nil
            vaultNotice = nil
            vaultStatusWanted = false
            let page: SearchPage
            do {
                page = try store.search(query, page: 1, pageSize: Self.pageSize)
            } catch {
                NSLog("[jtb] search failed: \(error)")
                return
            }
            items = page.items
        }
        if let expanded, index(of: expanded.row) == nil { self.expanded = nil }
        selectedIndex = anchor.flatMap(index(of:)) ?? 0
        dropStaleSettle()
    }

    /// 刚进密钥视图才读 jt；之后改关键词只在本地筛。读失败不缓存，下次改关键词再试。
    private func reloadSecretRecords() {
        if secretSnapshot == nil {
            do {
                secretSnapshot = try secrets.listRecords()
                secretListError = nil
                vaultStatusWanted = true
            } catch {
                NSLog("[jtb] listing jt secrets failed: \(error)")
                secretListError = error.localizedDescription
            }
        }
        secretRecords = SecretRecords.filter(secretSnapshot ?? [], keyword: query.keyword)
    }

    private func dropStaleSettle() {
        if settledRow != selectedRow?.id { settledRow = nil }
    }

    /// 用库里的最新版本替换同 id 的行：不动选中和其余行。
    private func replaceInPlace(_ updated: ClipItem) {
        guard let row = items.firstIndex(where: { $0.id == updated.id }) else {
            reload(anchor: selectedRow?.id)
            return
        }
        items[row] = updated
        if expanded?.row == .clip(updated.id) { expanded = nil }
    }

    /// 已删掉的行从列表拿走，选中仍指向原来那条（删的就是选中行时停在同一位置）。
    private func removeRow(_ id: RowID) {
        guard let row = index(of: id) else { return }
        let selectedId = selectedRow?.id
        switch id {
        case .clip: items.remove(at: row)
        case .secret: secretRecords.remove(at: row)
        }
        if expanded?.row == id { expanded = nil }
        selectedIndex = selectedId.flatMap(index(of:)) ?? max(0, min(selectedIndex, rowCount - 1))
        dropStaleSettle()
    }

    private func toggleExpand(_ item: ClipItem) -> [PanelEffect] {
        if expanded?.row == .clip(item.id) {
            expanded = nil
            return []
        }
        let unfold: RowUnfold
        switch item.kind {
        case .image:
            guard let path = item.imagePath ?? item.thumbPath else { return [] }
            unfold = .body(.image(path: path))
        case .text where item.isSecret:
            do {
                unfold = .body(.text(try secrets.resolveValue(for: item) + "\n\n" + (item.secretToken ?? "")))
            } catch {
                return failure(error)
            }
        case .text:
            unfold = .all
        }
        expanded = Expanded(row: .clip(item.id), unfold: unfold)
        return []
    }

    private func paste(_ item: ClipItem) -> [PanelEffect] {
        if item.isSecret { return execute(.secretReference(item.secretToken ?? item.content), itemID: item.id) }
        switch item.kind {
        case .text:
            return execute(.text(item.content), itemID: item.id)
        case .image:
            guard let path = item.imagePath else { return handle(.contentUnavailable, content: nil) }
            return execute(.image(path: path, asFile: imagePasteAsFile()), itemID: item.id)
        }
    }

    /// itemID：贴回的剪贴板记录，贴成功后标为"贴过"（保留策略用）；jt 记录不在历史里，传 nil。
    private func execute(_ content: PastebackContent, itemID: Int64?) -> [PanelEffect] {
        let result = pasteback.execute(content, intent: pasteback.mode) { [weak self] in
            guard let self, let itemID else { return }
            do { try self.store.markPasted(id: itemID) }
            catch { NSLog("[jtb] failed to retain pasted item: \(error)") }
        }
        return handle(result, content: content)
    }

    private func handle(_ result: PastebackResult, content: PastebackContent?) -> [PanelEffect] {
        switch result {
        case .pasted:
            return result.hidesPanel(for: content) ? [.hide] : []
        case .copied:
            return result.hidesPanel(for: content) ? [.hide, .toast("已复制，请按 ⌘V 粘贴")] : []
        case .needsAccessibility:
            return [.pastebackModeChanged, .beep]
        case .secretPlaintextConfirmationRequired:
            // 走到这里的入口（⇧⌘↩ / 右键"粘贴明文"）本身就是显式意图，不再二次确认。
            guard let content else { return [] }
            let confirmed = pasteback.execute(content, intent: .copyOnly, secretPlaintextConfirmed: true)
            guard case .copied = confirmed else { return handle(confirmed, content: content) }
            return [.hide, .toast("已复制明文，⌘V 粘贴 · 注意明文在系统剪贴板")]
        case .contentUnavailable:
            return [.beep, .toast("内容不可用，剪贴板未修改")]
        }
    }

    private func attempt(_ body: () throws -> [PanelEffect]) -> [PanelEffect] {
        do {
            return try body()
        } catch {
            return failure(error)
        }
    }

    /// 错误只走 toast + 日志，面板不失焦。
    private func failure(_ error: Error) -> [PanelEffect] {
        NSLog("[jtb] error: \(error)")
        return [.beep, .toast(error.localizedDescription)]
    }
}
