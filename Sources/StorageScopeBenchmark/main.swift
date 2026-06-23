import Foundation
import StorageScopeCore

struct BenchmarkArguments {
    var path: String?
    var useSyntheticFixture = false
    var keepFixture = false
    var showFullPath = false
    /// User-requested file count for the synthetic fixture. 0 means "use the v0.5.0 curated
    /// 7-file default". >0 builds the scaled generator (`depth` directory levels deep,
    /// `duplicateRatio` of items emitted as content-identical duplicates).
    var items = 0
    var depth = 0
    /// Fraction in [0, 1] of `items` that become content-identical duplicates. Stored
    /// as the raw user-supplied string so we can validate before parsing (e.g. 0.05 = 5%).
    var duplicateRatio: Double = 0
}

func usage() -> String {
    """
    Usage:
      StorageScopeBenchmark [--show-full-path] <folder>
      StorageScopeBenchmark --synthetic [--keep-fixture] [--show-full-path]
      StorageScopeBenchmark --synthetic --items <n> [--depth <d>] [--duplicates <0..1>] [--keep-fixture]

    Scaled fixtures (--items, --depth, --duplicates) build a synthetic tree of N files
    distributed across up to depth directory levels, with an optional fraction of
    duplicates (pairs sharing identical content). Useful for capturing v0.5.x perf
    baselines at 10k / 100k / 500k items.

    Examples:
      swift run StorageScopeBenchmark --synthetic --items 100000 --depth 8 --duplicates 0.2
      swift run StorageScopeBenchmark --synthetic --items 500000 --depth 12 --keep-fixture
    """
}

func parseArguments(_ rawArguments: [String]) throws -> BenchmarkArguments {
    var arguments = BenchmarkArguments()
    var index = 0

    func consumeNextValue(flag: String) throws -> String {
        index += 1
        guard index < rawArguments.count else {
            throw BenchmarkError.invalidArgument("\(flag) requires a value")
        }
        return rawArguments[index]
    }

    while index < rawArguments.count {
        let value = rawArguments[index]
        switch value {
        case "--synthetic":
            arguments.useSyntheticFixture = true
        case "--keep-fixture":
            arguments.keepFixture = true
        case "--show-full-path":
            arguments.showFullPath = true
        case "--items":
            let raw = try consumeNextValue(flag: value)
            guard let parsed = Int(raw), parsed >= 0 else {
                throw BenchmarkError.invalidArgument("--items requires a non-negative integer, got \(raw)")
            }
            arguments.items = parsed
        case "--depth":
            let raw = try consumeNextValue(flag: value)
            guard let parsed = Int(raw), parsed >= 0 else {
                throw BenchmarkError.invalidArgument("--depth requires a non-negative integer, got \(raw)")
            }
            arguments.depth = parsed
        case "--duplicates":
            let raw = try consumeNextValue(flag: value)
            guard let parsed = Double(raw), parsed >= 0, parsed <= 1 else {
                throw BenchmarkError.invalidArgument("--duplicates requires a fraction in [0,1], got \(raw)")
            }
            arguments.duplicateRatio = parsed
        case "-h", "--help":
            print(usage())
            exit(0)
        default:
            guard !value.hasPrefix("-") else {
                throw BenchmarkError.invalidArgument(value)
            }
            guard arguments.path == nil else {
                throw BenchmarkError.invalidArgument(value)
            }
            arguments.path = value
        }
        index += 1
    }

    if arguments.items > 0 {
        arguments.useSyntheticFixture = true
    }

    return arguments
}

enum BenchmarkError: LocalizedError {
    case missingPath
    case invalidArgument(String)

    var errorDescription: String? {
        switch self {
        case .missingPath:
            return "Provide a folder path, or pass --synthetic."
        case .invalidArgument(let argument):
            return "Invalid benchmark argument: \(argument)"
        }
    }
}

do {
    let arguments = try parseArguments(Array(CommandLine.arguments.dropFirst()))
    let rootURL: URL
    var cleanup: (() -> Void)?

    if arguments.useSyntheticFixture {
        if arguments.items > 0 {
            let depth = arguments.depth > 0 ? arguments.depth : 5
            rootURL = try SyntheticBenchmarkFixture.create(
                items: arguments.items,
                depth: depth,
                duplicateRatio: arguments.duplicateRatio
            )
        } else {
            rootURL = try SyntheticBenchmarkFixture.create()
        }
        if arguments.keepFixture {
            print("Synthetic fixture: \(rootURL.path)")
        } else {
            cleanup = { SyntheticBenchmarkFixture.remove(rootURL) }
        }
    } else if let path = arguments.path {
        rootURL = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    } else {
        throw BenchmarkError.missingPath
    }

    defer {
        cleanup?()
    }

    let report = try ScanBenchmarkRunner().run(
        rootURL: rootURL,
        showFullPath: arguments.showFullPath
    )
    print(report.text)
} catch {
    let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
    FileHandle.standardError.write(
        Data("StorageScopeBenchmark failed: \(message)\n\n\(usage())\n".utf8)
    )
    exit(2)
}