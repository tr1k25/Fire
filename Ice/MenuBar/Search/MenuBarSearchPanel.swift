//
//  MenuBarSearchPanel.swift
//  Fire
//

import Combine
import SwiftUI

/// A panel that contains the menu bar search interface.
///
/// The panel lists the menu bar items found through the accessibility API and opens the menu
/// of the item the user picks.
final class MenuBarSearchPanel: NSPanel {
    /// The default screen to show the panel on.
    static var defaultScreen: NSScreen? {
        NSScreen.screenWithMouse ?? NSScreen.main
    }

    /// The shared app state.
    private weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// Monitor for mouse down events.
    private lazy var mouseDownMonitor = UniversalEventMonitor(
        mask: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    ) { [weak self] event in
        guard let self, event.window !== self else {
            return event
        }
        close()
        return event
    }

    /// Monitor for key down events.
    private lazy var keyDownMonitor = UniversalEventMonitor(
        mask: [.keyDown]
    ) { [weak self] event in
        if KeyCode(rawValue: Int(event.keyCode)) == .escape {
            self?.close()
            return nil
        }
        return event
    }

    /// Overridden to always be `true`.
    override var canBecomeKey: Bool { true }

    /// Creates a menu bar search panel with the given app state.
    init(appState: AppState) {
        super.init(
            contentRect: .zero,
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )
        self.appState = appState
        self.titlebarAppearsTransparent = true
        self.isMovableByWindowBackground = false
        self.animationBehavior = .none
        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .moveToActiveSpace]
        configureCancellables()
    }

    /// Configures the internal observers for the panel.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        NSApp.publisher(for: \.effectiveAppearance)
            .sink { [weak self] effectiveAppearance in
                self?.appearance = effectiveAppearance
            }
            .store(in: &c)

        // Close the panel when the active space changes, or when the screen parameters change.
        Publishers.Merge(
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification),
            NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
        )
        .sink { [weak self] _ in
            self?.close()
        }
        .store(in: &c)

        cancellables = c
    }

    /// Shows the search panel on the given screen.
    @MainActor
    func show(on screen: NSScreen) async {
        guard let appState else {
            return
        }

        appState.navigationState.isSearchPresented = true
        await appState.menuBarManager.itemCover.refresh()

        let hostingView = MenuBarSearchHostingView(
            cover: appState.menuBarManager.itemCover,
            close: { [weak self] in self?.close() }
        )
        hostingView.setFrameSize(NSSize(width: 520, height: 420))
        setFrame(hostingView.frame, display: true)
        contentView = hostingView

        let topLeft = CGPoint(
            x: screen.frame.midX - frame.width / 2,
            y: screen.frame.midY + (frame.height / 2) + (screen.frame.height / 8)
        )
        cascadeTopLeft(from: topLeft)
        makeKeyAndOrderFront(nil)

        mouseDownMonitor.start()
        keyDownMonitor.start()
    }

    /// Toggles the panel's visibility.
    @MainActor
    func toggle() async {
        if isVisible {
            close()
        } else if let screen = MenuBarSearchPanel.defaultScreen {
            await show(on: screen)
        }
    }

    /// Dismisses the search panel.
    override func close() {
        super.close()
        contentView = nil
        mouseDownMonitor.stop()
        keyDownMonitor.stop()
        appState?.navigationState.isSearchPresented = false
    }
}

private final class MenuBarSearchHostingView: NSHostingView<MenuBarSearchContentView> {
    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsets()
    }

    init(cover: HiddenItemCover, close: @escaping () -> Void) {
        super.init(rootView: MenuBarSearchContentView(cover: cover, close: close))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @available(*, unavailable)
    required init(rootView: MenuBarSearchContentView) {
        fatalError("init(rootView:) has not been implemented")
    }
}

private struct MenuBarSearchContentView: View {
    @ObservedObject var cover: HiddenItemCover
    let close: () -> Void

    @State private var query = ""
    @State private var selection: String?
    @FocusState private var isSearchFocused: Bool

    private var results: [HiddenItemCover.Item] {
        let items = cover.items
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return items
        }
        return items.filter {
            $0.displayName.localizedCaseInsensitiveContains(trimmed) ||
            ($0.bundleIdentifier?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                TextField("Search menu bar items", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isSearchFocused)
                    .onSubmit { openSelected() }
            }
            .padding(14)

            Divider()

            if results.isEmpty {
                Text("No matching menu bar items")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(results, selection: $selection) { item in
                    HStack(spacing: 10) {
                        if let icon = item.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 24, height: 24)
                        } else {
                            Image(systemName: "square.dashed")
                                .frame(width: 24, height: 24)
                        }
                        Text(item.displayName)
                            .lineLimit(1)
                        Spacer()
                        if cover.isHidden(item) {
                            Text("Hidden")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selection = item.id
                        open(item)
                    }
                    .tag(item.id)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(width: 520, height: 420)
        .onAppear {
            isSearchFocused = true
            selection = results.first?.id
        }
        .onChange(of: query) {
            selection = results.first?.id
        }
    }

    private func openSelected() {
        if let item = results.first(where: { $0.id == selection }) ?? results.first {
            open(item)
        }
    }

    private func open(_ item: HiddenItemCover.Item) {
        close()
        // Let the panel go away first, so the menu opens in front.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            cover.open(item)
        }
    }
}
