import AppKit
import WebKit

/// Who took the screen. A fullscreen page owns every pixel, including where the address
/// bar used to be, so it can draw a convincing fake one; this names the real site and the
/// way out, over the page, for a few seconds after it goes fullscreen.
@MainActor enum FullscreenNotice {
    private static var panel: NSPanel?
    private static var dismissal: DispatchWorkItem?

    static func show(site: String?, over web: WKWebView) {
        hide()
        guard let screen = web.window?.screen ?? NSScreen.main else { return }
        let label = NSTextField(labelWithString: "\(site ?? "This page") is full screen · Press Esc to exit")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.setAccessibilityRole(.staticText)
        let size = label.fittingSize
        let frame = NSRect(x: screen.frame.midX - (size.width + 32) / 2,
                           y: screen.frame.maxY - size.height - 16 - 48,
                           width: size.width + 32, height: size.height + 16)
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = frame.height / 2
        label.frame = NSRect(x: 16, y: 8, width: size.width, height: size.height)
        blur.addSubview(label)
        p.contentView = blur
        panel = p
        let reduced = CustomPiPWindow.reducesMotion
        p.alphaValue = reduced ? 1 : 0
        p.orderFrontRegardless()
        if !reduced { NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 } }
        NSAccessibility.post(element: p, notification: .announcementRequested,
                             userInfo: [.announcement: label.stringValue, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        let work = DispatchWorkItem { hide() }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
    }

    static func hide() {
        dismissal?.cancel(); dismissal = nil
        guard let p = panel else { return }
        panel = nil
        if CustomPiPWindow.reducesMotion { p.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; p.animator().alphaValue = 0 },
                                             completionHandler: { p.orderOut(nil) })
    }
}
