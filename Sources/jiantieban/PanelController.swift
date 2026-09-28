import AppKit
import Core

/// 剪贴板面板：NSPanel(.nonactivatingPanel) + NSGlassEffectView + NSTableView 虚拟列表。
/// 状态与规则都在 PanelSession（Core，可测）；这里只负责画出来、把键盘/鼠标翻译成 session 调用、
/// 执行它返回的界面效果。面板临时成为 key window 接收键盘输入，关闭后恢复先前 App，再延迟发送 Cmd+V。
@MainActor
final class PanelController: NSObject {
    private let session: PanelSession
    /// 只用来在后台问 vault 状态（jt status 要跑 git，不能在主线程上等）；别的密钥动作都经 session
    private let secrets: SecretManager
    private let panel: NSPanel
    private let panelWidth: CGFloat
    private let panelHeight: CGFloat = 560
    private let searchField = SpotlightSearchField()
    private let headerView = SpotlightHeaderView()
    private let tableView = NSTableView()
    private let inputSwitcher = InputSourceSwitcher()

    /// 表格当前画出来的内容。数据源只读它；render() 拿它和 session 比对，只刷新变了的部分。
    private var shownRows: [PanelRow] = []
    /// 与 shownRows 一一对应：密钥视图每组第一行上方的组标题
    private var shownHeaders: [String?] = []
    private var shownExpanded: PanelSession.Expanded?
    private var isRendering = false
    /// 选中"停下"的计时：最后一次移动后过了按键重复的起始间隔还没再动，才让 session 自动展开。
    /// 不看 isARepeat：键盘工具把 ⌃J/⌃K 转成的 ↓/↑ 每下都是独立按键。
    private var settleTask: DispatchWorkItem?
    private var settleWatchedRow: RowID?
    /// 渲染途中滚动把选中甩出视口：渲染完再把选中跟到视口
    private var needsSnapAfterRender = false

    /// ⌘1-9 角标锚点：当前视口第一行（随滚动更新）
    private var badgeAnchorRow = 0
    /// 键盘导航触发的滚动中（防止 scroll 回调把选中拉回视口顶部，与导航打架）
    private var keyboardNavigating = false
    /// 某一行正在行内改名：键盘事件全部让给输入框，且不重载列表。
    private var isInlineEditing = false
    /// 按住 ⌘ 期间：显示 ⌘n 角标和当前项的快捷键提示；松开即隐藏
    private var cmdHeld = false
    /// 按住 ⌘ 停 0.3s 才进入快捷键模式：⌘V、⌘A、⌘D 这类一按就松的组合不让顶栏闪一下
    private var cmdHintTask: DispatchWorkItem?
    private static let cmdHintDelay: TimeInterval = 0.3
    private var flagsMonitor: Any?

    private let permissionButton = NSButton(title: "启用一键贴回", target: nil, action: nil)
    private let emptyLabel = NSTextField(labelWithString: "")
    /// 密钥视图顶栏下的一行：vault 有未同步的改动（session.vaultNotice）
    private let noticeLabel = NSTextField(labelWithString: "")

    private var searchDebounce: DispatchWorkItem?
    private var blurCloseTask: DispatchWorkItem?
    private var makeKeyTask: DispatchWorkItem?
    private var previousApp: NSRunningApplication?
    private var keyMonitor: Any?
    private(set) var isVisible = false
    /// 调试模式可关闭失焦自关（截图验收时 screencapture 会抢 key window）
    var blurCloseEnabled = true

    /// 面板隐藏后的回调（AppDelegate 接线用）
    var onDidHide: (() -> Void)?
    /// 面板里按了打开设置（面板先收起）
    var onOpenSettings: (() -> Void)?

    /// keymap：键位表，默认 Keymap.defaults；自定义快捷键时传 `Keymap.defaults.overriding(...)`。
    init(store: ClipStore, secrets: SecretManager, pasteback: PastebackCoordinator? = nil, keymap: Keymap = .defaults) {
        session = PanelSession(
            store: store,
            secrets: secrets,
            pasteback: pasteback ?? Pasteback.makeCoordinator(),
            imagePasteAsFile: { AppSettings.shared.imagePasteAsFile },
            keymap: keymap,
            autoUnfoldLines: { AppSettings.shared.autoUnfoldLines }
        )
        self.secrets = secrets
        self.panelWidth = CGFloat(AppSettings.shared.panelWidth)
        panel = ClipboardPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            // .borderless：.titled 窗框会在玻璃外再画一圈自己的小圆角（暗色下露出双层角）
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        super.init()
        setupPanel()
        setupKeyMonitor()
    }

    // MARK: - UI 构建

    private func setupPanel() {
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // 阴影交给系统：它按窗口的 alpha 轮廓画在窗口外面，不挡点击。前提是圆角外完全透明——
        // 玻璃自己会在轮廓外画一圈淡阴影，窗口和玻璃一样大时它被直角边切成"方形灰底"，
        // 系统阴影再按这圈半透明像素算就在角上出硬边。所以玻璃装进按圆角裁剪的容器（见 makeChromeRoot）。
        panel.hasShadow = !DebugFlags.solidBackground
        panel.level = .floating
        panel.animationBehavior = .none // 一天唤起几十次：出现 / 收起不加动画（见 Motion）
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = self

        let root = makeChromeRoot()
        installChrome(in: root)
    }

