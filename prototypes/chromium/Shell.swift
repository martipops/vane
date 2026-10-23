import AppKit
import Combine
import SwiftUI

// The shell deliberately mirrors Vane's 228-point sidebar and 10-point page rim.
// This is an engine spike, not a second implementation of Spaces or profiles.
@MainActor final class PrototypePage: ObservableObject, Identifiable {
    let id = UUID()
    var token: Int32 = 0
    let initialURL: String
    @Published var url: String
    @Published var title = "New Tab"
    @Published var loading = true
    @Published var back = false
    @Published var forward = false

    init(url: String) { self.initialURL = url; self.url = url }
}

@MainActor final class PrototypeModel: ObservableObject {
    static let shared = PrototypeModel()
    @Published var pages: [PrototypePage] = []
    @Published var batterySaver = false
    @Published var selection: UUID? {
        didSet { if let page = active { VaneSelectBrowser(page.token) } }
    }
    // Keep closing tab state until CEF acknowledges browser destruction.
    var closing: [Int32: PrototypePage] = [:]
    var active: PrototypePage? { pages.first { $0.id == selection } }
    var windows: [Int32: NSWindow] = [:]
    let actions = ShellActions()

    func add(_ url: String? = nil) {
        let page = PrototypePage(url: url ?? String(cString: VaneStartupURL()))
        page.token = page.initialURL.withCString { VaneCreateBrowser($0) }
        if page.token == 0 { page.title = "Couldn’t create Chromium tab"; page.loading = false }
        pages.append(page)
        selection = page.id
    }

    func close(_ page: PrototypePage) {
        let index = pages.firstIndex { $0.id == page.id } ?? 0
        if page.token != 0 { closing[page.token] = page; VaneCloseBrowser(page.token) }
        pages.removeAll { $0.id == page.id }
        if selection == page.id {
            selection = pages.isEmpty ? nil : pages[min(index, pages.count - 1)].id
        }
        if pages.isEmpty { add() }
    }

    func find(_ token: Int32) -> PrototypePage? {
        pages.first { $0.token == token } ?? closing[token]
    }
}

private struct PageRow: View {
    @ObservedObject var page: PrototypePage
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Button(action: select) {
                HStack(spacing: 9) {
                    Image(systemName: page.loading ? "hourglass" : "globe")
                        .frame(width: 18).foregroundStyle(.secondary)
                    Text(page.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 10)) }
                .buttonStyle(.plain).help("Close tab").accessibilityLabel("Close \(page.title)")
        }
        .padding(.horizontal, 10).frame(height: 36)
        .background(selected ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}

private struct PrototypeShell: View {
    @ObservedObject var model: PrototypeModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var motion: Animation? {
        reduceMotion || model.batterySaver || ProcessInfo.processInfo.isLowPowerModeEnabled
            ? nil : .easeInOut(duration: 0.18)
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Vane").font(.system(size: 23, weight: .semibold))
                    Text("Chromium Prototype").font(.system(size: 12)).foregroundStyle(.secondary)
                }.padding(.top, 18).padding(.horizontal, 12)
                Button { withAnimation(motion) { model.add() } } label: {
                    Label("New Tab", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain).padding(12)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(model.pages) { page in
                            PageRow(page: page, selected: page.id == model.selection,
                                select: { withAnimation(motion) { model.selection = page.id } },
                                close: { withAnimation(motion) { model.close(page) } })
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 13) {
                    shortcut("Extensions", icon: "puzzlepiece.extension", url: "chrome://extensions/")
                    shortcut("Web Store", icon: "bag", url: "https://chromewebstore.google.com/")
                    shortcut("Playback Check", icon: "play.rectangle", url: "vane:playback")
                    Toggle("Battery Saver", isOn: $model.batterySaver).toggleStyle(.checkbox).font(.system(size: 12))
                }.padding(.horizontal, 10)
                Text("Separate test profile").font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.bottom, 8)
            }
            .padding(12).frame(width: 228).background(Color(nsColor: .windowBackgroundColor))
            Color.clear
        }
        .frame(minWidth: 850, minHeight: 580)
    }
    private func shortcut(_ title: String, icon: String, url: String) -> some View {
        Button {
            let destination = url == "vane:playback"
                ? Bundle.main.url(forResource: "playback", withExtension: "html")!.absoluteString : url
            withAnimation(motion) { model.add(destination) }
        } label: { Label(title, systemImage: icon).font(.system(size: 13)) }
        .buttonStyle(.plain)
    }
}

