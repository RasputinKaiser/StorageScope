import SwiftUI

/// Tactile press feedback for plain-styled row buttons (StorageItemRow, TreeNodeRow,
/// StorageMapRow, DuplicateFileRow, CleanupCandidateRow). Visuals (hover tint, selection
/// background) stay exactly as `.plain` already renders them; this only adds the press
/// scale. 0.96 per the interface-polish rubric — below 0.95 reads as exaggerated for a
/// list row.
struct PressableRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableRowButtonStyle {
    static var pressableRow: PressableRowButtonStyle { PressableRowButtonStyle() }
}