    /// 玻璃必须走 `NSGlassEffectView.contentView`；直接往 glass 上 addSubview 会穿帮、透出背后文字。
    private func makeChromeRoot() -> NSView {
        let frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        // 截图量尺用：纯色底，去掉玻璃透出的桌面噪声
        if DebugFlags.solidBackground {
            let solid = SolidBackdropView(frame: frame)
            solid.wantsLayer = true
            solid.layer?.cornerRadius = PanelMetrics.cornerRadius
            solid.layer?.masksToBounds = true
            solid.autoresizingMask = [.width, .height]
            panel.contentView = solid
            let root = PanelChromeHost(frame: solid.bounds)
            root.autoresizingMask = [.width, .height]
            solid.addSubview(root)
            return root
        }
        if AppSettings.shared.appearanceStyle == "compatible" {
            let vibrancy = NSVisualEffectView(frame: frame)
            vibrancy.material = .popover
            vibrancy.blendingMode = .behindWindow
            vibrancy.state = .active
            vibrancy.wantsLayer = true
            vibrancy.layer?.cornerRadius = PanelMetrics.cornerRadius
            vibrancy.layer?.cornerCurve = .continuous
            vibrancy.layer?.masksToBounds = true
            vibrancy.autoresizingMask = [.width, .height]
            panel.contentView = vibrancy
            let root = PanelChromeHost(frame: vibrancy.bounds)
            root.autoresizingMask = [.width, .height]
            vibrancy.addSubview(root)
            return root
        }

        let glass = NSGlassEffectView(frame: frame)
        glass.cornerRadius = PanelMetrics.cornerRadius
        glass.style = .regular
        // 对照系统 Spotlight：浅色桌面上它明显更白；.regular 默认偏灰，浅色模式补一层白 tint，暗色不动
        glass.tintColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .clear : NSColor.white.withAlphaComponent(0.25)
        }
        if #available(macOS 27.0, *) {
            glass.effectIsInteractive = true
        }
        glass.autoresizingMask = [.width, .height]
        // 按玻璃同样的圆角裁掉它画在轮廓外的阴影：角上完全透明，系统阴影才贴着圆角走
        let clip = NSView(frame: frame)
        clip.wantsLayer = true
        clip.layer?.cornerRadius = PanelMetrics.cornerRadius
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        clip.autoresizingMask = [.width, .height]
        clip.addSubview(glass)
        panel.contentView = clip

        let root = PanelChromeHost(frame: glass.bounds)
        root.autoresizingMask = [.width, .height]
        glass.contentView = root
        return root
    }

    private func installChrome(in root: NSView) {
        headerView.embed(searchField)
        searchField.delegate = self



        permissionButton.bezelStyle = .inline
        permissionButton.controlSize = .small
        permissionButton.font = .systemFont(ofSize: 11, weight: .medium)
        permissionButton.target = self
        permissionButton.action = #selector(requestAccessibility)
        permissionButton.isHidden = true

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 3
        emptyLabel.lineBreakMode = .byTruncatingTail
        emptyLabel.cell?.wraps = true
        emptyLabel.isHidden = true

        noticeLabel.font = .systemFont(ofSize: 11)
        noticeLabel.textColor = .secondaryLabelColor
        noticeLabel.lineBreakMode = .byTruncatingTail
        noticeLabel.isHidden = true

        let scrollView = NSScrollView(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.width = panelWidth
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        // 关键性能开关：禁用「文字截断悬停展开 tooltip」。
        // 开启时每帧滚动都会对新入行内每个 label 做 CoreText 排版测量（CJK 排版尤其贵），
        // 60Hz 键盘导航下主线程被打满，滚动跟不上选择（sample 实测证据）。
        tableView.allowsExpansionToolTips = false
        tableView.allowsEmptySelection = false
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(onTableDoubleClick)
        tableView.menu = makeContextMenu()
        tableView.menu?.delegate = self

        scrollView.documentView = tableView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(onScrollBoundsChanged),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )

        if let host = root as? PanelChromeHost {
            host.header = headerView
            host.permissionButton = permissionButton
            host.empty = emptyLabel
            host.notice = noticeLabel
            host.scroll = scrollView
        }
        root.addSubview(headerView)
        root.addSubview(noticeLabel)
        root.addSubview(scrollView)
        root.addSubview(emptyLabel)
        root.addSubview(permissionButton)
        root.needsLayout = true
    }

    // MARK: - 右键菜单

    /// 每项显示的快捷键取自键位表；标题与显隐在 menuWillOpen 按这一行更新。
    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem("粘贴密钥引用", #selector(pasteSecretReferenceFromMenu), .pasteAsSecret))
        menu.addItem(menuItem("粘贴明文", #selector(pastePlaintextFromMenu), .pastePlaintext))
        menu.addItem(menuItem("标记为密钥", #selector(markSecretFromMenu), .markSecret))
        menu.addItem(menuItem("重命名", #selector(editSecretNameFromMenu), .rename))
        menu.addItem(menuItem("打开", #selector(openInEditorFromMenu), .openInEditor))
        menu.addItem(menuItem("回到页面", #selector(openSourceFromMenu), .openSource))
        menu.addItem(menuItem("收藏", #selector(toggleFavoriteFromMenu), .toggleFavorite))
        menu.addItem(.separator())
        menu.addItem(menuItem("删除", #selector(deleteFromMenu), .delete))
        return menu
    }

    private func menuItem(_ title: String, _ selector: Selector, _ action: PanelAction) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = action.rawValue
        applyKeyEquivalent(to: item, action)
        return item
    }

    /// 菜单项上显示的快捷键跟着当前键位表走（设置页改过后，下次打开菜单就是新的）
    private func applyKeyEquivalent(to item: NSMenuItem, _ action: PanelAction) {
        if let combo = session.keymap.combo(for: action) {
            item.keyEquivalent = KeyTranslation.keyEquivalent(for: combo.key)
            item.keyEquivalentModifierMask = KeyTranslation.modifierFlags(for: combo.modifiers)
        } else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
        }
    }

    private func menuRow() -> Int? {
        let row = tableView.clickedRow
        if row >= 0 { return row }
        return session.selectedRow == nil ? nil : session.selectedIndex
    }

    @objc private func pasteSecretReferenceFromMenu() { run(.pasteAsSecret, row: menuRow()) }
    @objc private func pastePlaintextFromMenu() { run(.pastePlaintext, row: menuRow()) }
    @objc private func markSecretFromMenu() { run(.markSecret, row: menuRow()) }
    @objc private func editSecretNameFromMenu() { run(.rename, row: menuRow()) }
    @objc private func openInEditorFromMenu() { run(.openInEditor, row: menuRow()) }
    @objc private func openSourceFromMenu() { run(.openSource, row: menuRow()) }
    @objc private func toggleFavoriteFromMenu() { run(.toggleFavorite, row: menuRow()) }
    @objc private func deleteFromMenu() { run(.delete, row: menuRow()) }

    @objc private func requestAccessibility() {
        Pasteback.requestAccessibility()
    }

    // MARK: - 命令与效果

    /// 命令入口：键盘、菜单、双击、⌘1-9 都走这里。先画出新状态，再执行界面效果（改名要在刷新后的行上开始）。
    private func run(_ command: PanelCommand, row: Int? = nil) {
        let effects = session.perform(command, row: row)
        render(scroll: command == .toggleExpand ? .reveal : .keep)
        apply(effects)
    }

    private func apply(_ effects: [PanelEffect]) {
        for effect in effects {
            switch effect {
            case .hide:
                hide()
            case .toast(let message):
                PastebackToast.show(message)
            case .beep:
                NSSound.beep()
            case .beginRename(let row, let suggestion):
                beginInlineNameEdit(row: row, suggestion: suggestion)
            case .openInEditor(let item):
                EditorOpener.open(item)
            case .openSource(let source):
                guard let url = URL(string: source.url) else {
                    PastebackToast.show("原页面地址不可用")
                    break
                }
                hide(restoringPreviousApp: false)
                if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleID) {
                    NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: .init()) { _, error in
                        if let error {
                            NSLog("[jtb] opening source page failed: \(error)")
                            Task { @MainActor in PastebackToast.show("没能打开原页面") }
                        }
                    }
                } else if !NSWorkspace.shared.open(url) {
                    PastebackToast.show("没能打开原页面")
                }
            case .pastebackModeChanged:
                refreshPastebackMode()
            }
        }
    }

    /// 重命名：不弹框，标题原地变输入框（见 ClipCellView.beginEditingName）。
    private func beginInlineNameEdit(row id: RowID, suggestion: String? = nil) {
        guard let row = session.index(of: id) else { return }
        session.select(row)
        render(scroll: .reveal)
        tableView.layoutSubtreeIfNeeded()
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? ClipCellView else { return }
        isInlineEditing = true
        cell.beginEditingName(suggestion: suggestion)
    }

    private func endInlineNameEdit() {
        guard isInlineEditing else { return }
        isInlineEditing = false
        render()
        panel.makeFirstResponder(searchField)
    }

    // MARK: - 渲染：比对 session 与表格当前内容，只刷新变了的部分

    private enum Scroll {
        case keep
        /// 选中行滚进视口
        case reveal
        /// 键盘导航：滚进视口且不让滚动回调把选中拉走
        case navigate
    }

    private func render(scroll: Scroll = .keep, reloadAll: Bool = false) {
        isRendering = true
        let old = shownRows
        let oldHeaders = shownHeaders
        let oldExpanded = shownExpanded
        let new = session.rows
        let newHeaders = new.indices.map { session.groupHeader(at: $0) }
        let newExpanded = session.unfolded
        // 先换数据源，再通知表格：刷新过程中 AppKit 回调读到的已是新内容
        shownRows = new
        shownHeaders = newHeaders
        shownExpanded = newExpanded

        // 这次渲染选中换了行 = 在导航：行高变化立即生效，不给下面的行加动画
        let selectionMoved = tableView.selectedRow != session.selectedIndex

        var contentChanged = reloadAll
        // 组标题跟着邻居走：删掉组里第一条，下一条就要画标题——整表刷新
        let headersShifted = oldHeaders.count == newHeaders.count ? oldHeaders != newHeaders : new.contains { $0.record != nil }
        if reloadAll || old.map(\.id) != new.map(\.id) {
            contentChanged = true
            if !reloadAll, !headersShifted, let removed = Self.singleRemoval(from: old, to: new) {
                tableView.removeRows(at: IndexSet(integer: removed), withAnimation: Motion.rowFade)
            } else if !reloadAll, !headersShifted, let inserted = Self.singleRemoval(from: new, to: old) {
                // 撤销删除：在原位置淡入，和删除时的淡出对称
                tableView.insertRows(at: IndexSet(integer: inserted), withAnimation: Motion.rowFade)
            } else {
                replaceAllRows(oldCount: old.count, newCount: new.count)
            }
        } else {
            var heightRows = IndexSet()
            if oldExpanded != newExpanded {
                for id in [oldExpanded?.row, newExpanded?.row].compactMap({ $0 }) {
                    if let row = new.firstIndex(where: { $0.id == id }) { heightRows.insert(row) }
                }
            } else if let expanded = newExpanded,
                      let row = new.firstIndex(where: { $0.id == expanded.row }),
                      old[row].clip?.browserSource != new[row].clip?.browserSource {
                // 浏览器查询晚于展开返回：来源区出现/消失时也要重新计算行高。
                heightRows.insert(row)
            }
            let rows = IndexSet(new.indices.filter { new[$0] != old[$0] || newHeaders[$0] != (oldHeaders.indices.contains($0) ? oldHeaders[$0] : nil) }).union(heightRows)
            if !rows.isEmpty {
                contentChanged = true
                tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
            }
            // 先换内容、再改行高。反过来的话，重载出来的 cell 直接拿到最终行高，行视图的高度动画又按增量
            // 把它再撑高一遍：cell 比行高出一截（实测 94 → 132），展开后时间行被挤到行外。
            if !heightRows.isEmpty {
                // 停下展开、⌘R：短动画；导航时收回上一行：立即。动画中再按键会以 0 时长打断它
                Motion.run(selectionMoved ? 0 : Motion.rowResize) {
                    tableView.noteHeightOfRows(withIndexesChanged: heightRows)
                }
            }
        }

        let selectionChanged = !new.isEmpty && tableView.selectedRow != session.selectedIndex
        if selectionChanged {
            tableView.selectRowIndexes(IndexSet(integer: session.selectedIndex), byExtendingSelection: false)
        }
        if contentChanged {
            updateChrome()
        } else if selectionChanged {
            updateFooterHint()
        }

        switch scroll {
        case .keep:
            break
        case .reveal:
            if !new.isEmpty { tableView.scrollRowToVisible(session.selectedIndex) }
        case .navigate:
            if !new.isEmpty {
                keyboardNavigating = true
                tableView.scrollRowToVisible(session.selectedIndex)
                ensureSelectedRowVisible()
                keyboardNavigating = false
            }
        }
        syncBadgeAnchor()
        isRendering = false
        if needsSnapAfterRender {
            needsSnapAfterRender = false
            snapSelectionToViewport()
        }
        syncSettleTimer()
        requestVaultStatusIfNeeded()
    }

    /// 进密钥视图、在里面改名 / 删除之后，后台问一次 jt status，有未同步的改动就在顶栏下提示（App 自己不 sync）。
    private func requestVaultStatusIfNeeded() {
        guard let request = session.takeVaultStatusRequest() else { return }
        let secrets = self.secrets
        DispatchQueue.global(qos: .userInitiated).async {
            let status: JTVaultStatus?
            do {
                status = try secrets.fetchVaultStatus()
            } catch {
                NSLog("[jtb] jt status failed: \(error)")
                status = nil
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.session.setVaultStatus(status, request: request) else { return }
                self.updateNotice()
                self.fitPanelHeight()
            }
        }
    }

    /// 选中换了条目就重新计时；已停下（点选、⌘R）就不用等。
    private func syncSettleTimer() {
        let selectedId = session.selectedRow?.id
        let moved = selectedId != settleWatchedRow
        settleWatchedRow = selectedId
        guard selectedId != nil, !session.isSettled else {
            settleTask?.cancel()
            settleTask = nil
            return
        }
        guard moved || settleTask == nil else { return }
        settleTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.settleTask = nil
            guard self.isVisible else { return }
            self.session.settle()
            // 改名中不刷列表（输入框在行上）；密钥行本来也不自动展开
            guard !self.isInlineEditing else { return }
            self.render(scroll: .reveal)
        }
        settleTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.keyRepeatDelay + 0.05, execute: task)
    }

    /// 整表换内容（切筛选、搜索、打开面板）。不用 reloadData：它丢掉可见行的 cell 而不放回复用池，
    /// 每次都新建一屏 cell 和行视图，切一次筛选要 110–190ms 布局（实测）。这里多出的行删、缺的行补，
    /// 其余原位重载，cell 和行视图都能复用；不加动画（切分类是高频操作，见 Motion）。
    private func replaceAllRows(oldCount: Int, newCount: Int) {
        let kept = IndexSet(0..<min(oldCount, newCount))
        Motion.run(0) {
            tableView.beginUpdates()
            if newCount < oldCount {
                tableView.removeRows(at: IndexSet(newCount..<oldCount), withAnimation: [])
            } else if newCount > oldCount {
                tableView.insertRows(at: IndexSet(oldCount..<newCount), withAnimation: [])
            }
            tableView.reloadData(forRowIndexes: kept, columnIndexes: IndexSet(integer: 0))
            tableView.noteHeightOfRows(withIndexesChanged: kept)
            tableView.endUpdates()
        }
        // 原位重载只换 cell，行视图留着：组标题的留白要跟着新内容改
        tableView.enumerateAvailableRowViews { rowView, row in
            (rowView as? ClipRowView)?.headerInset = shownHeader(row) != nil ? ClipCellView.groupHeaderHeight : 0
        }
    }

    /// old 去掉一行正好等于 new 时返回那一行（删除淡出；参数对调即"插回一行"，撤销淡入），否则 nil（整表刷新）。
    private static func singleRemoval(from old: [PanelRow], to new: [PanelRow]) -> Int? {
        guard old.count == new.count + 1 else { return nil }
        let index = new.indices.first { old[$0].id != new[$0].id } ?? new.count
        var rest = old
        rest.remove(at: index)
        return rest.map(\.id) == new.map(\.id) ? index : nil
    }

    private func shownUnfold(for row: PanelRow) -> RowUnfold? {
        shownExpanded?.row == row.id ? shownExpanded?.unfold : nil
    }

    private func shownHeader(_ index: Int) -> String? {
        shownHeaders.indices.contains(index) ? shownHeaders[index] : nil
    }

    private func shownRowHeight(_ index: Int) -> CGFloat {
        let row = shownRows[index]
        return ClipCellView.rowHeight(for: row, hasHeader: shownHeader(index) != nil, unfold: shownUnfold(for: row),
                                      width: tableView.bounds.width, maxHeight: listMaxHeight)
    }

    /// 列表最多能占的高度（面板长到最高时）：展开的行不超过它
    private var listMaxHeight: CGFloat {
        panelHeight - PanelMetrics.headerHeight - noticeHeight - PanelMetrics.sectionGap - PanelMetrics.bottomPad
    }

    // MARK: - 显示 / 隐藏

    func show() {
        NSLog("[jtb] show begin")
        refreshPastebackMode()
        positionOnMouseScreen()

        searchDebounce?.cancel()
        searchField.stringValue = ""
        headerView.syncSearchChrome()
        badgeAnchorRow = 0
        ClipCellView.clearTimeCache()
        session.open()
        headerView.setChip(session.query.typeChip)
        render(scroll: .reveal, reloadAll: true)
        applyDebugContent()

        let front = NSWorkspace.shared.frontmostApplication
        if front != NSRunningApplication.current {
            previousApp = front
        }
        // accessory + 无边框时，不激活本进程窗口永远成不了 key，键盘会落到背后的 App。
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if !shownRows.isEmpty {
            tableView.scrollRowToVisible(0)
            tableView.enclosingScrollView?.contentView.scroll(to: .zero)
        }
        panel.makeFirstResponder(searchField)

        makeKeyTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.isVisible else { return }
            self.panel.makeKey()
            self.panel.makeFirstResponder(self.searchField)
            NSLog("[jtb] show+async isKey=\(self.panel.isKeyWindow) active=\(NSApp.isActive)")
        }
        makeKeyTask = task
        DispatchQueue.main.async(execute: task)
        // 面板先出来，再看 vault 变没变（没变只是一次 stat）：终端里改名 / 删掉的密钥，引用记录跟着更新
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, self.session.refreshReferences() else { return }
            self.render(scroll: .keep)
        }

        inputSwitcher.saveAndSwitchToEnglish()
        session.keymap = AppSettings.shared.keymap // 设置页可能改过快捷键（设置页开着时面板是收起的）
        isVisible = true
        if DebugFlags.holdCommand {
            setCmdHeld(true) // 截图：直接进入快捷键模式
        } else if NSEvent.modifierFlags.contains(.command) {
            scheduleCmdHints() // 热键 ⇧⌘V 唤起时 ⌘ 往往还按着：继续按住才出提示
        }
        applyDebugPresets()
        NSLog("[jtb] show end: isKey=\(panel.isKeyWindow) active=\(NSApp.isActive) canBecomeKey=\(panel.canBecomeKey) firstResponder=\(String(describing: panel.firstResponder)) frame=\(panel.frame)")
    }

    /// 截图量尺的预设内容（DebugFlags），在面板出现之前生效：出现后再改列表会让窗口缩放与
    /// 搜索框布局交错，截图里的文字偶尔差 1px。正常启动时为空操作。
    private func applyDebugContent() {
        if let name = DebugFlags.appearance {
            panel.appearance = NSAppearance(named: name)
        }
        if DebugFlags.imageFilter {
            applyTypeChip(.image)
        }
        if let text = DebugFlags.query {
            searchField.stringValue = text
            headerView.syncSearchChrome()
            applySearchField()
        }
    }

    /// 截图量尺的预设动作（面板出现之后）；正常启动时为空操作。
    private func applyDebugPresets() {
        if let text = DebugFlags.query {
            // 排在 show() 的异步 makeFirstResponder 之后：它会把框里已有的字全选，这里把光标放回末尾
            DispatchQueue.main.async { [weak self] in
                self?.searchField.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
            }
        }
        if !DebugFlags.keys.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.replayDebugKeys(DebugFlags.keys) }
        }
        if DebugFlags.expandSelected {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.run(.toggleExpand) }
        }
    }

    /// 截图量尺：按顺序回放按键，直接喂给键盘处理（不依赖前台焦点，锁屏也能跑）。
    private func replayDebugKeys(_ keys: [String]) {
        let table: [String: (code: UInt16, flags: NSEvent.ModifierFlags, chars: String)] = [
            "up": (126, [], "\u{F700}"), "down": (125, [], "\u{F701}"),
            "cmd-up": (126, .command, "\u{F700}"), "cmd-down": (125, .command, "\u{F701}"),
            "cmd-r": (15, .command, "r"), "cmd-l": (37, .command, "l"), "cmd-e": (14, .command, "e"),
            "cmd-d": (2, .command, "d"), "cmd-s": (1, .command, "s"), "cmd-o": (31, .command, "o"),
            "cmd-z": (6, .command, "z"), "cmd-comma": (43, .command, ","),
        ]
        for key in keys {
            if key.hasPrefix("type:") {
                (panel.firstResponder as? NSTextView)?.insertText(String(key.dropFirst(5)), replacementRange: NSRange(location: NSNotFound, length: 0))
            } else if key == "field-enter" {
                (panel.firstResponder as? NSTextView)?.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            } else if let k = table[key], let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: k.flags, timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: k.chars,
                charactersIgnoringModifiers: k.chars, isARepeat: false, keyCode: k.code
            ) {
                _ = handleKey(event)
            } else {
                NSLog("[jtb] unknown debug key: \(key)")
            }
        }
    }

    /// 退出前：还能撤销的删除到此为止，被删图片的文件这时删掉（面板开着就退出时，不然文件留在磁盘上没人清理）。
    func finishPendingDeletion() { session.close() }

    /// restoringPreviousApp：false 时不把焦点还给唤起前的 App（接着要打开本 App 的窗口，如设置）。
    func hide(restoringPreviousApp: Bool = true) {
        guard isVisible else { return }
        NSLog("[jtb] hide")
        isVisible = false
        panel.orderOut(nil) // 先从屏幕消失，再做数据库收尾和输入法恢复；避免失焦后还悬在别的窗口上
        session.close() // 撤销删除到此失效，被删图片的文件这时才删
        isInlineEditing = false
        cmdHeld = false
        cmdHintTask?.cancel()
        cmdHintTask = nil
        makeKeyTask?.cancel()
        blurCloseTask?.cancel()
        settleTask?.cancel()
        settleTask = nil
        inputSwitcher.restore()
        let front = NSWorkspace.shared.frontmostApplication
        if restoringPreviousApp, front == nil || front == NSRunningApplication.current {
            previousApp?.activate(options: []) // .activateIgnoringOtherApps 自 macOS 14 起无效且已弃用
        }
        previousApp = nil
        onDidHide?()
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    private func positionOnMouseScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        // 顶边固定在屏幕 15% 处，高度随内容变时只往下长
        let size = panel.frame.size
        let x = screen.frame.midX - size.width / 2
        let top = screen.frame.maxY - screen.frame.height * 0.15
        panel.setFrameOrigin(NSPoint(x: x, y: top - size.height))
    }

    /// 调试：60Hz 连续下移选择，用于复现快速导航滚动问题 + sample 采样
    func debugAutoScroll(duration: TimeInterval = 6) {
        let end = Date().addingTimeInterval(duration)
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            let done = MainActor.assumeIsolated { () -> Bool in // 计时器挂在主 RunLoop 上
                guard let self, Date() < end else { return true }
                if self.session.selectedIndex >= self.session.rowCount - 1 {
                    self.session.select(0)
                    self.render(scroll: .reveal)
                }
                self.move(1)
                return false
            }
            if done {
                timer.invalidate()
                NSLog("[jtb] debugAutoScroll done")
            }
        }
    }

    // MARK: - 数据

    /// 面板可见且剪贴板变化时刷新（无搜索词才刷，避免打断搜索）。
    /// 列表头变了（新拷或去重顶到第一条）就选中第一条；自写剪贴板等未入库的变化保持当前选中。
    func refreshIfVisible() {
        guard isVisible, !isInlineEditing else { return }
        let backToTop = session.clipboardDidChange()
        render(scroll: backToTop ? .reveal : .keep)
    }

    /// ⌘1-9 角标锚定视口第一行；直接改可见 cell 的角标，不走 reload（避免滚动中重载抖动）
    private func syncBadgeAnchor() {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.location != NSNotFound, visible.length > 0 else { return }
        let anchor = visible.location
        guard anchor != badgeAnchorRow else { return }
        badgeAnchorRow = anchor
        for row in visible.location..<(visible.location + visible.length) {
            guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ClipCellView else { continue }
            let i = row - anchor
            cell.setBadge(cmdHeld && (0..<9).contains(i) ? "⌘\(i + 1)" : nil)
        }
    }

    /// 空态文案 + 面板高度跟内容走 + 模式提示
    private func updateChrome() {
        refreshPastebackMode()
        emptyLabel.isHidden = !shownRows.isEmpty
        if session.isSecretView {
            // 读不到 jt 要说原因：空列表会让人以为密钥都没了
            emptyLabel.stringValue = session.secretListError.map { "读不到 jt 的密钥：\($0)" }
                ?? (session.query.keyword.isEmpty ? "jt 里还没有密钥" : "没有匹配的密钥")
        } else {
            emptyLabel.stringValue = session.query.isEmpty
                ? "还没有剪贴板历史，复制点什么吧"
                : "没有匹配的条目"
        }
        emptyLabel.toolTip = session.secretListError
        emptyLabel.superview?.needsLayout = true
        updateNotice()
        fitPanelHeight()
    }

    private func updateNotice() {
        noticeLabel.stringValue = session.vaultNotice ?? ""
        noticeLabel.isHidden = session.vaultNotice == nil
        noticeLabel.superview?.needsLayout = true
    }

    /// 提示条占的高度：没有提示时为 0
    private var noticeHeight: CGFloat { noticeLabel.isHidden ? 0 : PanelMetrics.noticeHeight }

    /// Spotlight 同款：高度 = 头 + 内容 + 脚，上边缘不动；空态给一块最小高度；最多 panelHeight。
    private func fitPanelHeight() {
        let rowsH = shownRows.indices.reduce(CGFloat(0)) { acc, index in acc + shownRowHeight(index) }
        let gaps = PanelMetrics.sectionGap + PanelMetrics.bottomPad
        let listH: CGFloat = shownRows.isEmpty ? 96 : min(rowsH, listMaxHeight)
        let target = PanelMetrics.headerHeight + noticeHeight + gaps + listH
        var frame = panel.frame
        guard abs(frame.height - target) > 0.5 else { return }
        frame.origin.y = frame.maxY - target
        frame.size.height = target
        panel.setFrame(frame, display: true, animate: false)
        panel.invalidateShadow() // 形状变了，阴影按新轮廓重算
    }

    func refreshPastebackMode() {
        let copyOnly = session.mode == .copyOnly
        permissionButton.isHidden = !copyOnly
        tableView.menu?.update()
        updateFooterHint()
    }

    /// 只在按住 ⌘ 时显示当前项的快捷键；标签统一两字。回车贴回是常识，不写。
    private func updateFooterHint() {
        headerView.setHints(cmdHeld ? session.hints.map { ($0.key, $0.label, ItemActions.hintPriority($0.action)) } : [])
    }

    /// ⌘ 按下：停一下再出提示；松开：立即收起
    private func commandFlagChanged(_ down: Bool) {
        if down {
            if !cmdHeld { scheduleCmdHints() }
        } else {
            cmdHintTask?.cancel()
            cmdHintTask = nil
            setCmdHeld(false)
        }
    }

    /// 从现在起 ⌘ 一直按着、不按别的键，满 cmdHintDelay 才出提示；按了组合键就重新计时
    private func scheduleCmdHints() {
        cmdHintTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.isVisible, NSEvent.modifierFlags.contains(.command) else { return }
            self.cmdHintTask = nil
            self.setCmdHeld(true)
        }
        cmdHintTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.cmdHintDelay, execute: task)
    }

    /// ⌘ 按下/松开：角标 + 提示一起出现/消失
    private func setCmdHeld(_ held: Bool) {
        guard held != cmdHeld else { return }
        cmdHeld = held
        updateFooterHint()
        badgeAnchorRow = -1
        syncBadgeAnchor()
    }

    @objc private func onScrollBoundsChanged(_ note: Notification) {
        // 全量加载后无需翻页；滚动只驱动 ⌘1-9 角标锚点
        syncBadgeAnchor()
        // 非键盘触发的滚动（触控板/鼠标滚轮/拖滚动条，含惯性）：
        // 选中行被甩出可视区时，把选中跟到视口顶部，保证「选中的条目永不出窗口」。
        guard !keyboardNavigating else { return }
        if isRendering {
            needsSnapAfterRender = true
            return
        }
        snapSelectionToViewport()
    }

    /// 滚动把选中行甩出视口时，把选中移到视口顶部行（跟随视口顶部移动）
    private func snapSelectionToViewport() {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.location != NSNotFound, visible.length > 0 else { return }
        guard !(visible.location..<(visible.location + visible.length)).contains(session.selectedIndex) else { return }
        session.select(visible.location)
        render()
    }

    // MARK: - 鼠标

    @objc private func onTableDoubleClick() {
        let row = tableView.clickedRow
        guard row >= 0 else { return }
        if clickLandedOnRowControl() { return }
        session.select(row)
        run(.paste)
    }

    /// 锁 / 眼睛 / 铅笔 / 密钥引用按钮自己处理点击，双击不得再走整行贴回。
    private func clickLandedOnRowControl() -> Bool {
        guard let event = NSApp.currentEvent else { return false }
        let pointInTable = tableView.convert(event.locationInWindow, from: nil)
        let row = tableView.row(at: pointInTable)
        guard row >= 0,
              let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ClipCellView else {
            return false
        }
        let pointInCell = cell.convert(pointInTable, from: tableView)
        return cell.hitTest(pointInCell) is NSControl
    }

    private func move(_ delta: Int) {
        session.move(delta)
        render(scroll: .navigate)
    }

    /// 兜底滚动：scrollRowToVisible 的滚动可能被 AppKit 延迟/合并（快速连发、主线程忙时），
    /// 直接按行矩形改 clip bounds，保证每次按键后选中行都完全落在视口内。
    private func ensureSelectedRowVisible() {
        guard let clip = tableView.enclosingScrollView?.contentView else { return }
        let rowRect = tableView.rect(ofRow: session.selectedIndex)
        let visible = clip.bounds
        var newY = visible.origin.y
        if rowRect.minY < visible.minY {
            newY = rowRect.minY
        } else if rowRect.maxY > visible.maxY {
            newY = rowRect.maxY - visible.height
        }
        newY = max(0, min(newY, tableView.frame.height - visible.height))
        if abs(newY - visible.origin.y) > 0.5 {
            clip.scroll(to: NSPoint(x: visible.origin.x, y: newY))
        }
    }

    private static let digitKeyCodes: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
    ]

    // MARK: - 键盘（3.3 节 parity 全集）

    private func setupKeyMonitor() {
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, self.isVisible else { return event }
            self.commandFlagChanged(event.modifierFlags.contains(.command))
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            // 按着 ⌘ 按了组合键（⌘V、⌘D…）：用户知道要按什么，提示重新计时
            if event.modifierFlags.contains(.command), !self.cmdHeld { self.scheduleCmdHints() }
            // 芯片 ←/→ 在 .nonactivatingPanel 上不得要求 isKeyWindow。
            if self.handleChipCycleKey(event) { return nil }
            guard self.panel.isKeyWindow else { return event }
            return self.handleKey(event)
        }
    }

    /// 按键 → 键位表里的动作。表里没有的组合（⌃ 系列、搜索框的 ⌘A/⌘C…）原样放行给搜索框。
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        // 行内改名中：回车 / Esc / 字符全部归输入框
        if isInlineEditing { return event }
        let cmd = event.modifierFlags.contains(.command)
        let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty

        if let combo = KeyTranslation.combo(for: event), let action = session.keymap.action(for: combo) {
            return perform(action) ? nil : event
        }

        // ⌘1..⌘9 贴回视口中的第 n 项（与角标一致）
        if cmd, let digit = Self.digitKeyCodes[event.keyCode], shownRows.indices.contains(badgeAnchorRow + digit - 1) {
            run(.paste, row: badgeAnchorRow + digit - 1)
            return nil
        }

        // 可打印字符：焦点不在搜索框时转发过去。方向键、回车等不是字符，不转发。
        if plain, let chars = event.characters, chars.count == 1, KeyTranslation.isPrintable(chars),
           panel.firstResponder !== searchField.currentEditor() {
            panel.makeFirstResponder(searchField)
            searchField.currentEditor()?.moveToEndOfLine(nil)
            searchField.currentEditor()?.insertText(chars)
            return nil
        }
        return event
    }

    /// 执行键位表里的动作。返回 false = 这次不处理（如没有可撤销的删除 / 标记时 ⌘Z），按键照常交给搜索框。
    private func perform(_ action: PanelAction) -> Bool {
        switch action {
        case .moveUp:
            move(-1)
        case .moveDown:
            move(1)
        case .jumpToFirst:
            move(-session.rowCount)
        case .jumpToLast:
            move(session.rowCount)
        case .undo:
            guard let effects = session.undo() else { return false }
            render(scroll: .reveal)
            apply(effects)
        case .openSettings:
            hide(restoringPreviousApp: false)
            onOpenSettings?()
        case .close:
            hide()
        default:
            guard let command = action.command else { return false }
            run(command)
        }
        return true
    }

    /// 搜索框为空时 ←/→ 切芯片；框里有字时把方向键留给光标。不要求面板是 key。
    private func handleChipCycleKey(_ event: NSEvent) -> Bool {
        guard !isInlineEditing else { return false }
        let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        guard plain, searchField.stringValue.isEmpty else { return false }
        switch event.keyCode {
        case 123:
            cycleTypeChip(-1)
            return true
        case 124:
            cycleTypeChip(1)
            return true
        default:
            return false
        }
    }

    private func cycleTypeChip(_ delta: Int) {
        guard let text = session.cycleChip(delta, fieldText: searchField.stringValue) else { return }
        showChip(fieldText: text)
    }

    private func applyTypeChip(_ chip: SearchTypeChip) {
        guard let text = session.setChip(chip, fieldText: searchField.stringValue) else { return }
        showChip(fieldText: text)
    }

    private func showChip(fieldText text: String) {
        headerView.setChip(session.query.typeChip)
        if searchField.stringValue != text {
            searchField.stringValue = text
        }
        headerView.syncSearchChrome()
        searchDebounce?.cancel()
        render(scroll: .reveal)
    }

    /// 搜索框文字 → 查询（冒号前缀会同步芯片）→ 重载列表。
    fileprivate func applySearchField() {
        session.setSearchText(searchField.stringValue)
        headerView.setChip(session.query.typeChip)
        render(scroll: .reveal)
    }
}

