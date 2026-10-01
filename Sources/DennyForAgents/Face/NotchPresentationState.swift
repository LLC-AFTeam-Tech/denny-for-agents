import Foundation

public enum NotchPresentationState: Equatable, Sendable {
    case idle
    case listening
    case thinking
    case talking
    case downloading
    case extracting
    case ready
    case error
    case notification
    case unknown(String)

    public init(rawValue: String) {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "", "idle":
            self = .idle
        case "listening":
            self = .listening
        case "thinking":
            self = .thinking
        case "talking":
            self = .talking
        case "downloading":
            self = .downloading
        case "extracting":
            self = .extracting
        case "ready":
            self = .ready
        case "error":
            self = .error
        case "notification":
            self = .notification
        default:
            self = .unknown(normalized)
        }
    }

    public var rawValue: String {
        switch self {
        case .idle: return "idle"
        case .listening: return "listening"
        case .thinking: return "thinking"
        case .talking: return "talking"
        case .downloading: return "downloading"
        case .extracting: return "extracting"
        case .ready: return "ready"
        case .error: return "error"
        case .notification: return "notification"
        case .unknown(let value): return value
        }
    }
}

/// Kept for DennyFaceGestureAdmission; Denny for Agents only uses closed/nook.
public enum NotchSurfaceState: String, Equatable, Codable {
    case closed
    case nook
    case tray
    case dragging
}
