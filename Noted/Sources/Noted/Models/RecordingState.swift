import Foundation
import Observation

enum SessionPhase: String, Codable, Sendable {
    case idle
    case starting
    case recording
    case stopping
    case processing
    case failed

    var menuTitle: String {
        switch self {
        case .idle: return "Idle"
        case .starting: return "Starting"
        case .recording: return "Recording"
        case .stopping: return "Stopping"
        case .processing: return "Processing"
        case .failed: return "Failed"
        }
    }
}

@Observable
@MainActor
final class RecordingState {
    var phase: SessionPhase = .idle
    var currentSessionID: String?
    var currentSessionDirectory: URL?
    var startedAt: Date?
    var lastError: String?

    var isRecording: Bool { phase == .starting || phase == .recording }
    var isBusy: Bool { phase == .starting || phase == .recording || phase == .stopping }

    func reset() {
        phase = .idle
        currentSessionID = nil
        currentSessionDirectory = nil
        startedAt = nil
        lastError = nil
    }
}