@MainActor final class ShellActions: NSObject, NSApplicationDelegate {
    @objc func newTab() { PrototypeModel.shared.add() }
    @objc func closeTab() { if let page = PrototypeModel.shared.active { PrototypeModel.shared.close(page) } }
    @objc func focusAddress() { if let page = PrototypeModel.shared.active { VaneFocusAddress(page.token) } }
    @objc func reload() { if let page = PrototypeModel.shared.active { VaneReload(page.token) } }
    @objc func revealProfile() { NSWorkspace.shared.open(URL(fileURLWithPath: String(cString: VaneProfilePath()))) }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

// The transparent page slot lets mouse events reach Chromium's Views hierarchy.
@MainActor private final class ShellHostingView: NSHostingView<PrototypeShell> {
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if local.x >= 228 { return nil }
        return super.hitTest(point)
    }
}

@MainActor @_cdecl("VaneStart")
func start() {
    MainActor.assumeIsolated {
        let model = PrototypeModel.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.delegate = model.actions
        let menu = NSMenu()
        func section(_ title: String) -> NSMenu {
            let item = NSMenuItem(); menu.addItem(item)
            let submenu = NSMenu(title: title); item.submenu = submenu; return submenu
        }
        func action(_ menu: NSMenu, _ title: String, _ selector: Selector, _ key: String, target: AnyObject?) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = target; menu.addItem(item)
        }
        let appMenu = section("Vane Chromium Prototype")
        action(appMenu, "Show Prototype Data…", #selector(ShellActions.revealProfile), "", target: model.actions)
        appMenu.addItem(.separator())
        action(appMenu, "Quit Vane Chromium Prototype", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        let file = section("File")
        action(file, "New Tab", #selector(ShellActions.newTab), "t", target: model.actions)
        action(file, "Close Tab", #selector(ShellActions.closeTab), "w", target: model.actions)
        let edit = section("Edit")
        action(edit, "Undo", Selector(("undo:")), "z", target: nil)
        action(edit, "Cut", #selector(NSText.cut(_:)), "x", target: nil)
        action(edit, "Copy", #selector(NSText.copy(_:)), "c", target: nil)
        action(edit, "Paste", #selector(NSText.paste(_:)), "v", target: nil)
        action(edit, "Select All", #selector(NSText.selectAll(_:)), "a", target: nil)
        let view = section("View")
        action(view, "Open Address", #selector(ShellActions.focusAddress), "l", target: model.actions)
        action(view, "Reload", #selector(ShellActions.reload), "r", target: model.actions)
        NSApp.mainMenu = menu
        model.add()
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor @_cdecl("VaneCreateWindow")
func createWindow(_ nativeView: UnsafeMutableRawPointer, _ token: Int32) {
    MainActor.assumeIsolated {
        let model = PrototypeModel.shared
        let native = Unmanaged<NSView>.fromOpaque(nativeView).takeUnretainedValue()
        let window = native.window!
        let shell = ShellHostingView(rootView: PrototypeShell(model: model))
        shell.frame = native.bounds
        shell.autoresizingMask = [.width, .height]
        native.addSubview(shell)
        model.windows[token] = window
    }
}

@_cdecl("VaneBrowserChanged")
func browserChanged(_ token: Int32, _ url: UnsafePointer<CChar>, _ title: UnsafePointer<CChar>,
                    _ loading: Bool, _ back: Bool, _ forward: Bool) {
    let address = String(cString: url), name = String(cString: title)
    // Defer state publication out of AppKit/CEF view callbacks.
    DispatchQueue.main.async {
        guard let page = PrototypeModel.shared.find(token) else { return }
        page.url = address
        if !name.isEmpty { page.title = name }
        page.loading = loading; page.back = back; page.forward = forward
    }
}

@_cdecl("VaneBrowserClosed")
func browserClosed(_ token: Int32) {
    DispatchQueue.main.async {
        let model = PrototypeModel.shared
        model.closing[token] = nil
        if let page = model.pages.first(where: { $0.token == token }) {
            model.pages.removeAll { $0.token == token }
            if model.selection == page.id { model.selection = model.pages.first?.id }
        }
    }
}

@_cdecl("VaneWindowClosed")
func windowClosed(_ token: Int32) {
    MainActor.assumeIsolated { PrototypeModel.shared.windows[token] = nil }
}
