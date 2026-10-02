import Foundation

public enum ReleaseUpdateStatus: Equatable {
    case updateAvailable(version: String)
    case noNewerRelease(version: String)
    case unknownInstalledVersion(latestVersion: String)
}

public enum ReleaseUpdateError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case invalidRelease

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The update server returned an invalid response."
        case .httpStatus(404):
            return "No published release is available yet."
        case .httpStatus(403), .httpStatus(429):
            return "GitHub is limiting update requests. Please try again later."
        case .httpStatus(let status):
            return "The update check failed (HTTP \(status))."
        case .invalidRelease:
            return "The latest release could not be verified."
        }
    }
}

public enum ReleaseUpdateChecker {
    public static let websiteURL = URL(string: "https://leoccino.github.io/CodexGlance/")!
    public static let releasesURL = URL(string: "https://github.com/Leoccino/CodexGlance/releases/latest")!
    private static let apiURL = URL(string: "https://api.github.com/repos/Leoccino/CodexGlance/releases/latest")!

    public static func check(
        installedVersion: String?,
        completion: @escaping (Result<ReleaseUpdateStatus, Error>) -> Void
    ) {
        var request = URLRequest(url: apiURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CodexGlance", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let response = response as? HTTPURLResponse, let data else {
                completion(.failure(ReleaseUpdateError.invalidResponse))
                return
            }
            completion(Result {
                try evaluate(data: data, statusCode: response.statusCode, installedVersion: installedVersion)
            })
        }.resume()
    }

    static func evaluate(data: Data, statusCode: Int, installedVersion: String?) throws -> ReleaseUpdateStatus {
        guard statusCode == 200 else {
            throw ReleaseUpdateError.httpStatus(statusCode)
        }
        struct Release: Decodable {
            let tag_name: String
            let draft: Bool
            let prerelease: Bool
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              !release.draft, !release.prerelease,
              let latest = ReleaseVersion(release.tag_name) else {
            throw ReleaseUpdateError.invalidRelease
        }
        guard let installedVersion, let installed = ReleaseVersion(installedVersion) else {
            return .unknownInstalledVersion(latestVersion: release.tag_name)
        }
        return latest > installed
            ? .updateAvailable(version: release.tag_name)
            : .noNewerRelease(version: release.tag_name)
    }
}

// Stable release tags and bundle versions use one to three numeric components.
// Unknown formats are deliberately not treated as an up-to-date installation.
struct ReleaseVersion: Comparable {
    private let components: [Int]

    init?(_ value: String) {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") { value.removeFirst() }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy({
            !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) }
        }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        components = numbers + Array(repeating: 0, count: 3 - numbers.count)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}
