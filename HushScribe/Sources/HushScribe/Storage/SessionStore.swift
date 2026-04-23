import Foundation

struct SessionDescriptor: Sendable {
    let id: String
    let directory: URL
    let type: SessionType
    let startedAt: Date

    var rawDirectory: URL {
        directory.appendingPathComponent("raw", isDirectory: true)
    }

    var microphoneAudioURL: URL {
        rawDirectory.appendingPathComponent("microphone.wav")
    }

    var systemAudioURL: URL {
        rawDirectory.appendingPathComponent("system.wav")
    }
}

actor SessionStore {
    private let rootDirectory: URL

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    func createSession(type: SessionType) throws -> SessionDescriptor {
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"

        let startedAt = Date()
        let id = "\(formatter.string(from: startedAt))-\(UUID().uuidString.prefix(8).lowercased())"
        let directory = rootDirectory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("raw", isDirectory: true),
            withIntermediateDirectories: true
        )

        return SessionDescriptor(id: id, directory: directory, type: type, startedAt: startedAt)
    }

    func discardSession(_ descriptor: SessionDescriptor) throws {
        guard descriptor.directory.path.hasPrefix(rootDirectory.path) else { return }
        if FileManager.default.fileExists(atPath: descriptor.directory.path) {
            try FileManager.default.removeItem(at: descriptor.directory)
        }
    }
}
