import Foundation

public enum ModelCatalogError: Error, Equatable, LocalizedError, Sendable {
    case bundledResourcesMissing
    case bundledManifestMissing
    case invalidManifest(String)

    public var errorDescription: String? {
        switch self {
        case .bundledResourcesMissing:
            return "The EchoFlow model resource bundle is missing from the app. Reinstall EchoFlow from the official release."
        case .bundledManifestMissing:
            return "The model catalog file is missing from the EchoFlow app bundle. Reinstall EchoFlow from the official release."
        case .invalidManifest(let reason): return "Invalid model manifest: \(reason)"
        }
    }
}

public struct SupportedLanguage: Decodable, Equatable, Sendable, Identifiable {
    public let code: String
    public let name: String
    public var id: String { code }
}

public struct ModelEngine: Decodable, Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let downloadId: String?
    public let languageSupport: String
    public let accuracyNote: String?
    public let speedNote: String?
    public let vocabularySupport: String?
    private let languageEntries: [SupportedLanguage]?

    public var supportedLanguages: [SupportedLanguage] { languageEntries ?? [] }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, downloadId, languageSupport, accuracyNote, speedNote
        case vocabularySupport, supportedLanguages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        downloadId = try container.decodeIfPresent(String.self, forKey: .downloadId)
        languageSupport = try container.decode(String.self, forKey: .languageSupport)
        accuracyNote = try container.decodeIfPresent(String.self, forKey: .accuracyNote)
        speedNote = try container.decodeIfPresent(String.self, forKey: .speedNote)
        vocabularySupport = try container.decodeIfPresent(String.self, forKey: .vocabularySupport)
        languageEntries = try container.decodeIfPresent([SupportedLanguage].self, forKey: .supportedLanguages)
    }
}

public struct ModelFile: Decodable, Equatable, Sendable, Identifiable {
    public let repo: String
    public let revision: String
    public let sourcePath: String
    public let destinationPath: String
    public let size: Int
    public let sha256: String
    public let sha256Source: String?

    public var id: String { destinationPath }

    public var sourceURL: URL? {
        var segments = repo.split(separator: "/").map(String.init)
        segments.append("resolve")
        segments.append(revision)
        segments.append(contentsOf: sourcePath.split(separator: "/").map(String.init))
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encodedPath = segments
            .compactMap { $0.addingPercentEncoding(withAllowedCharacters: allowed) }
            .joined(separator: "/")
        return URL(string: "https://huggingface.co/\(encodedPath)?download=true")
    }
}

public struct ModelDownload: Decodable, Equatable, Sendable, Identifiable {
    public let id: String
    public let engineId: String
    public let bytes: Int
    public let optional: Bool
    public let license: String?
    public let originalModel: String?
    public let originalModelLicense: String?
    public let files: [ModelFile]
}

private struct ManifestDocument: Decodable {
    let schemaVersion: Int
    let engines: [ModelEngine]
    let downloads: [ModelDownload]
}

public struct ModelCatalog: Sendable {
    public let schemaVersion: Int
    public let engines: [ModelEngine]
    public let downloads: [ModelDownload]

    private static let resourceBundleName = "EchoFlow_EchoFlowCore.bundle"

