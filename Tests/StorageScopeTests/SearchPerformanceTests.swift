import Foundation
import Testing
import StorageScopeCore
@testable import StorageScope

@Suite("Display search performance")
struct SearchPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["STORAGESCOPE_SEARCH_PERF"] == "1"))
    func releaseSearchMeasurement() {
        let items = (0..<20_000).map { index in
            StorageItem(
                url: URL(fileURLWithPath: "/fixture/Documents/Projects/Folder-\(index % 100)/report-\(index).txt"),
                kind: .file, byteSize: 1024, allocatedSize: 1024, modifiedAt: nil,
                immediateChildCount: 0, descendantCount: 0, isReadable: true
            )
        }
        let queries = ["Documents report", "not-present-anywhere", "Projects txt", "Folder-50 report"]
        var durations: [Double] = []
        for _ in 0..<3 {
            let start = ContinuousClock.now
            var matches = 0
            for query in queries {
                matches += items.filter { $0.matchesNormalizedSearchQuery(query) }.count
            }
            let elapsed = start.duration(to: .now).components
            durations.append(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
            #expect(matches == 40_200)
        }
        print("SEARCH_PERF items=20000 queries=4 runs=3 seconds=\(durations) median=\(durations.sorted()[1])")
    }
}