// MARK: - NSTableViewDataSource / Delegate

extension PanelController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { shownRows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard shownRows.indices.contains(row) else { return ClipCellView.rowHeight }
        return shownRowHeight(row)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(withIdentifier: ClipRowView.identifier, owner: nil) as? ClipRowView ?? ClipRowView()
        view.identifier = ClipRowView.identifier
        view.headerInset = shownHeader(row) != nil ? ClipCellView.groupHeaderHeight : 0
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard shownRows.indices.contains(row) else { return nil }
        let item = shownRows[row]
        let cell = ClipCellView.make(in: tableView)
        // ⌘1..⌘9 角标锚定视口前 9 行（随滚动移动）
        let badgeIndex = row - badgeAnchorRow
        let badge = cmdHeld && (0..<9).contains(badgeIndex) ? "⌘\(badgeIndex + 1)" : nil
        cell.configure(with: item, header: shownHeader(row), badge: badge, unfold: shownUnfold(for: item), maxHeight: listMaxHeight)
        cell.onEditName = { [weak self] id in self?.run(.rename, rowId: id) }
        cell.onOpenSource = { [weak self] id in self?.run(.openSource, rowId: id) }
        cell.onNameEditCommit = { [weak self] id, name in
            guard let self else { return }
            self.apply(self.session.rename(row: id, to: name))
        }
        cell.onNameEditEnd = { [weak self] in self?.endInlineNameEdit() }
        return cell
    }

    /// 用户点选（程序改选中时 render 自己同步，不走这里）。点选即停下，立刻展开；不滚动——
    /// 行只往下长，点下去的位置还在这一行上，双击不会落到别的行。
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRendering else { return }
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        session.select(row)
        session.settle()
        render()
    }

    private func run(_ command: PanelCommand, rowId: RowID) {
        guard let row = session.index(of: rowId) else { return }
        run(command, row: row)
    }
}