    public static func bundled() throws -> ModelCatalog {
        let resourceDirectories = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle.main.executableURL?.deletingLastPathComponent()
        ].compactMap { $0 }
        let fileManager = FileManager.default
        guard let resourceDirectory = resourceDirectories.first(where: { directory in
            let manifestURL = directory
                .appendingPathComponent(resourceBundleName, isDirectory: true)
                .appendingPathComponent("model-manifest.json")
            return fileManager.fileExists(atPath: manifestURL.path)
        }) else {
            throw ModelCatalogError.bundledResourcesMissing
        }
        return try bundled(resourceDirectory: resourceDirectory)
    }

    public static func bundled(resourceDirectory: URL) throws -> ModelCatalog {
        let bundleDirectory = resourceDirectory.appendingPathComponent(resourceBundleName, isDirectory: true)
        let manifestURL = bundleDirectory.appendingPathComponent("model-manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            if FileManager.default.fileExists(atPath: bundleDirectory.path) {
                throw ModelCatalogError.bundledManifestMissing
            }
            throw ModelCatalogError.bundledResourcesMissing
        }
        return try ModelCatalog(data: Data(contentsOf: manifestURL))
    }

    public init(data: Data) throws {
        let document: ManifestDocument
        do {
            document = try JSONDecoder().decode(ManifestDocument.self, from: data)
        } catch {
            throw ModelCatalogError.invalidManifest("JSON decoding failed: \(error.localizedDescription)")
        }
        try Self.validate(document)
        schemaVersion = document.schemaVersion
        engines = document.engines
        downloads = document.downloads
    }

    public func engine(id: String) -> ModelEngine? {
        engines.first { $0.id == id }
    }

    public func download(id: String) -> ModelDownload? {
        downloads.first { $0.id == id }
    }

    public func download(forEngineID engineID: String) -> ModelDownload? {
        guard let downloadId = engine(id: engineID)?.downloadId else { return nil }
        return download(id: downloadId)
    }

    private static func validate(_ document: ManifestDocument) throws {
        guard document.schemaVersion == 1 else {
            throw ModelCatalogError.invalidManifest("unsupported schema version \(document.schemaVersion)")
        }
        guard !document.engines.isEmpty, !document.downloads.isEmpty else {
            throw ModelCatalogError.invalidManifest("engines and downloads must not be empty")
        }

        let engineIDs = document.engines.map(\.id)
        guard Set(engineIDs).count == engineIDs.count else {
            throw ModelCatalogError.invalidManifest("duplicate engine identifier")
        }
        let downloadIDs = document.downloads.map(\.id)
        guard Set(downloadIDs).count == downloadIDs.count else {
            throw ModelCatalogError.invalidManifest("duplicate download identifier")
        }
        let downloadsByID = Dictionary(uniqueKeysWithValues: document.downloads.map { ($0.id, $0) })
        let enginesByID = Dictionary(uniqueKeysWithValues: document.engines.map { ($0.id, $0) })

        for engine in document.engines {
            guard !engine.id.isEmpty, !engine.displayName.isEmpty else {
                throw ModelCatalogError.invalidManifest("engine identifiers and names must not be empty")
            }
            if let downloadId = engine.downloadId {
                guard let download = downloadsByID[downloadId], download.engineId == engine.id else {
                    throw ModelCatalogError.invalidManifest("engine \(engine.id) references an inconsistent download")
                }
            }
            let languageCodes = engine.supportedLanguages.map(\.code)
            guard languageCodes.allSatisfy({ !$0.isEmpty }) else {
                throw ModelCatalogError.invalidManifest("engine \(engine.id) has an empty language code")
            }
            guard Set(languageCodes).count == languageCodes.count else {
                throw ModelCatalogError.invalidManifest("engine \(engine.id) has duplicate language codes")
            }
        }

        for download in document.downloads {
            guard enginesByID[download.engineId] != nil else {
                throw ModelCatalogError.invalidManifest("download \(download.id) references an unknown engine")
            }
            guard download.bytes > 0, !download.files.isEmpty else {
                throw ModelCatalogError.invalidManifest("download \(download.id) must have files and a positive byte total")
            }
            guard download.license?.isEmpty == false else {
                throw ModelCatalogError.invalidManifest("download \(download.id) is missing license metadata")
            }

            var totalBytes = 0
            var destinationPaths = Set<String>()
            for file in download.files {
                guard isPublicRepository(file.repo) else {
                    throw ModelCatalogError.invalidManifest("file repository must be a public Hugging Face owner/name")
                }
                guard isPinnedRevision(file.revision) else {
                    throw ModelCatalogError.invalidManifest("file revision must be a 40-character commit SHA")
                }
                guard isSafeRelativePath(file.sourcePath), isSafeRelativePath(file.destinationPath) else {
                    throw ModelCatalogError.invalidManifest("file paths must be safe relative paths")
                }
                guard file.size > 0 else {
                    throw ModelCatalogError.invalidManifest("file size must be positive")
                }
                guard isSHA256(file.sha256) else {
                    throw ModelCatalogError.invalidManifest("file SHA-256 must contain 64 hexadecimal characters")
                }
                guard let url = file.sourceURL,
                      url.scheme == "https",
                      url.host == "huggingface.co",
                      url.user == nil,
                      url.password == nil else {
                    throw ModelCatalogError.invalidManifest("file URL must be public HTTPS on huggingface.co")
                }
                guard destinationPaths.insert(file.destinationPath).inserted else {
                    throw ModelCatalogError.invalidManifest("download \(download.id) has duplicate destination paths")
                }
                let (sum, overflow) = totalBytes.addingReportingOverflow(file.size)
                guard !overflow else {
                    throw ModelCatalogError.invalidManifest("download \(download.id) byte total overflowed")
                }
                totalBytes = sum
            }
            guard totalBytes == download.bytes else {
                throw ModelCatalogError.invalidManifest("download \(download.id) byte total does not match its files")
            }
        }
    }

    private static func isPublicRepository(_ repo: String) -> Bool {
        let components = repo.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else { return false }
        return components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
                && component.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
        }
    }

    private static func isPinnedRevision(_ revision: String) -> Bool {
        revision.count == 40 && revision.allSatisfy(\.isHexDigit)
    }

    private static func isSHA256(_ digest: String) -> Bool {
        digest.count == 64 && digest.allSatisfy(\.isHexDigit)
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
