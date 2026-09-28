import AppKit

@MainActor
enum PastebackToast {
    private static var window: NSPanel?

    static func show(_ message: String) {
        window?.orderOut(nil)

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.sizeToFit()

        let width = max(220, label.frame.width + 40)
        let height: CGFloat = 44
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 8
        effect.layer?.masksToBounds = true
        label.frame = NSRect(x: 20, y: 13, width: width - 40, height: 18)
        effect.addSubview(label)
        panel.contentView = effect

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let screen {
            panel.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.midX - width / 2,
                y: screen.visibleFrame.minY + 80
            ))
        }

        window = panel
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        Motion.run(Motion.toastIn) { panel.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            guard window === panel else { return }
            window = nil
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = Motion.toastOut
                panel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated { panel.orderOut(nil) } // AppKit 在主线程回调
            })
        }
    }
}
