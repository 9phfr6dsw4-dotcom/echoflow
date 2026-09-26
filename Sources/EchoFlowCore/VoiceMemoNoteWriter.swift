import Darwin
import Foundation

public enum VoiceMemoNoteWriterError: Error, LocalizedError, Sendable {
    case emptyTranscript
    case destinationIsNotDirectory(URL)
    case atomicPublishUnavailable(URL)
    case fileWriteFailed(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            return "No speech was recognized, so no voice memo was saved."
        case .destinationIsNotDirectory(let url):
            return "The selected voice memo destination is not an existing folder: \(url.path)"
        case .atomicPublishUnavailable(let url):
            return "This folder's storage does not support safely publishing a complete memo without replacing an existing file: \(url.path). Choose another folder."
        case .fileWriteFailed(let path, let code):
            let detail = POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO).localizedDescription
            return "Could not save the voice memo at \(path): \(detail)"
        }
    }
}

/// Writes each voice memo as a new Markdown file and never replaces an existing file.
public struct VoiceMemoNoteWriter {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    @discardableResult
    public func write(
        _ transcript: String,
        to directoryURL: URL,
        timestamp: Date = Date(),
        timeZone: TimeZone = .current
    ) throws -> URL {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceMemoNoteWriterError.emptyTranscript
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw VoiceMemoNoteWriterError.destinationIsNotDirectory(directoryURL)
        }
        let volumeValues = try directoryURL.resourceValues(forKeys: [.volumeSupportsExclusiveRenamingKey])
        guard volumeValues.volumeSupportsExclusiveRenaming == true else {
            throw VoiceMemoNoteWriterError.atomicPublishUnavailable(directoryURL)
        }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = timeZone
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let displayTimestamp = dateFormatter.string(from: timestamp)
        let filenameTimestamp = displayTimestamp.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: " ", with: "_")
        let contents = Data("# Voice Memo — \(displayTimestamp)\n\n\(transcript)\n".utf8)

        var collisionIndex = 1
        while true {
            let suffix = collisionIndex == 1 ? "" : "-\(collisionIndex)"
            let fileURL = directoryURL.appendingPathComponent(
                "Voice-Memo-\(filenameTimestamp)\(suffix).md",
                isDirectory: false
            )
            let temporaryURL = directoryURL.appendingPathComponent(
                ".EchoFlow-Voice-Memo-\(UUID().uuidString).tmp",
                isDirectory: false
            )
            var descriptor = Darwin.open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(S_IRUSR | S_IWUSR))
            guard descriptor >= 0 else {
                let errorCode = errno
                if errorCode == EEXIST { continue }
                throw VoiceMemoNoteWriterError.fileWriteFailed(temporaryURL.path, errorCode)
            }
            if let aclError = Self.removeExtendedACL(from: descriptor) {
                _ = Darwin.close(descriptor)
                _ = Darwin.unlink(temporaryURL.path)
                throw VoiceMemoNoteWriterError.fileWriteFailed(temporaryURL.path, aclError)
            }
            guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
                let errorCode = errno
                _ = Darwin.close(descriptor)
                _ = Darwin.unlink(temporaryURL.path)
                throw VoiceMemoNoteWriterError.fileWriteFailed(temporaryURL.path, errorCode)
            }

            do {
                try Self.write(contents, to: descriptor, path: fileURL.path)
                let syncResult = Darwin.fsync(descriptor)
                guard syncResult == 0 else {
                    throw VoiceMemoNoteWriterError.fileWriteFailed(fileURL.path, errno)
                }
                let closeResult = Darwin.close(descriptor)
                descriptor = -1
                guard closeResult == 0 else {
                    throw VoiceMemoNoteWriterError.fileWriteFailed(fileURL.path, errno)
                }
            } catch {
                if descriptor >= 0 { _ = Darwin.close(descriptor) }
                _ = Darwin.unlink(temporaryURL.path)
                throw error
            }

            if Darwin.renamex_np(temporaryURL.path, fileURL.path, UInt32(RENAME_EXCL)) == 0 {
                return fileURL
            }
            let errorCode = errno
            _ = Darwin.unlink(temporaryURL.path)
            if errorCode == EEXIST {
                collisionIndex += 1
                continue
            }
            throw VoiceMemoNoteWriterError.fileWriteFailed(fileURL.path, errorCode)
        }
    }

    /// Replaces any extended ACL (including entries inherited from the destination folder)
    /// with an empty one, then verifies that no ACL entries remain. Returns an errno value
    /// when the file cannot be proven free of ACL grants, so callers fail closed.
    private static func removeExtendedACL(from descriptor: Int32) -> Int32? {
        guard let emptyACL = Darwin.acl_init(0) else {
            return errno == 0 ? ENOMEM : errno
        }
        let setResult = Darwin.acl_set_fd_np(descriptor, emptyACL, ACL_TYPE_EXTENDED)
        let setError = errno
        _ = Darwin.acl_free(UnsafeMutableRawPointer(emptyACL))

        errno = 0
        guard let remainingACL = Darwin.acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            let getError = errno
            // ENOENT means the file has no extended ACL at all.
            if getError == ENOENT { return nil }
            if setResult != 0 { return setError == 0 ? EPERM : setError }
            return getError == 0 ? EPERM : getError
        }
        defer { _ = Darwin.acl_free(UnsafeMutableRawPointer(remainingACL)) }
        var entry: acl_entry_t?
        if Darwin.acl_get_entry(remainingACL, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == 0 {
            return setResult != 0 && setError != 0 ? setError : EPERM
        }
        return nil
    }

    private static func write(_ data: Data, to descriptor: Int32, path: String) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw VoiceMemoNoteWriterError.fileWriteFailed(path, EIO)
            }
            var bytesWritten = 0
            while bytesWritten < buffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: bytesWritten),
                    buffer.count - bytesWritten
                )
                if result > 0 {
                    bytesWritten += result
                } else if result < 0 && errno == EINTR {
                    continue
                } else {
                    throw VoiceMemoNoteWriterError.fileWriteFailed(path, errno == 0 ? EIO : errno)
                }
            }
        }
    }
}
