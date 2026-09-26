import CryptoKit
import Foundation

public struct ModelInstallProgress: Equatable, Sendable {
    public let verifiedFileCount: Int
    public let fileCount: Int
    public let verifiedBytes: Int
    public let totalBytes: Int
    public let currentPath: String
}

public enum ModelArtifactInstallError: Error, Equatable, LocalizedError, Sendable {
    case invalidDownload(String)
    case invalidFile(String)
    case unsafeDestination(String)
    case httpStatus(Int)
    case missingDownloadedFile(String)
    case sizeMismatch(path: String, expected: Int, actual: Int)
    case checksumMismatch(String)
    case installationAlreadyExists(String)
    case installationInProgress(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDownload(let id): return "The model download definition is invalid: \(id)"
        case .invalidFile(let path): return "The model file definition is invalid: \(path)"
        case .unsafeDestination(let path): return "The model destination is unsafe: \(path)"
        case .httpStatus(let status): return "The public model server returned HTTP \(status)."
        case .missingDownloadedFile(let path): return "The downloaded model file is missing: \(path)"
        case .sizeMismatch(let path, let expected, let actual):
            return "The downloaded size for \(path) was \(actual) bytes; expected \(expected)."
        case .checksumMismatch(let path): return "The SHA-256 checksum did not match for \(path)."
        case .installationAlreadyExists(let id): return "An incomplete installation already exists for \(id)."
        case .installationInProgress(let id): return "An installation is already running for \(id)."
        }
    }
}

public typealias ModelArtifactFetcher = @Sendable (_ source: URL, _ destination: URL) async throws -> Void

private struct InstalledFileMarker: Codable, Equatable, Sendable {
    let path: String
    let size: Int
    let sha256: String
}

private struct InstalledModelMarker: Codable, Equatable, Sendable {
    let formatVersion: Int
    let downloadID: String
    let engineID: String
    let files: [InstalledFileMarker]
}

public final class ModelArtifactInstaller: @unchecked Sendable {
    private let modelsDirectory: URL
    private let fetcher: ModelArtifactFetcher?
    private let session: URLSession
    private let lock = NSLock()
    private var activeInstallations = Set<String>()

