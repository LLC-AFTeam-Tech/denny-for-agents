import Foundation

/// The newest published release, as GitHub describes it.
public struct ReleaseInfo: Equatable, Sendable {
    public var version: String
    public var downloadURL: URL
    /// From the release notes ("SHA-256: …"); without it Denny won't install.
    public var sha256: String?

    public init(version: String, downloadURL: URL, sha256: String?) {
        self.version = version
        self.downloadURL = downloadURL
        self.sha256 = sha256
    }
}

public enum Updates {
    public static let repository = "LLC-AFTeam-Tech/denny-for-agents"
    public static let assetName = "DennyForAgents.zip"

    /// Parses `GET /repos/{repo}/releases/latest`. Only an https download
    /// from github.com is accepted.
    public static func parseLatest(_ data: Data) -> ReleaseInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]],
              let asset = assets.first(where: { $0["name"] as? String == assetName }),
              let link = asset["browser_download_url"] as? String,
              let url = URL(string: link), url.scheme == "https", url.host == "github.com"
        else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return ReleaseInfo(version: version, downloadURL: url, sha256: checksum(in: json["body"] as? String ?? ""))
    }

    static func checksum(in notes: String) -> String? {
        guard let range = notes.range(of: #"SHA-256:\s*[0-9a-fA-F]{64}"#, options: .regularExpression) else { return nil }
        return String(notes[range].suffix(64)).lowercased()
    }

    /// "0.10.0" is newer than "0.9.2"; a leading "v" and suffixes like "-beta" are ignored.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = numbers(candidate), b = numbers(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func numbers(_ version: String) -> [Int] {
        let trimmed = version.hasPrefix("v") ? String(version.dropFirst()) : version
        return trimmed.split(separator: ".").map { part in Int(part.prefix(while: \.isNumber)) ?? 0 }
    }
}
