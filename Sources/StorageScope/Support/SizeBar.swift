import SwiftUI

/// Shared fractional size bar used by row views (Tree Explorer, Type Breakdown,
/// Overview storage map). Drawn with `Canvas` rather than the previous per-row
/// `GeometryReader` track/overlay pair: `GeometryReader` adds a deferred layout
/// pass for every visible row, which compounds on scrolls through hundreds of
/// expanded tree rows. `Canvas` receives its resolved size directly and draws
/// the same two rounded rects in one pass with no extra layout feedback.
struct SizeBar: View {
    let fraction: Double
    private let fill: AnyShapeStyle
    private let minimumWidth: CGFloat

    init(fraction: Double, fill: some ShapeStyle, minimumWidth: CGFloat = 8) {
        self.fraction = fraction
        self.fill = AnyShapeStyle(fill)
        self.minimumWidth = minimumWidth
    }

    var body: some View {
        Canvas { context, size in
            let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4)
            context.fill(track, with: .style(.quaternary))
            let width = min(max(minimumWidth, size.width * CGFloat(fraction)), size.width)
            let bar = Path(
                roundedRect: CGRect(x: 0, y: 0, width: width, height: size.height),
                cornerRadius: 4
            )
            context.fill(bar, with: .style(fill))
        }
    }
}
