import CryptoKit
import Foundation

/// A file fetched once, by URL, and accepted only when its SHA-256 digest matches.
///
/// The harness's results depend on exact versions of the guest kernel and Valgrind, so each is
/// pinned by digest rather than trusted by name.
public struct PinnedDownload: Hashable, Sendable {
    /// Where the file is downloaded from.
    public let url: URL
    /// The file's SHA-256 digest, as lowercase hexadecimal.
    public let sha256: String

    /// A download of `url` whose digest must be `sha256`.
    public init(url: URL, sha256: String) {
        self.url = url
        self.sha256 = sha256
    }

    /// Kata Containers 3.17.0 for arm64, the release Containerization's own tooling takes its guest
    /// kernel from.
    public static let kataContainers = PinnedDownload(
        url: URL(string: "https://github.com/kata-containers/kata-containers/releases/download/3.17.0/kata-static-3.17.0-arm64.tar.xz")!,
        sha256: "647c7612e6edf789d5e14698c48c99d8bac15ad139ffaa1c8bb7d229f748d181"
    )

    /// The Valgrind 3.28.0 source release.
    public static let valgrindSource = PinnedDownload(
        url: URL(string: "https://sourceware.org/pub/valgrind/valgrind-3.28.0.tar.bz2")!,
        sha256: "9f7a18d128f05d3a80fea53e6953f34aad7200a425ceaee46099a8a798a7dd9c"
    )

    /// The file in `directory`, downloading it first unless a copy with the right digest is there.
    ///
    /// - Parameter directory: Where downloads are kept.
    /// - Returns: The verified file.
    /// - Throws: ``DigestMismatch`` when the downloaded file's digest is not ``sha256``, or a
    ///   download or file-system error.
    public func fetch(into directory: URL) async throws -> URL {
        let destination = directory.appending(path: url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path), try Self.digest(of: destination) == sha256 {
            return destination
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileHandle.standardError.write(Data("Downloading \(url.absoluteString)\n".utf8))
        let (temporary, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            try? FileManager.default.removeItem(at: temporary)
            throw URLError(.badServerResponse)
        }
        guard try Self.digest(of: temporary) == sha256 else {
            try? FileManager.default.removeItem(at: temporary)
            throw DigestMismatch(url: url)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    private static func digest(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// The error thrown when a downloaded file's digest is not the pinned one.
public struct DigestMismatch: Error, Hashable, Sendable, CustomStringConvertible {
    /// The file's URL.
    public let url: URL

    public var description: String {
        "The SHA-256 digest of \(url.absoluteString) is not the pinned one"
    }
}
