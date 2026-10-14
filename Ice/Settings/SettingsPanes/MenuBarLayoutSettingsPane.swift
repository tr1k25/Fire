//
//  MenuBarLayoutSettingsPane.swift
//  Fire
//

import SwiftUI

/// The pane that lists all menu bar items and lets the user hide or show them.
struct MenuBarLayoutSettingsPane: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        MenuBarItemsList(cover: appState.menuBarManager.itemCover)
    }
}

private struct MenuBarItemsList: View {
    @ObservedObject var cover: HiddenItemCover
    @State private var busyItemID: String?
    @State private var failedItemName: String?
    @State private var isTrusted = AXIsProcessTrusted()

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var shownItems: [HiddenItemCover.Item] {
        cover.items.filter { !cover.isHidden($0) }
    }

    private var hiddenItems: [HiddenItemCover.Item] {
        cover.items.filter { cover.isHidden($0) }
    }

    var body: some View {
        IceForm(alignment: .leading, spacing: 18) {
            header
            if isTrusted {
                section(
                    title: "Hidden",
                    subtitle: "Covered in the menu bar until you click the Fire icon.",
                    symbol: "eye.slash",
                    items: hiddenItems,
                    emptyText: "Nothing is hidden. Hide an item to keep your menu bar tidy."
                )
                section(
                    title: "Shown",
                    subtitle: "Always visible in the menu bar.",
                    symbol: "eye",
                    items: shownItems,
                    emptyText: "No other menu bar items were found."
                )
            } else {
                permissionNotice
            }
            footer
        }
        .task {
            isTrusted = AXIsProcessTrusted()
            await cover.refresh()
        }
        .onReceive(timer) { _ in
            isTrusted = AXIsProcessTrusted()
            if busyItemID == nil {
                Task { await cover.refresh() }
            }
        }
    }

    // MARK: Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Menu Bar Items")
                .font(.system(size: 22, weight: .bold, design: .rounded))
            Text("Items to the left of the Fire icon are hidden. Use the buttons to move an item to the other side.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var permissionNotice: some View {
        IceSection {
            VStack(alignment: .leading, spacing: 8) {
                Label("Accessibility permission required", systemImage: "hand.raised.fill")
                    .font(.headline)
                Text("Fire needs the Accessibility permission to find and move menu bar items.")
                    .foregroundStyle(.secondary)
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let failedItemName {
                Label(
                    "Could not move \(failedItemName). Hold ⌘ and drag it in the menu bar instead.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            }
            Text("Tip: you can also hold ⌘ and drag items directly in the menu bar.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func section(
        title: String,
        subtitle: String,
        symbol: String,
        items: [HiddenItemCover.Item],
        emptyText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.headline)
                Text("\(items.count)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Spacer()
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            IceGroupBox(padding: 4) {
                if items.isEmpty {
                    Text(emptyText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                } else {
                    VStack(spacing: 0) {
                        ForEach(items) { item in
                            row(for: item)
                            if item.id != items.last?.id {
                                Divider().padding(.leading, 44)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(for item: HiddenItemCover.Item) -> some View {
        let isHidden = cover.isHidden(item)
        HStack(spacing: 12) {
            Group {
                if let icon = item.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "square.dashed")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName)
                    .lineLimit(1)
                if item.isSystem {
                    Text("System")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if busyItemID == item.id {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    cover.open(item)
                } label: {
                    Image(systemName: "cursorarrow.click")
                }
                .help("Open this item's menu")
                .buttonStyle(.borderless)

                if !item.isSystem {
                    Button {
                        move(item, hide: !isHidden)
                    } label: {
                        Label(isHidden ? "Show" : "Hide", systemImage: isHidden ? "eye" : "eye.slash")
                            .labelStyle(.titleAndIcon)
                    }
                    .controlSize(.small)
                    .disabled(busyItemID != nil)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    // MARK: Actions

    private func move(_ item: HiddenItemCover.Item, hide: Bool) {
        busyItemID = item.id
        failedItemName = nil
        Task {
            let success = await cover.setHidden(hide, for: item)
            busyItemID = nil
            if !success {
                failedItemName = item.appName
            }
            await cover.refresh()
        }
    }
}
