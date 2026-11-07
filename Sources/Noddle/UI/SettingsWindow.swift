import AppKit
import NoddleCore

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let split = SettingsSplit()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Noddle"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 900, height: 620)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1000, height: 680))
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func present(page: String?) {
        NSApp.setActivationPolicy(.regular)
        AppController.shared.isObserved = true
        if let page { split.select(page) }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// `--snapshot <dir>`: saves every page as a PNG, for docs and visual checks.
    func snapshotAll(to directory: String, ids: [String], then done: @escaping () -> Void) {
        guard let id = ids.first else { return snapshotRecording(to: directory, then: done) }
        split.select(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let view = self.window?.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return done() }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(directory)/\(id).png"))
                self.snapshotAll(to: directory, ids: Array(ids.dropFirst()), then: done)
            }
        }
    }

    private func snapshotRecording(to directory: String, then done: @escaping () -> Void) {
        let window = NSWindow(contentViewController: RecordSheet(target: nil, modeID: Mode.pointerID))
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 14) {
            MainActor.assumeIsolated {
                if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(directory)/record.png"))
                }
                done()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        AppController.shared.isObserved = false
        AppController.shared.saveNow()
        NSApp.setActivationPolicy(.accessory)
    }
}

private struct PageEntry {
    var id: String
    var title: String
    var symbol: String
    var make: @MainActor () -> Page
}

@MainActor
private final class SettingsSplit: NSSplitViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let entries: [PageEntry] = [
        PageEntry(id: "overview", title: L("总览", "Overview"), symbol: "person.crop.circle") { OverviewPage() },
        PageEntry(id: "gestures", title: L("动作与映射", "Gestures"), symbol: "hand.point.up.left") { GesturesPage() },
        PageEntry(id: "feel", title: L("手感", "Feel"), symbol: "slider.horizontal.3") { FeelPage() },
        PageEntry(id: "calibrate", title: L("校准", "Calibrate"), symbol: "scope") { CalibratePage() },
        PageEntry(id: "apps", title: L("应用配置", "Apps"), symbol: "square.grid.2x2") { AppsPage() },
        PageEntry(id: "permissions", title: L("权限与隐私", "Permissions"), symbol: "lock.shield") { PermissionsPage() },
        PageEntry(id: "advanced", title: L("高级", "Advanced"), symbol: "gearshape") { AdvancedPage() },
    ]
    private let table = NSTableView()
    private let holder = NSViewController()
    private var pages: [String: Page] = [:]
    private var current: Page?

    override func viewDidLoad() {
        super.viewDidLoad()
        table.addTableColumn(NSTableColumn(identifier: .init("page")))
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 32
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        let sidebarController = NSViewController()
        sidebarController.view = scroll

        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebar.minimumThickness = 196
        sidebar.maximumThickness = 196
        sidebar.canCollapse = false
        addSplitViewItem(sidebar)

        holder.view = NSView()
        let content = NSSplitViewItem(viewController: holder)
        content.minimumThickness = 660
        addSplitViewItem(content)

        table.reloadData()
        table.selectRowIndexes([0], byExtendingSelection: false)
    }

    func select(_ id: String) {
        _ = view
        if let i = entries.firstIndex(where: { $0.id == id }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let icon = NSImageView(image: NSImage(systemSymbolName: entries[row].symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        let stack = hstack([icon, text(entries[row].title)], spacing: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0 else { return }
        let entry = entries[table.selectedRow]
        let page = pages[entry.id] ?? entry.make()
        pages[entry.id] = page
        guard page !== current else { return }
        if let current {
            current.view.removeFromSuperview()
            current.removeFromParent()
        }
        holder.addChild(page)
        page.view.frame = holder.view.bounds
        page.view.autoresizingMask = [.width, .height]
        holder.view.addSubview(page.view)
        current = page
    }
}
