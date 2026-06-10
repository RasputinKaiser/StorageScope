import SwiftUI

struct FilterRecoveryView: View {
    let title: String
    let systemImage: String
    let description: String
    let filters: [String]
    let clearTitle: String
    let clearAction: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            VStack(spacing: 8) {
                Text(description)

                if !filters.isEmpty {
                    Text(filters.joined(separator: "  |  "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
        } actions: {
            Button(clearTitle) {
                clearAction()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }
}
