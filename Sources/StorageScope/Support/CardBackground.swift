import SwiftUI

extension View {
    /// Standard card background across the app. Replaces the repeated
    /// `.background(<material>, in: RoundedRectangle(cornerRadius: <radius>))`
    /// pattern that previously appeared ~22 times across the view layer.
    /// Kept as a View extension rather than a ViewModifier so call sites stay terse;
    /// default radius matches the existing 8/8 split that ships today.
    func cardBackground(_ material: Material = .regular, radius: CGFloat = 8) -> some View {
        background(material, in: RoundedRectangle(cornerRadius: radius))
    }
}