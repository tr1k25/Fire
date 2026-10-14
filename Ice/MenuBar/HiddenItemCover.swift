//
//  HiddenItemCover.swift
//  Ice
//

import ApplicationServices
import Cocoa
import Combine
import ScreenCaptureKit

/// Hides menu bar items on macOS versions where the items can no longer be pushed
/// out of the menu bar (macOS 27: items are hosted by `MenuBarAgent` and have no
/// windows that other processes can see or move).
///
/// Items to the left of the Fire icon are located through the accessibility API and
/// covered with small panels that reproduce the menu bar background.
///
/// The class also exposes the list of items it found, so that the settings and the search
/// panel can show them, and it can move items by performing a Command + drag.
@MainActor
final class HiddenItemCover: ObservableObject {
    /// An item in the menu bar, found through the accessibility API.
    struct Item: Identifiable, Equatable {
        let id: String
        let pid: pid_t
        let index: Int
        let frame: CGRect
        let title: String
        let appName: String
        let bundleIdentifier: String?
        let isSystem: Bool
        let element: AXUIElement

        var displayName: String {
            title.isEmpty || title == appName ? appName : "\(appName) – \(title)"
        }

        var icon: NSImage? {
            NSRunningApplication(processIdentifier: pid)?.icon
        }

        static func == (lhs: Item, rhs: Item) -> Bool {
            lhs.id == rhs.id && lhs.frame == rhs.frame && lhs.title == rhs.title
        }
    }

    /// The menu bar items of other apps and the system, from left to right.
    @Published private(set) var items = [Item]()

    /// The left edge of the Fire icon in CoreGraphics coordinates.
    @Published private(set) var delimiter: CGFloat?

    /// A Boolean value that indicates whether an item is currently being moved.
    @Published private(set) var isMovingItem = false

    private weak var appState: AppState?
    private var cancellables = Set<AnyCancellable>()
    private var pollTask: Task<Void, Never>?
    private var panels = [CoverPanel]()
    private var cachedItems = [Item]()
    private var isCovering = false
    /// Left edge of the Ice icon while the items are hidden. The icon is wider in this state, so
    /// its left edge sits further to the left than in the shown state.
    private var hiddenStateDelimiterX: CGFloat?
    private var lastGoodRuns = [CGRect]()
    private var emptyStreak = 0
    private var backgroundCache = [String: (date: Date, top: CGImage, bottom: CGImage)]()

    init(appState: AppState) {
        self.appState = appState
    }

    /// The frames of all menu bar items known through the accessibility API, plus Ice's own items.
    /// The coordinates are in the CoreGraphics coordinate space (origin at the top left).
    var allItemFrames: [CGRect] {
        var frames = cachedItems.map(\.frame)
        if let appState {
            for section in appState.menuBarManager.sections {
                if let frame = section.controlItem.window?.frame, frame.width > 0 {
                    frames.append(CGRect(x: frame.minX, y: 0, width: frame.width, height: barHeight))
                }
            }
        }
        return frames
    }

