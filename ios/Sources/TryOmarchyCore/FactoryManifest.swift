import CryptoKit
import Foundation

/// The compressed factory a release publishes in parts.
///
/// This is the same `download.json` the Mac app carries
/// (`FactoryDownloadManifest` in the macOS helper): consecutive byte ranges
/// of one `.img.zst`, each with its own digest. `identity` is the SHA-256 of
/// the decompressed disk.
public struct FactoryManifest: Equatable, Sendable {
    public struct Part: Equatable, Sendable {
        public let url: URL
        public let offset: Int64
        public let bytes: Int64
        public let sha256: String

        public var end: Int64 { offset + bytes }

        public init(url: URL, offset: Int64, bytes: Int64, sha256: String) {
            self.url = url
            self.offset = offset
            self.bytes = bytes
            self.sha256 = sha256
        }
    }

    public static let fileName = "download.json"

    public let identity: String
    public let imageBytes: Int64
    public let imageSHA256: String
    public let parts: [Part]

    public init(identity: String, imageBytes: Int64, imageSHA256: String, parts: [Part]) {
        self.identity = identity
        self.imageBytes = imageBytes
        self.imageSHA256 = imageSHA256
        self.parts = parts
    }

    public static func decode(_ data: Data) -> Self? {
        guard data.count <= 65_536,
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.format == 1, payload.kind == "try-omarchy-factory-download",
              isDigest(payload.identity), isDigest(payload.image.sha256), payload.image.bytes > 0,
              (1...64).contains(payload.parts.count) else { return nil }
        var offset: Int64 = 0
        var parts: [Part] = []
        for part in payload.parts {
            guard part.bytes > 0, isDigest(part.sha256),
                  let url = URL(string: part.url), isAllowed(url) else { return nil }
            parts.append(Part(url: url, offset: offset, bytes: part.bytes, sha256: part.sha256))
            let (next, overflow) = offset.addingReportingOverflow(part.bytes)
            guard !overflow else { return nil }
            offset = next
        }
        guard offset == payload.image.bytes else { return nil }
        return Self(identity: payload.identity, imageBytes: payload.image.bytes,
                    imageSHA256: payload.image.sha256, parts: parts)
    }

    /// HTTPS, or plain HTTP to this device for a test server.
    public static func isAllowed(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil, let host = url.host, !host.isEmpty else { return false }
        switch url.scheme {
        case "https": return true
        case "http": return host == "127.0.0.1" || host == "localhost"
        default: return false
        }
    }

    private struct Payload: Decodable {
        let format: Int
        let kind: String
        let identity: String
        let image: Image
        let parts: [PartPayload]

        struct Image: Decodable {
            let bytes: Int64
            let sha256: String
        }

        struct PartPayload: Decodable {
            let url: String
            let bytes: Int64
            let sha256: String
        }
    }
}

func isDigest(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
}

enum Digest {
    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(of data: Data) -> String {
        hex(SHA256.hash(data: data))
    }
}
