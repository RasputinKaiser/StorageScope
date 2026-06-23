import Foundation

public struct ScanThresholds: Equatable, Sendable {
    public let largeFileThreshold: Int64
    public let duplicateCandidateThreshold: Int64

    public init(largeFileThreshold: Int64, duplicateCandidateThreshold: Int64) {
        self.largeFileThreshold = largeFileThreshold
        self.duplicateCandidateThreshold = duplicateCandidateThreshold
    }
}

public enum ScanOptionPolicy {
    public static func interactiveScanThresholds() -> ScanThresholds {
        // Display-size filtering belongs in ScanStore.sizeFilter; scanner inclusion thresholds stay fixed.
        ScanThresholds(
            largeFileThreshold: 1_000_000_000,
            duplicateCandidateThreshold: 100_000_000
        )
    }
}