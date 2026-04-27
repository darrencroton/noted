import Foundation

struct SessionDescriptor: Sendable {
    let id: String
    let directory: URL
    let type: SessionType
    let startedAt: Date
    let audioStrategy: String

    init(
        id: String,
        directory: URL,
        type: SessionType,
        startedAt: Date,
        audioStrategy: String = "room_mic"
    ) {
        self.id = id
        self.directory = directory
        self.type = type
        self.startedAt = startedAt
        self.audioStrategy = audioStrategy
    }

    var audioDirectory: URL {
        directory.appendingPathComponent("audio", isDirectory: true)
    }

    var transcriptDirectory: URL {
        directory.appendingPathComponent("transcript", isDirectory: true)
    }

    var diarizationDirectory: URL {
        directory.appendingPathComponent("diarization", isDirectory: true)
    }

    var runtimeDirectory: URL {
        directory.appendingPathComponent("runtime", isDirectory: true)
    }

    var microphoneAudioURL: URL {
        if audioStrategy == "mic_plus_system" {
            return audioDirectory.appendingPathComponent("raw_mic.wav")
        }
        return audioDirectory.appendingPathComponent("raw_room.wav")
    }

    var systemAudioURL: URL {
        audioDirectory.appendingPathComponent("raw_system.wav")
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
        try Self.createCanonicalDirectories(at: directory)

        return SessionDescriptor(id: id, directory: directory, type: type, startedAt: startedAt)
    }

    static func createCanonicalDirectories(at directory: URL) throws {
        for name in ["runtime", "audio", "transcript", "diarization", "outputs", "logs"] {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    func discardSession(_ descriptor: SessionDescriptor) throws {
        guard descriptor.directory.path.hasPrefix(rootDirectory.path) else { return }
        if FileManager.default.fileExists(atPath: descriptor.directory.path) {
            try FileManager.default.removeItem(at: descriptor.directory)
        }
    }
}