// MARK: - NSMenuDelegate

extension PanelController: NSMenuDelegate {
    /// 菜单项按 ItemActions 显隐：图片行没有加密/重命名，密钥行没有"标记"（也没有"取消"，见 ADR-0001）；
    /// jt 记录没有收藏 / 打开 / 原页，删除是从 jt 删。
    func menuWillOpen(_ menu: NSMenu) {
        let copyOnly = session.mode == .copyOnly
        let targetRow = menuRow().flatMap(session.row(at:))
        let target = targetRow?.clip
        let a = targetRow.map(ItemActions.available) ?? []
        for entry in menu.items {
            if let raw = entry.representedObject as? String, let action = PanelAction(rawValue: raw) {
                applyKeyEquivalent(to: entry, action)
            }
            switch entry.action {
            case #selector(pasteSecretReferenceFromMenu):
                let secret = targetRow?.isSecret == true
                entry.isHidden = !(a.contains(.pasteAsSecret) || (secret && a.contains(.paste)))
                entry.title = secret ? (copyOnly ? "复制密钥引用" : "粘贴密钥引用") : (copyOnly ? "加密并复制引用" : "加密并粘贴引用")
            case #selector(pastePlaintextFromMenu):
                entry.isHidden = !a.contains(.pastePlaintext)
                entry.title = copyOnly ? "复制明文" : "粘贴明文"
            case #selector(markSecretFromMenu):
                entry.isHidden = !a.contains(.markSecret)
            case #selector(editSecretNameFromMenu):
                entry.isHidden = !a.contains(.rename)
            case #selector(openInEditorFromMenu):
                entry.isHidden = !a.contains(.openInEditor)
            case #selector(openSourceFromMenu):
                entry.isHidden = !a.contains(.openSource) || session.expanded?.row != targetRow?.id
            case #selector(toggleFavoriteFromMenu):
                entry.isHidden = !a.contains(.toggleFavorite)
                entry.title = target?.isFavorite == true ? "取消收藏" : "收藏"
            case #selector(deleteFromMenu):
                entry.isHidden = !a.contains(.delete)
                entry.title = targetRow?.record == nil ? "删除" : "从 jt 删除"
            default:
                break
            }
        }
    }
}

