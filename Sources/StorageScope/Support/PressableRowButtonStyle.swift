import SwiftUI

/// Tactile press feedback for plain-styled row buttons (StorageItemRow, TreeNodeRow,
/// StorageMapRow, DuplicateFileRow, CleanupCandidateRow). Visuals (hover tint, selection
/// background) stay exactly as `.plain` already renders them; this only adds the press
/// scale. Keep it subtle for wide rows and honor Reduce Motion.
struct PressableRowButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.99 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableRowButtonStyle {
    static var pressableRow: PressableRowButtonStyle { PressableRowButtonStyle() }
}