    public init(modelsDirectory: URL) {
        self.modelsDirectory = modelsDirectory.standardizedFileURL
        self.fetcher = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpAdditionalHeaders = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    public init(modelsDirectory: URL, fetcher: @escaping ModelArtifactFetcher) {
        self.modelsDirectory = modelsDirectory.standardizedFileURL
        self.fetcher = fetcher
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpAdditionalHeaders = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    public func install(
        _ download: ModelDownload,
        progress: (@Sendable (ModelInstallProgress) -> Void)? = nil
    ) async throws -> URL {
        try Self.validate(download)
        try beginInstallation(id: download.id)
        defer { endInstallation(id: download.id) }

        let finalURL = modelsDirectory.appendingPathComponent(download.id, isDirectory: true)
        if isInstalled(download) { return finalURL }
        if FileManager.default.fileExists(atPath: finalURL.path) {
            // A folder without this app's marker (for example one left in the shared FluidAudio
            // folder by an earlier version) is adopted only when every file matches the manifest.
            guard try adoptVerifiedExistingInstallation(download, at: finalURL, progress: progress) else {
                throw ModelArtifactInstallError.installationAlreadyExists(download.id)
            }
            return finalURL
        }

        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let stagingURL = modelsDirectory.appendingPathComponent(".installing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: false)

        do {
            var verifiedBytes = 0
            for (index, file) in download.files.enumerated() {
                try Task.checkCancellation()
                guard let sourceURL = file.sourceURL else {
                    throw ModelArtifactInstallError.invalidFile(file.sourcePath)
                }

                let temporaryURL = stagingURL.appendingPathComponent(".download-\(UUID().uuidString)")
                try await fetch(sourceURL, to: temporaryURL)
                guard FileManager.default.fileExists(atPath: temporaryURL.path) else {
                    throw ModelArtifactInstallError.missingDownloadedFile(file.sourcePath)
                }

                let attributes = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
                let actualSize = (attributes[.size] as? NSNumber)?.intValue ?? (attributes[.size] as? Int ?? -1)
                guard actualSize == file.size else {
                    throw ModelArtifactInstallError.sizeMismatch(path: file.sourcePath, expected: file.size, actual: actualSize)
                }

                let actualDigest = try Self.sha256(of: temporaryURL)
                guard actualDigest.caseInsensitiveCompare(file.sha256) == .orderedSame else {
                    throw ModelArtifactInstallError.checksumMismatch(file.destinationPath)
                }

                let destinationURL = try destinationURL(for: file.destinationPath, inside: stagingURL)
                try FileManager.default.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
                verifiedBytes += file.size
                progress?(ModelInstallProgress(
                    verifiedFileCount: index + 1,
                    fileCount: download.files.count,
                    verifiedBytes: verifiedBytes,
                    totalBytes: download.bytes,
                    currentPath: file.destinationPath
                ))
            }

            let markerData = try JSONEncoder().encode(Self.marker(for: download))
            try markerData.write(to: stagingURL.appendingPathComponent(Self.markerFileName), options: .atomic)
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: stagingURL, to: finalURL)
            return finalURL
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }
    }

    public func isInstalled(_ download: ModelDownload) -> Bool {
        guard Self.isSafeIdentifier(download.id) else { return false }
        let installationURL = modelsDirectory.appendingPathComponent(download.id, isDirectory: true)
        let markerURL = installationURL.appendingPathComponent(Self.markerFileName)
        guard let data = try? Data(contentsOf: markerURL),
              let marker = try? JSONDecoder().decode(InstalledModelMarker.self, from: data),
              marker == Self.marker(for: download) else {
            return false
        }

        return download.files.allSatisfy { file in
            guard Self.isSafeRelativePath(file.destinationPath),
                  let url = try? destinationURL(for: file.destinationPath, inside: installationURL),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
                return false
            }
            let size = (attributes[.size] as? NSNumber)?.intValue ?? (attributes[.size] as? Int ?? -1)
            return size == file.size
        }
    }

    public func installedURL(for download: ModelDownload) -> URL? {
        guard isInstalled(download) else { return nil }
        return modelsDirectory.appendingPathComponent(download.id, isDirectory: true)
    }

    @discardableResult
    public func removeInstalled(_ download: ModelDownload) throws -> Bool {
        try Self.validate(download)
        try beginInstallation(id: download.id)
        defer { endInstallation(id: download.id) }

        let installationURL = modelsDirectory.appendingPathComponent(download.id, isDirectory: true).standardizedFileURL
        guard installationURL.deletingLastPathComponent() == modelsDirectory else {
            throw ModelArtifactInstallError.unsafeDestination(download.id)
        }
        guard FileManager.default.fileExists(atPath: installationURL.path) else { return false }
        guard isInstalled(download) else {
            throw ModelArtifactInstallError.installationAlreadyExists(download.id)
        }

        try FileManager.default.removeItem(at: installationURL)
        return true
    }

    private func fetch(_ sourceURL: URL, to destinationURL: URL) async throws {
        guard sourceURL.scheme == "https",
              sourceURL.host == "huggingface.co",
              sourceURL.user == nil,
              sourceURL.password == nil else {
            throw ModelArtifactInstallError.invalidFile(sourceURL.absoluteString)
        }
        if let fetcher {
            try await fetcher(sourceURL, destinationURL)
            return
        }

        var request = URLRequest(url: sourceURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (temporaryURL, response) = try await session.download(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ModelArtifactInstallError.httpStatus(-1)
        }
        guard httpResponse.statusCode == 200 else {
            throw ModelArtifactInstallError.httpStatus(httpResponse.statusCode)
        }
        guard response.url?.scheme == "https" else {
            throw ModelArtifactInstallError.invalidFile(response.url?.absoluteString ?? sourceURL.absoluteString)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
    }

    private func beginInstallation(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard activeInstallations.insert(id).inserted else {
            throw ModelArtifactInstallError.installationInProgress(id)
        }
    }

    private func endInstallation(id: String) {
        lock.lock()
        activeInstallations.remove(id)
        lock.unlock()
    }

    private func destinationURL(for path: String, inside root: URL) throws -> URL {
        guard Self.isSafeRelativePath(path) else {
            throw ModelArtifactInstallError.unsafeDestination(path)
        }
        let candidate = root.appendingPathComponent(path).standardizedFileURL
        let rootURL = root.standardizedFileURL
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard candidate.path.hasPrefix(rootPath) else {
            throw ModelArtifactInstallError.unsafeDestination(path)
        }
        return candidate
    }

    private static func validate(_ download: ModelDownload) throws {
        guard isSafeIdentifier(download.id), isSafeIdentifier(download.engineId),
              download.bytes > 0, !download.files.isEmpty else {
            throw ModelArtifactInstallError.invalidDownload(download.id)
        }
        var totalBytes = 0
        var destinations = Set<String>()
        for file in download.files {
            let repositories = file.repo.split(separator: "/", omittingEmptySubsequences: false)
            guard repositories.count == 2,
                  repositories.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) } }),
                  file.revision.count == 40, file.revision.allSatisfy(\.isHexDigit),
                  isSafeRelativePath(file.sourcePath), isSafeRelativePath(file.destinationPath),
                  file.size > 0,
                  file.sha256.count == 64, file.sha256.allSatisfy(\.isHexDigit),
                  destinations.insert(file.destinationPath).inserted else {
                throw ModelArtifactInstallError.invalidFile(file.destinationPath)
            }
            let (sum, overflow) = totalBytes.addingReportingOverflow(file.size)
            guard !overflow else { throw ModelArtifactInstallError.invalidDownload(download.id) }
            totalBytes = sum
        }
        guard totalBytes == download.bytes else {
            throw ModelArtifactInstallError.invalidDownload(download.id)
        }
    }

    private static let markerFileName = ".echoflow-installed.json"

    /// Verifies an existing, unmarked installation folder file by file (size and SHA-256) and,
    /// only if every file matches, records the marker so it counts as installed. Nothing is
    /// deleted or overwritten; a folder that does not verify is left exactly as it was.
    private func adoptVerifiedExistingInstallation(
        _ download: ModelDownload,
        at installationURL: URL,
        progress: (@Sendable (ModelInstallProgress) -> Void)?
    ) throws -> Bool {
        guard installationURL.standardizedFileURL.deletingLastPathComponent() == modelsDirectory else {
            throw ModelArtifactInstallError.unsafeDestination(download.id)
        }
        var verifiedBytes = 0
        for (index, file) in download.files.enumerated() {
            try Task.checkCancellation()
            let url = try destinationURL(for: file.destinationPath, inside: installationURL)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else {
                return false
            }
            let size = (attributes[.size] as? NSNumber)?.intValue ?? (attributes[.size] as? Int ?? -1)
            guard size == file.size,
                  try Self.sha256(of: url).caseInsensitiveCompare(file.sha256) == .orderedSame else {
                return false
            }
            verifiedBytes += file.size
            progress?(ModelInstallProgress(
                verifiedFileCount: index + 1,
                fileCount: download.files.count,
                verifiedBytes: verifiedBytes,
                totalBytes: download.bytes,
                currentPath: file.destinationPath
            ))
        }
        let markerData = try JSONEncoder().encode(Self.marker(for: download))
        try markerData.write(to: installationURL.appendingPathComponent(Self.markerFileName), options: .atomic)
        return isInstalled(download)
    }

    private static func marker(for download: ModelDownload) -> InstalledModelMarker {
        InstalledModelMarker(
            formatVersion: 1,
            downloadID: download.id,
            engineID: download.engineId,
            files: download.files.map {
                InstalledFileMarker(path: $0.destinationPath, size: $0.size, sha256: $0.sha256.lowercased())
            }
        )
    }

    private static func sha256(of url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hasher = SHA256()
        while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else { return false }
        return value.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
