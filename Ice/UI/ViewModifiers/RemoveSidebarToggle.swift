//
//  RemoveSidebarToggle.swift
//  Fire
//

import SwiftUI

extension View {
    /// Removes the sidebar toggle button from the toolbar.
    ///
    /// No placeholder toolbar item is added, because macOS 27 draws a glass capsule behind
    /// every toolbar item, even an invisible one.
    func removeSidebarToggle() -> some View {
        toolbar(removing: .sidebarToggle)
    }
}
