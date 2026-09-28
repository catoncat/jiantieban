import Carbon.HIToolbox
import Foundation

/// Carbon 全局热键（Cmd+Shift+V 等），零依赖替代 KeyboardShortcuts 库。
/// 用法：HotkeyCenter.register(modifiers: [.command, .shift], keyCode: kVK_ANSI_V) { ... }
@MainActor
public final class HotkeyCenter {
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: UInt32(cmdKey))
        public static let shift = Modifiers(rawValue: UInt32(shiftKey))
        public static let option = Modifiers(rawValue: UInt32(optionKey))
        public static let control = Modifiers(rawValue: UInt32(controlKey))
    }

    private struct Registration {
        var ref: EventHotKeyRef?
        var id: UInt32
        var action: () -> Void
    }

    private var registrations: [UInt32: Registration] = [:]
    private var nextID: UInt32 = 1
    private var eventHandlerInstalled = false
    private var eventHandlerRef: EventHandlerRef?

    public init() {}

    /// 注册全局热键，返回句柄 id 供注销
    @discardableResult
    public func register(modifiers: Modifiers, keyCode: UInt32, action: @escaping () -> Void) -> UInt32 {
        installEventHandlerIfNeeded()

        let id = nextID
        nextID += 1
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = 0x4A5442 // 'JTB'
        hotKeyID.id = id

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers.rawValue, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            FileHandle.standardError.write("RegisterEventHotKey failed: \(status)\n".data(using: .utf8)!)
            return 0
        }
        registrations[id] = Registration(ref: ref, id: id, action: action)
        return id
    }

    public func unregister(_ id: UInt32) {
        guard let reg = registrations.removeValue(forKey: id), let ref = reg.ref else { return }
        UnregisterEventHotKey(ref)
    }

    fileprivate func fire(_ id: UInt32) {
        registrations[id]?.action()
    }

    private func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        eventHandlerInstalled = true

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { center.fire(hotKeyID.id) }
            return noErr
        }, 1, &eventType, selfPtr, &eventHandlerRef)
    }
}
