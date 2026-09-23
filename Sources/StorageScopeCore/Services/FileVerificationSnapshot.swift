import Darwin
import Foundation

/// Identity and change stamps for one independently allocated regular file.
/// ctime prevents a same-size rewrite with a restored mtime from hitting the cache.
struct FileVerificationSnapshot: Equatable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init?(_ value: stat) {
        guard value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1 else { return nil }
        device = value.st_dev
        inode = value.st_ino
        size = value.st_size
        modifiedSeconds = value.st_mtimespec.tv_sec
        modifiedNanoseconds = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec
        changedNanoseconds = value.st_ctimespec.tv_nsec
    }

    static func read(at url: URL) -> Self? {
        var value = stat()
        guard url.withUnsafeFileSystemRepresentation({ path in
            path.map { lstat($0, &value) } ?? -1
        }) == 0 else { return nil }
        return Self(value)
    }

    static func isHardLinked(at url: URL) -> Bool {
        var value = stat()
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path, lstat(path, &value) == 0 else { return false }
            return value.st_mode & S_IFMT == S_IFREG && value.st_nlink > 1
        }
    }

    func matches(_ item: StorageItem) -> Bool {
        guard item.kind == .file, size == item.byteSize, let modifiedAt = item.modifiedAt else { return false }
        let date = Date(timeIntervalSince1970: Double(modifiedSeconds) + Double(modifiedNanoseconds) / 1_000_000_000)
        return abs(date.timeIntervalSince(modifiedAt)) < 0.000_001
    }

    func key(for item: StorageItem) -> DuplicateHashCache.LookupKey {
        DuplicateHashCache.LookupKey(
            path: item.url.standardizedFileURL.path, byteSize: size, modificationDate: item.modifiedAt,
            identity: "\(device):\(inode):\(modifiedSeconds):\(modifiedNanoseconds):\(changedSeconds):\(changedNanoseconds)"
        )
    }

    func matches(descriptor: Int32) -> Bool {
        var value = stat()
        return fstat(descriptor, &value) == 0 && Self(value) == self
    }
}
