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
/// Items to the left of the Ice icon are located through the accessibility API and
/// covered with small panels that reproduce the menu bar background.
@MainActor
final class HiddenItemCover {
    private struct ItemRect: Equatable {
        let pid: pid_t
        let frame: CGRect
    }

    private weak var appState: AppState?
    private var cancellables = Set<AnyCancellable>()
    private var pollTask: Task<Void, Never>?
    private var panels = [CoverPanel]()
    private var cachedItems = [ItemRect]()
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
        let items = await Task.detached(priority: .utility) { () -> [ItemRect] in
            var result = [ItemRect]()
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
                for child in children {
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
                    result.append(ItemRect(pid: pid, frame: CGRect(origin: point, size: extent)))
                }
            }
            return result
        }.value
        cachedItems = items
        refreshPanels()
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
            .map(\.frame)
            .filter { frame in
                frame.minY < height &&
                frame.maxX <= delimiterX + 1 &&
                frame.minX >= screen.frame.minX
            }
        guard let leftmost = candidates.map(\.minX).min() else {
            return []
        }
        let minX = max(screen.frame.minX, leftmost - 24)
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
            panel.alphaValue = isCovering ? 1 : 0
            panel.ignoresMouseEvents = !isCovering
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
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
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
