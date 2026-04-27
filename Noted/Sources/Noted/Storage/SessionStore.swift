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

enum SessionStore {
    static func createCanonicalDirectories(at directory: URL) throws {
        for name in ["runtime", "audio", "transcript", "diarization", "outputs", "logs"] {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }
}
