import Darwin
import Foundation

/// Holds only one locally installed model. File metadata is checked on every use so reinstalling
/// into the same directory does not reuse Core ML objects backed by the removed files.
public actor SerializedModelCache<Model: Sendable> {
    public enum CacheError: Error {
        case changedDuringLoad
    }

    private struct FileStamp: Equatable {
        let path: String
        let type: FileAttributeType?
        let inode: NSNumber?
        let size: NSNumber?
        let created: Date?
        let modified: Date?
        let changedSeconds: Int64
        let changedNanoseconds: Int64
    }

    private struct Fingerprint: Equatable {
        let directory: URL
        let files: [FileStamp]
    }

    private var cached: (fingerprint: Fingerprint, model: Model)?
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// The gate covers initialization AND the complete operation: actor isolation alone does not
    /// prevent concurrent use of a model across `await` suspension points.
    public func withModel<Result: Sendable>(
        at directory: URL,
        load: @Sendable (URL) async throws -> Model,
        operation: @Sendable (Model) async throws -> Result
    ) async throws -> Result {
        await acquire()
        defer { release() }

        let canonicalDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let current: Fingerprint
        do {
            current = try Self.fingerprint(at: canonicalDirectory)
        } catch {
            cached = nil // Removal must discard the old in-memory session, even on a failed lookup.
            throw error
        }
        if cached?.fingerprint != current {
            cached = nil // Release the previous folder before loading another model.
            let model = try await load(canonicalDirectory)
            let after = try Self.fingerprint(at: canonicalDirectory)
            guard after == current else { throw CacheError.changedDuringLoad }
            cached = (after, model)
        }
        return try await operation(cached!.model)
    }

    private func acquire() async {
        if !occupied {
            occupied = true
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private func release() {
        if waiters.isEmpty {
            occupied = false
        } else {
            waiters.removeFirst().resume() // Ownership passes directly to the next waiter.
        }
    }

    private static func fingerprint(at directory: URL) throws -> Fingerprint {
        let manager = FileManager.default
        var stamps: [FileStamp] = []

        func visit(_ url: URL, relativePath: String) throws {
            let attributes = try manager.attributesOfItem(atPath: url.path)
            let type = attributes[.type] as? FileAttributeType
            // EchoFlow's installer writes regular files; a linked nested asset can change
            // outside this folder without changing its link metadata. Never reuse it.
            guard type != .typeSymbolicLink else { throw CocoaError(.fileReadUnknown) }
            var fileInfo = stat()
            guard lstat(url.path, &fileInfo) == 0 else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            stamps.append(FileStamp(
                path: relativePath,
                type: type,
                inode: attributes[.systemFileNumber] as? NSNumber,
                size: attributes[.size] as? NSNumber,
                created: attributes[.creationDate] as? Date,
                modified: attributes[.modificationDate] as? Date,
                // APFS updates ctime for in-place writes even if mtime is restored. Reading
                // metadata avoids hashing multi-gigabyte weights for every dictation.
                changedSeconds: Int64(fileInfo.st_ctimespec.tv_sec),
                changedNanoseconds: Int64(fileInfo.st_ctimespec.tv_nsec)
            ))
            if type == .typeDirectory {
                let children = try manager.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil, options: []
                ).sorted { $0.lastPathComponent < $1.lastPathComponent }
                for child in children {
                    let path = relativePath.isEmpty
                        ? child.lastPathComponent : relativePath + "/" + child.lastPathComponent
                    try visit(child, relativePath: path)
                }
            }
        }

        try visit(directory, relativePath: "")
        guard stamps.first?.type == .typeDirectory else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return Fingerprint(directory: directory, files: stamps)
    }
}
