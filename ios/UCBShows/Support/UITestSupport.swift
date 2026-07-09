import SwiftUI

/// Deterministic navigation hooks driven by launch-environment variables, used to
/// capture specific screens for verification screenshots. Active only in DEBUG
/// builds and only when the corresponding variable is set, so shipping behavior
/// is completely unaffected.
///
/// Supported variables:
///   UITEST_TAB           — initial tab index (0 Shows, 1 Classes)
///   UITEST_PUSH_SOURCE   — push the first show from this source id that has a cast
///   UITEST_CLASS_FILTER  — "1" to auto-present the Classes filter sheet
///   UITEST_SIDEBAR       — "1" to open the theater sidebar on launch
struct UITestTabSelection: ViewModifier {
    @Binding var selection: Int

    func body(content: Content) -> some View {
        #if DEBUG
        content.onAppear {
            if let raw = ProcessInfo.processInfo.environment["UITEST_TAB"],
               let i = Int(raw) {
                selection = i
            }
        }
        #else
        content
        #endif
    }
}

/// DEBUG-only: opens the theater sidebar on launch when UITEST_SIDEBAR=1, for
/// verification screenshots. No-op in release.
struct UITestSidebar: ViewModifier {
    @Environment(AppState.self) private var app

    func body(content: Content) -> some View {
        #if DEBUG
        content.onAppear {
            if ProcessInfo.processInfo.environment["UITEST_SIDEBAR"] == "1" {
                app.sidebarOpen = true
            }
        }
        #else
        content
        #endif
    }
}

extension ProcessInfo {
    var uiTestPushSource: String? {
        #if DEBUG
        environment["UITEST_PUSH_SOURCE"]
        #else
        nil
        #endif
    }

    var uiTestClassFilter: Bool {
        #if DEBUG
        environment["UITEST_CLASS_FILTER"] == "1"
        #else
        false
        #endif
    }
}
