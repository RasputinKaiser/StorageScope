import SwiftUI

extension View {
    /// Standard card background across the app. Replaces the repeated
    /// `.background(<material>, in: RoundedRectangle(cornerRadius: <radius>))`
    /// pattern that previously appeared ~22 times across the view layer.
    /// Kept as a View extension rather than a ViewModifier so call sites stay terse;
    /// default radius matches the existing 8/8 split that ships today.
    func cardBackground(_ material: Material = .regular, radius: CGFloat = 12) -> some View {
        background(material, in: RoundedRectangle(cornerRadius: radius))
            // Soft layered elevation instead of a flat fill — adapts to light/dark via
            // NSColor.shadowColor rather than a fixed black, and stays subtle enough not
            // to compete with WelcomeCapabilityCard's own stronger hover shadow.
            .shadow(color: Color(nsColor: .shadowColor).opacity(0.05), radius: 1, y: 1)
            .shadow(color: Color(nsColor: .shadowColor).opacity(0.05), radius: 4, y: 2)
    }

    /// Selection highlight tint. Default opacity (0.18) matches list rows and cards;
    /// sidebar items pass a higher `tint` (0.24) since they're slimmer visually.
    /// Pass `radius: nil` (default) for a plain fill — matches the legacy full-width row
    /// highlight shape used in StorageItemTable / TreeExplorerView; pass a corner radius
    /// to wrap in a RoundedRectangle for cards with rounded selection boxes.
    @ViewBuilder
    func selectionBackground(isSelected: Bool, tint: Double = 0.18, radius: CGFloat? = nil) -> some View {
        let color = isSelected ? Color.accentColor.opacity(tint) : Color.clear
        if let radius {
            background(color, in: RoundedRectangle(cornerRadius: radius))
        } else {
            background(color)
        }
    }
}