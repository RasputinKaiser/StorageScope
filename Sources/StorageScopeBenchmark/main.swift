import Foundation
import StorageScopeCore

struct BenchmarkArguments {
    var path: String?
    var useSyntheticFixture = false
    var keepFixture = false
    var showFullPath = false
}

func usage() -> String {
    """
    Usage:
      StorageScopeBenchmark [--show-full-path] <folder>
      StorageScopeBenchmark --synthetic [--keep-fixture] [--show-full-path]
    """
}

func parseArguments(_ rawArguments: [String]) throws -> BenchmarkArguments {
    var arguments = BenchmarkArguments()
    var index = 0

    while index < rawArguments.count {
        let value = rawArguments[index]
        switch value {
        case "--synthetic":
            arguments.useSyntheticFixture = true
        case "--keep-fixture":
            arguments.keepFixture = true
        case "--show-full-path":
            arguments.showFullPath = true
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
        rootURL = try SyntheticBenchmarkFixture.create()
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
    FileHandle.standardError.write(Data(((error as? LocalizedError)?.errorDescription ?? "\(error)").utf8))
    FileHandle.standardError.write(Data("\n\n\(usage())\n".utf8))
    exit(2)
}