// MARK: - NSTextFieldDelegate

extension PanelController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        headerView.syncSearchChrome()
        searchDebounce?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.applySearchField() }
        searchDebounce = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: task)
    }
}

// MARK: - NSWindowDelegate（失焦自动关闭，延迟来自 AppSettings）

extension PanelController: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        NSLog("[jtb] resignKey isVisible=\(isVisible)")
        guard isVisible, blurCloseEnabled else { return }
        // 用户主动点了别的 App，不要在延迟关闭后又激活唤起面板前的 App。
        let task = DispatchWorkItem { [weak self] in self?.hide(restoringPreviousApp: false) }
        blurCloseTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + AppSettings.shared.blurCloseDelay, execute: task)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        blurCloseTask?.cancel()
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// 量尺用纯色底：浅色白、暗色黑，跟随面板外观。
private final class SolidBackdropView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = (dark ? NSColor.black : NSColor.white).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// 无边框 NSPanel 默认 canBecomeKey=false，makeKey() 会变成空操作，键盘全废。
private final class ClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private enum PanelMetrics {
    static let headerHeight: CGFloat = 64
    /// Liquid Glass 时代的连续大圆角；行选中 12pt 与之同心
    static let cornerRadius: CGFloat = 28
    /// 头 / 列表之间靠留白分区，不画线；列表底部留同样的呼吸
    static let sectionGap: CGFloat = 4
    static let bottomPad: CGFloat = 10
    /// 顶栏下的提示条（vault 未同步）
    static let noticeHeight: CGFloat = 18
}

