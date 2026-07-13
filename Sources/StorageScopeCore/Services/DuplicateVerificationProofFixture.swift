import Foundation

/// Reusable Phase 4 duplicate-verification corpus. The files are synthetic, but their
/// extensions, size-group shape, early-divergence behavior, prefix collision, exact copies,
/// and hard-link alias mirror the expensive media, disk-image, and VM cases the verifier
/// encounters on real disks without committing large or copyrighted assets to the repo.
public struct DuplicateVerificationProofFixture: Sendable {
    public let rootURL: URL
    public let naiveFullHashBytes: Int64
    public let exactDuplicateURLs: [URL]
    public let prefixCollisionURLs: [URL]
    public let hardLinkURLs: [URL]

    public var candidateFileCount: Int {
        48 + exactDuplicateURLs.count + prefixCollisionURLs.count + hardLinkURLs.count
    }

    /// Creates a corpus with 48 same-size early-diverging media/DMG/VM candidates plus
    /// exact-copy, prefix-collision, and hard-link groups. `largeCandidateBytes` defaults
    /// to 4 MiB for release measurements; focused tests can use 1 MiB while preserving
    /// the same >90% byte-reduction denominator.
    public static func create(
        in parentDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default,
        largeCandidateBytes: Int = 4 * 1_024 * 1_024
    ) throws -> DuplicateVerificationProofFixture {
        let largeBytes = max(1_024 * 1_024, largeCandidateBytes)
        let root = parentDirectory.appendingPathComponent(
            "StorageScopeDuplicateProof-\(UUID().uuidString)",
            isDirectory: true
        )
        let media = root.appendingPathComponent("Media", isDirectory: true)
        let images = root.appendingPathComponent("Disk Images", isDirectory: true)
        let virtualMachines = root.appendingPathComponent("Virtual Machines", isDirectory: true)
        let collisions = root.appendingPathComponent("Prefix Collisions", isDirectory: true)
        let links = root.appendingPathComponent("Hard Links", isDirectory: true)

        do {
            for directory in [media, images, virtualMachines, collisions, links] {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }

            let extensions = [
                "mov", "mp4", "m4v", "dmg", "sparseimage", "vmdk", "qcow2", "utm"
            ]
            for index in 0..<48 {
                let directory: URL
                switch index % 3 {
                case 0: directory = media
                case 1: directory = images
                default: directory = virtualMachines
                }
                let fileExtension = extensions[index % extensions.count]
                let url = directory.appendingPathComponent(
                    String(format: "candidate-%02d.%@", index, fileExtension)
                )
                try writePatternFile(
                    at: url,
                    bytes: largeBytes,
                    prefixByte: UInt8(index + 1),
                    bodyByte: UInt8((index * 5 + 17) % 251)
                )
            }

            let exactDuplicateURLs = [
                media.appendingPathComponent("export-copy-a.mov"),
                virtualMachines.appendingPathComponent("export-copy-b.mov")
            ]
            for url in exactDuplicateURLs {
                try writePatternFile(at: url, bytes: 128 * 1_024, prefixByte: 0xD1, bodyByte: 0xD2)
            }

            let prefixCollisionURLs = [
                collisions.appendingPathComponent("shared-header-a.dmg"),
                collisions.appendingPathComponent("shared-header-b.dmg")
            ]
            try writePatternFile(
                at: prefixCollisionURLs[0],
                bytes: 192 * 1_024,
                prefixByte: 0xC1,
                bodyByte: 0xC2
            )
            try writePatternFile(
                at: prefixCollisionURLs[1],
                bytes: 192 * 1_024,
                prefixByte: 0xC1,
                bodyByte: 0xC3
            )

            let hardLinkOriginal = links.appendingPathComponent("vm-base-original.img")
            let hardLinkAlias = links.appendingPathComponent("vm-base-alias.img")
            try writePatternFile(at: hardLinkOriginal, bytes: 96 * 1_024, prefixByte: 0xB1, bodyByte: 0xB2)
            try fileManager.linkItem(at: hardLinkOriginal, to: hardLinkAlias)

            let naiveBytes = Int64(48 * largeBytes) +
                Int64(2 * 128 * 1_024) +
                Int64(2 * 192 * 1_024) +
                Int64(2 * 96 * 1_024)

            return DuplicateVerificationProofFixture(
                rootURL: root,
                naiveFullHashBytes: naiveBytes,
                exactDuplicateURLs: exactDuplicateURLs,
                prefixCollisionURLs: prefixCollisionURLs,
                hardLinkURLs: [hardLinkOriginal, hardLinkAlias]
            )
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
    }

    public func remove(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: rootURL)
    }

    private static func writePatternFile(
        at url: URL,
        bytes: Int,
        prefixByte: UInt8,
        bodyByte: UInt8
    ) throws {
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        do {
            let prefixCount = min(bytes, 64 * 1_024)
            if prefixCount > 0 {
                try handle.write(contentsOf: Data(repeating: prefixByte, count: prefixCount))
            }
            var remaining = bytes - prefixCount
            let chunk = Data(repeating: bodyByte, count: min(max(remaining, 1), 1 * 1_024 * 1_024))
            while remaining > 0 {
                let count = min(remaining, chunk.count)
                try handle.write(contentsOf: chunk.prefix(count))
                remaining -= count
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }
}
