//
//  SettingsView.swift
//  Ice
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var navigationState: AppNavigationState
    @Environment(\.sidebarRowSize) var sidebarRowSize

    private var sidebarWidth: CGFloat {
        switch sidebarRowSize {
        case .small: 190
        case .medium: 210
        case .large: 230
        @unknown default: 210
        }
    }

    private var sidebarItemHeight: CGFloat {
        switch sidebarRowSize {
        case .small: 26
        case .medium: 32
        case .large: 34
        @unknown default: 32
        }
    }

    private var sidebarItemFontSize: CGFloat {
        switch sidebarRowSize {
        case .small: 13
        case .medium: 15
        case .large: 16
        @unknown default: 15
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
        .navigationTitle(navigationState.settingsNavigationIdentifier.localized)
    }

    @ViewBuilder
    private var sidebar: some View {
        List(selection: $navigationState.settingsNavigationIdentifier) {
            Section {
                ForEach(SettingsNavigationIdentifier.allCases, id: \.self) { identifier in
                    sidebarItem(for: identifier)
                }
            } header: {
                HStack(spacing: 8) {
                    Image(.fireOpen)
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 30, height: 30)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(red: 1.0, green: 0.62, blue: 0.15), Color(red: 1.0, green: 0.22, blue: 0.12)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    Text("Fire")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                }
                .padding(.vertical, 8)
            }
            .collapsible(false)
        }
        .scrollDisabled(true)
        .removeSidebarToggle()
        .navigationSplitViewColumnWidth(sidebarWidth)
    }

    @ViewBuilder
    private var detailView: some View {
        switch navigationState.settingsNavigationIdentifier {
        case .general:
            GeneralSettingsPane()
        case .menuBarLayout:
            MenuBarLayoutSettingsPane()
        case .menuBarAppearance:
            MenuBarAppearanceSettingsPane()
        case .hotkeys:
            HotkeysSettingsPane()
        case .advanced:
            AdvancedSettingsPane()
        case .about:
            AboutSettingsPane()
        }
    }

    @ViewBuilder
    private func sidebarItem(for identifier: SettingsNavigationIdentifier) -> some View {
        Label {
            Text(identifier.localized)
                .font(.system(size: sidebarItemFontSize, weight: .medium))
                .padding(.leading, 2)
        } icon: {
            icon(for: identifier).view
        }
        .frame(height: sidebarItemHeight)
    }

    private func icon(for identifier: SettingsNavigationIdentifier) -> IconResource {
        switch identifier {
        case .general: .systemSymbol("slider.horizontal.3")
        case .menuBarLayout: .systemSymbol("menubar.rectangle")
        case .menuBarAppearance: .systemSymbol("paintbrush.pointed")
        case .hotkeys: .systemSymbol("command")
        case .advanced: .systemSymbol("gearshape.2")
        case .about: .systemSymbol("flame.fill")
        }
    }
}