    func performSetup() {
        guard let appState, let hiddenSection = appState.menuBarManager.section(withName: .hidden) else {
            return
        }
        hiddenSection.controlItem.$state
            .sink { [weak self] state in
                guard let self else { return }
                isCovering = state == .hideItems
                lastStateChange = .now
                refreshPanels()
                // Beim Umschalten ändert sich die Breite des Ice-Symbols und die Items
                // verschieben sich. Schnell nachscannen, bis das Layout stabil ist.
                for delay in [0.03, 0.06, 0.1, 0.15, 0.2, 0.3, 0.4, 0.55, 0.75, 1.0, 1.4] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        self?.refreshPanels()
                    }
                }
                for delay in [0.1, 0.3, 0.7] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        self?.scanNow()
                    }
                }
            }
            .store(in: &cancellables)

        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: name)
                .delay(for: 0.4, scheduler: DispatchQueue.main)
                .sink { [weak self] _ in self?.scanNow() }
                .store(in: &cancellables)
        }

        // The cover reproduces the menu bar, including tint and shadow of the appearance settings.
        appState.appearanceManager.$configuration
            .dropFirst()
            .debounce(for: 0.3, scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.backgroundCache.removeAll()
                self?.refreshPanels()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                self?.backgroundCache.removeAll()
                self?.scanNow()
            }
            .store(in: &cancellables)

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.scan()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    deinit {
        pollTask?.cancel()
    }

    // MARK: Scanning

    private func scanNow() {
        Task { await scan() }
    }

    /// Rescans the menu bar items right now and waits for the result.
    func refresh() async {
        await scan()
    }

    /// Returns a readable name for a system menu bar item identifier like `com.apple.menuextra.wifi`.
    private static func systemItemName(for identifier: String) -> String {
        guard !identifier.isEmpty else {
            return "System"
        }
        let key = identifier.split(separator: ".").last.map(String.init) ?? identifier
        let names = [
            "wifi": "Wi-Fi",
            "bluetooth": "Bluetooth",
            "clock": "Clock",
            "controlcenter": "Control Center",
            "now-playing": "Now Playing",
            "battery": "Battery",
            "airplay": "AirPlay",
            "airdrop": "AirDrop",
            "focus": "Focus",
            "display": "Display",
            "sound": "Sound",
            "spotlight": "Spotlight",
            "siri": "Siri",
            "textinput": "Input Menu",
            "vpn": "VPN",
            "timemachine": "Time Machine",
            "user": "Fast User Switching",
            "screentime": "Screen Time",
            "keyboard": "Keyboard Brightness",
            "stage-manager": "Stage Manager",
            "weather": "Weather",
        ]
        if let name = names[key.lowercased()] {
            return name
        }
        return key.replacingOccurrences(of: "-", with: " ").capitalized
    }

    private struct RawItem {
        let pid: pid_t
        let index: Int
        let frame: CGRect
        let title: String
        let element: AXUIElement
    }

    private func scan() async {
        guard AXIsProcessTrusted() else {
            return
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter {
                $0.processIdentifier != ownPID &&
                ($0.activationPolicy != .prohibited || $0.bundleIdentifier == "com.apple.MenuBarAgent")
            }
            .map(\.processIdentifier)
        let raw = await Task.detached(priority: .utility) { () -> [RawItem] in
            var result = [RawItem]()
            func string(_ element: AXUIElement, _ attribute: String) -> String? {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
                    return nil
                }
                return value as? String
            }
            for pid in apps {
                let element = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(element, 0.3)
                var bar: CFTypeRef?
                guard
                    AXUIElementCopyAttributeValue(element, "AXExtrasMenuBar" as CFString, &bar) == .success,
                    let bar
                else {
                    continue
                }
                var children: CFTypeRef?
                guard
                    AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
                    let children = children as? [AXUIElement]
                else {
                    continue
                }
                for (index, child) in children.enumerated() {
                    var position: CFTypeRef?
                    var size: CFTypeRef?
                    AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &position)
                    AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &size)
                    var point = CGPoint.zero
                    var extent = CGSize.zero
                    guard
                        let position, let size,
                        AXValueGetValue(position as! AXValue, .cgPoint, &point),
                        AXValueGetValue(size as! AXValue, .cgSize, &extent),
                        extent.width > 0, extent.height > 0
                    else {
                        continue
                    }
                    var title = string(child, kAXTitleAttribute)
                        ?? string(child, kAXDescriptionAttribute)
                        ?? string(child, kAXHelpAttribute)
                        ?? ""
                    if title.isEmpty {
                        // System items are hosted in a group; the identifier is on the first child.
                        var grandChildren: CFTypeRef?
                        if
                            AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &grandChildren) == .success,
                            let first = (grandChildren as? [AXUIElement])?.first
                        {
                            title = string(first, kAXIdentifierAttribute)
                                ?? string(first, kAXTitleAttribute)
                                ?? string(first, kAXDescriptionAttribute)
                                ?? ""
                        }
                    }
                    result.append(RawItem(
                        pid: pid,
                        index: index,
                        frame: CGRect(origin: point, size: extent),
                        title: title,
                        element: child
                    ))
                }
            }
            return result
        }.value

        var seenPerApp = [pid_t: Int]()
        let height = barHeight
        let mapped: [Item] = raw
            .filter { $0.frame.minY < height && $0.frame.maxY > 0 }
            .sorted { $0.frame.minX < $1.frame.minX }
            .map { item in
                let app = NSRunningApplication(processIdentifier: item.pid)
                let bundleID = app?.bundleIdentifier
                let isSystem = bundleID == "com.apple.MenuBarAgent"
                var name = app?.localizedName ?? "Unknown"
                var title = item.title
                if isSystem {
                    name = Self.systemItemName(for: title)
                    title = ""
                } else {
                    seenPerApp[item.pid, default: 0] += 1
                    if title.isEmpty, seenPerApp[item.pid, default: 0] > 1 {
                        title = "Item \(seenPerApp[item.pid, default: 0])"
                    }
                }
                return Item(
                    id: "\(item.pid)#\(item.index)",
                    pid: item.pid,
                    index: item.index,
                    frame: item.frame,
                    title: title,
                    appName: name,
                    bundleIdentifier: bundleID,
                    isSystem: isSystem,
                    element: item.element
                )
            }
        if mapped != cachedItems {
            items = mapped
        }
        cachedItems = mapped
        refreshPanels()
    }

    // MARK: Actions

    /// A Boolean value that indicates whether the item is on the hidden side of the Fire icon.
    func isHidden(_ item: Item) -> Bool {
        guard let delimiter else {
            return false
        }
        return item.frame.maxX <= delimiter + 1
    }

    /// Opens the menu of the item, as if it had been clicked.
    @discardableResult
    func open(_ item: Item) -> Bool {
        AXUIElementPerformAction(item.element, kAXPressAction as CFString) == .success
    }

    /// Hides or shows the item by moving it to the other side of the Fire icon.
    ///
    /// This performs a Command + drag with synthetic mouse events and checks the result with the
    /// accessibility API. It retries with different drop positions.
    func setHidden(_ hide: Bool, for item: Item) async -> Bool {
        guard
            AXIsProcessTrusted(),
            let appState,
            let iconFrame = appState.menuBarManager.section(withName: .visible)?.controlItem.window?.frame,
            iconFrame.width > 0
        else {
            return false
        }
        guard !isMovingItem else {
            return false
        }
        isMovingItem = true
        refreshPanels()
        defer {
            isMovingItem = false
            refreshPanels()
        }
        // Give the cover a moment to disappear.
        try? await Task.sleep(for: .milliseconds(150))

        let offsets: [CGFloat] = [6, 22, 40]
        for offset in offsets {
            await scan()
            guard let current = cachedItems.first(where: { $0.id == item.id }) else {
                return false
            }
            if hide, current.frame.maxX <= iconFrame.minX + 1 { return true }
            if !hide, current.frame.minX >= iconFrame.minX + 8 { return true }

            let targetX = hide ? iconFrame.minX - offset : iconFrame.maxX + offset
            await commandDrag(from: CGPoint(x: current.frame.midX, y: barHeight / 2), toX: targetX)
            try? await Task.sleep(for: .milliseconds(350))
            await scan()
            if let moved = cachedItems.first(where: { $0.id == item.id }) {
                if hide, moved.frame.maxX <= iconFrame.minX + 1 { return true }
                if !hide, moved.frame.minX >= iconFrame.minX + 8 { return true }
            }
        }
        return false
    }

    /// Performs a Command + drag from the given point horizontally to the target x position.
    private func commandDrag(from start: CGPoint, toX endX: CGFloat) async {
        let savedLocation = CGEvent(source: nil)?.location ?? .zero
        let source = CGEventSource(stateID: .hidSystemState)

        func post(_ type: CGEventType, x: CGFloat) {
            let event = CGEvent(
                mouseEventSource: source,
                mouseType: type,
                mouseCursorPosition: CGPoint(x: x, y: start.y),
                mouseButton: .left
            )
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }

        post(.mouseMoved, x: start.x)
        try? await Task.sleep(for: .milliseconds(80))
        post(.leftMouseDown, x: start.x)
        try? await Task.sleep(for: .milliseconds(80))
        let steps = 24
        for step in 1...steps {
            post(.leftMouseDragged, x: start.x + (endX - start.x) * CGFloat(step) / CGFloat(steps))
            try? await Task.sleep(for: .milliseconds(16))
        }
        try? await Task.sleep(for: .milliseconds(120))
        post(.leftMouseUp, x: endX)
        try? await Task.sleep(for: .milliseconds(150))
        CGWarpMouseCursorPosition(savedLocation)
    }

    // MARK: Panels

    private var barHeight: CGFloat {
        guard let screen = NSScreen.main else {
            return 30
        }
        let height = screen.frame.maxY - screen.visibleFrame.maxY
        return height >= 20 ? height : 30
    }

    private var lastLiveDelimiterX: CGFloat?
    private var lastStateChange = Date.distantPast

    /// The live left edge of the Ice icon, or `nil` while its window has no sensible frame.
    private var liveDelimiterX: CGFloat? {
        guard
            let appState,
            let visibleSection = appState.menuBarManager.section(withName: .visible),
            let frame = visibleSection.controlItem.window?.frame,
            frame.width > 4,
            frame.minX > 200
        else {
            return nil
        }
        return frame.minX
    }

    /// The x position of the Ice icon, which separates hidden from visible items.
    ///
    /// The Ice icon changes its width when the items are shown or hidden, and its window frame
    /// lags behind the change. While the frame is still moving, the last settled value for the
    /// hidden state is used, so the cover never overlaps the icon or leaves its edge exposed.
    private var delimiterX: CGFloat? {
        guard let live = liveDelimiterX else {
            return hiddenStateDelimiterX
        }
        // Right after a toggle the icon's frame still has its old value; do not treat it as settled.
        let settled = lastLiveDelimiterX == live && Date.now.timeIntervalSince(lastStateChange) > 0.6
        lastLiveDelimiterX = live
        if isCovering {
            if settled || hiddenStateDelimiterX == nil {
                hiddenStateDelimiterX = live
                return live
            }
            return hiddenStateDelimiterX
        }
        return live
    }

    /// The area that is (or would be) covered: everything between the leftmost hidden item and
    /// the Ice icon. The area is contiguous and slightly oversized, so small layout shifts while
    /// the Ice icon changes its width never expose parts of hidden items.
    private func plannedRuns() -> [CGRect] {
        guard let delimiterX, let screen = NSScreen.main else {
            return []
        }
        let height = barHeight
        let candidates = cachedItems
            .filter { !$0.isSystem }
            .map(\.frame)
            .filter { frame in
                frame.minY < height &&
                frame.maxX <= delimiterX + 1 &&
                frame.minX >= screen.frame.minX
            }
        guard let leftmost = candidates.map(\.minX).min() else {
            return []
        }
        // Leave room for small layout shifts, but never cover the application menus.
        var lowerBound = screen.frame.minX
        if let displayID = Optional(screen.displayID),
           let menuFrame = appState?.menuBarManager.getApplicationMenuFrame(for: displayID) {
            lowerBound = max(lowerBound, menuFrame.maxX + 6)
        }
        let minX = max(lowerBound, leftmost - 48)
        let maxX = delimiterX - 1
        guard maxX > minX else {
            return []
        }
        return [CGRect(x: minX, y: 0, width: maxX - minX, height: height)]
    }

    private func refreshPanels() {
        guard let screen = NSScreen.main else {
            return
        }
        let currentDelimiter = delimiterX
        if delimiter != currentDelimiter {
            delimiter = currentDelimiter
        }
        var runs = plannedRuns()
        if runs.isEmpty {
            // Transient gaps (accessibility timeouts, layout in motion) must not expose items.
            emptyStreak += 1
            if isCovering, emptyStreak < 5 {
                runs = lastGoodRuns
            }
        } else {
            emptyStreak = 0
            lastGoodRuns = runs
        }
        while panels.count > runs.count {
            panels.removeLast().close()
        }
        while panels.count < runs.count {
            panels.append(CoverPanel())
        }
        for (panel, run) in zip(panels, runs) {
            let frame = CGRect(x: run.minX, y: screen.frame.maxY - run.height, width: run.width, height: run.height)
            if panel.frame != frame {
                panel.setFrame(frame, display: true)
            }
            // The background is prepared in advance, so the cover looks right the moment it appears.
            updateBackground(for: panel, run: run)
            // Panels stay ordered in and are switched by transparency; ordering windows in and out
            // can show one unpainted frame.
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
            let covers = isCovering && !isMovingItem
            panel.alphaValue = covers ? 1 : 0
            panel.ignoresMouseEvents = !covers
        }
    }

    private func updateBackground(for panel: CoverPanel, run: CGRect) {
        let key = "\(Int(run.minX / 8)):\(Int(run.width / 8)):\(Int(run.height))"
        if let cached = backgroundCache[key], Date.now.timeIntervalSince(cached.date) < 20 {
            panel.coverView.setBackground(top: cached.top, bottom: cached.bottom)
            return
        }
        let ownWindowIDs = Set(panels.map(\.windowNumber).filter { $0 > 0 }.map { CGWindowID($0) })
        Task { [weak self, weak panel] in
            do {
                let content = try await SCShareableContent.current
                guard
                    let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first
                else {
                    return
                }
                let excluded = content.windows.filter { ownWindowIDs.contains($0.windowID) }
                let filter = SCContentFilter(display: display, excludingWindows: excluded)
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                let configuration = SCStreamConfiguration()
                configuration.sourceRect = run
                configuration.width = max(1, Int(run.width * scale))
                configuration.height = max(1, Int(run.height * scale))
                configuration.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                let band = max(2, Int(2 * scale))
                guard
                    image.height > band * 2,
                    let top = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: band)),
                    let bottom = image.cropping(to: CGRect(x: 0, y: image.height - band, width: image.width, height: band))
                else {
                    return
                }
                await MainActor.run {
                    self?.backgroundCache[key] = (.now, top, bottom)
                    panel?.coverView.setBackground(top: top, bottom: bottom)
                }
            } catch {
                Logger.hiddenItemCover.error("Cover background capture failed: \(error)")
            }
        }
    }
}

// MARK: - CoverPanel

private final class CoverPanel: NSPanel {
    let coverView = CoverView()

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        backgroundColor = .clear
        isOpaque = true
        hasShadow = false
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        contentView = coverView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class CoverView: NSView {
    private var top: CGImage?
    private var bottom: CGImage?

    func setBackground(top: CGImage, bottom: CGImage) {
        self.top = top
        self.bottom = bottom
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        guard let top, let bottom else {
            NSColor(calibratedWhite: 0.2, alpha: 1).setFill()
            bounds.fill()
            return
        }
        let half = bounds.height / 2
        context.interpolationQuality = .high
        context.draw(top, in: CGRect(x: 0, y: half, width: bounds.width, height: bounds.height - half))
        context.draw(bottom, in: CGRect(x: 0, y: 0, width: bounds.width, height: half))
    }

    // Absorb clicks so that hidden items below cannot be activated.
    override func mouseDown(with event: NSEvent) { }
    override func rightMouseDown(with event: NSEvent) { }
}

private extension Logger {
    static let hiddenItemCover = Logger(category: "HiddenItemCover")
}
