import Carbon.HIToolbox
import Foundation

/// 输入法切换：显示面板时切到 ABC，关闭时恢复。
@MainActor
final class InputSourceSwitcher {
    private var savedSource: TISInputSource?

    func saveAndSwitchToEnglish() {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return }
        guard let sourceID = current.sourceID, sourceID != "com.apple.keylayout.ABC" else { return }

        savedSource = current
        if let abc = Self.findSource(id: "com.apple.keylayout.ABC") {
            TISSelectInputSource(abc)
        }
    }

    func restore() {
        guard let saved = savedSource else { return }
        savedSource = nil
        TISSelectInputSource(saved)
    }

    private static func findSource(id: String) -> TISInputSource? {
        guard let list = TISCreateInputSourceList(
            [kTISPropertyInputSourceID: id] as CFDictionary, false
        )?.takeRetainedValue() as? [TISInputSource] else { return nil }
        return list.first
    }
}

private extension TISInputSource {
    var sourceID: String? {
        guard let ptr = TISGetInputSourceProperty(self, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }
}
