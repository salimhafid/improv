import SwiftUI

extension View {
    /// Recognizes a left-to-right swipe anywhere on the view and runs `action`.
    /// Uses `simultaneousGesture` so it doesn't block the vertical ScrollView, and
    /// only fires for a clearly horizontal rightward drag/flick. Used for the
    /// "open theater drawer" (feed) and "go back" (detail) swipes.
    func onSwipeRight(perform action: @escaping () -> Void) -> some View {
        simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    let t = value.translation
                    let p = value.predictedEndTranslation
                    let horizontalDominant = abs(t.width) > abs(t.height) * 1.5
                    let movedRight = t.width > 60
                    let flickedRight = t.width > 24 && p.width > 140
                    if horizontalDominant && (movedRight || flickedRight) {
                        action()
                    }
                }
        )
    }
}

/// iOS 18 zoom (matched) navigation transition, gracefully no-op on iOS 17.
extension View {
    @ViewBuilder
    func zoomSource(id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            self.matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    @ViewBuilder
    func zoomDestination(id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            self.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }
}