private extension NSView {
    func fittingHeight(width: CGFloat) -> CGFloat {
        guard let field = self as? NSTextField else { return fittingSize.height }
        return ceil(field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? 20)
    }
}

/// 按自身 bounds 排顶栏 / 列表 / 底栏，避免 NSGlassEffectView 改 contentView 尺寸后控件漂掉。
private final class PanelChromeHost: NSView {
    var header: NSView?
    var permissionButton: NSView?
    var empty: NSView?
    var notice: NSView?
    var scroll: NSView?

    override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height
        header?.frame = NSRect(x: 0, y: h - PanelMetrics.headerHeight, width: w, height: PanelMetrics.headerHeight)
        permissionButton?.frame = NSRect(x: w - ClipCellView.trailingMargin - 150, y: h - PanelMetrics.headerHeight + (PanelMetrics.headerHeight - 22) / 2, width: 150, height: 22)
        // 提示条贴在顶栏下、和标题对齐；隐藏时不占地方
        let noticeH = notice.map { $0.isHidden ? 0 : PanelMetrics.noticeHeight } ?? 0
        notice?.frame = NSRect(x: ClipCellView.textX, y: h - PanelMetrics.headerHeight - noticeH,
                               width: max(0, w - ClipCellView.textX - ClipCellView.trailingMargin), height: noticeH)
        let scrollY = PanelMetrics.bottomPad
        let scrollH = max(0, h - PanelMetrics.headerHeight - noticeH - PanelMetrics.sectionGap - PanelMetrics.bottomPad)
        scroll?.frame = NSRect(x: 0, y: scrollY, width: w, height: scrollH)
        // 空态最多三行（jt 报错可能长），垂直居中在列表区
        let inset: CGFloat = 24
        let emptyW = max(0, w - inset * 2)
        let emptyH = min(60, max(20, empty?.fittingHeight(width: emptyW) ?? 20))
        empty?.frame = NSRect(x: inset, y: scrollY + max(0, scrollH - emptyH) / 2, width: emptyW, height: emptyH)
    }
}
