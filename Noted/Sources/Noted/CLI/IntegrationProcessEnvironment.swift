import Foundation

enum IntegrationProcessEnvironment {
    private static let defaultExecutableSearchPaths = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/../bin").path,
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    static func environment(extraExecutableSearchPaths: [String] = []) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let fallbackPath = defaultExecutableSearchPaths.joined(separator: ":")
        let existingPath = [environment["PATH"], fallbackPath]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ":")
        environment["PATH"] = mergedPath(
            existingPath: existingPath,
            extraPaths: extraExecutableSearchPaths
        )
        return environment
    }

    static func briefingHandoffSearchPaths(sessionDir: URL) -> [String] {
        let sessionsDir = sessionDir.deletingLastPathComponent()
        guard sessionsDir.lastPathComponent == "sessions" else {
            return []
        }
        let briefingRoot = sessionsDir.deletingLastPathComponent()
        return [
            briefingRoot.appendingPathComponent(".venv/bin", isDirectory: true).path,
        ]
    }

    static func mergedPath(existingPath: String?, extraPaths: [String]) -> String {
        var seen = Set<String>()
        var merged: [String] = []

        func append(_ path: String) {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else {
                return
            }
            merged.append(trimmed)
        }

        for path in extraPaths {
            append(path)
        }
        for path in (existingPath ?? "").split(separator: ":") {
            append(String(path))
        }
        return merged.joined(separator: ":")
    }
}
