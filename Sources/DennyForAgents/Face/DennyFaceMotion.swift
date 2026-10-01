import Foundation

public enum DennyFaceGesture: String, CaseIterable, Codable, Equatable, Sendable {
    case welcome
    case blush
    case shy
    case approval
    case joy
    case listening
    case speaking
    case thinking
    case confirmation
    case connectionLost
    case focus
    case `break`
    case singing
    case misheard
    case oops
    case idea
    case reassurance
    case restReminder
    case shutdown

    public var duration: TimeInterval {
        switch self {
        case .welcome: return 4.7
        case .blush, .shy: return 4.9
        case .approval: return 2.5
        case .joy: return 2.9
        case .listening: return 5.2
        case .speaking: return 4.5
        case .thinking, .confirmation, .connectionLost, .focus, .break: return 4.8
        case .singing: return 5.2
        case .misheard, .oops: return 4.8
        case .idea: return 4.5
        case .reassurance: return 5.2
        case .restReminder: return 5.4
        case .shutdown: return 1.5
        }
    }
}

public struct DennyFaceGestureCommand: Equatable, Sendable {
    public let id: Int
    public let gesture: DennyFaceGesture

    public init(id: Int, gesture: DennyFaceGesture) {
        self.id = id
        self.gesture = gesture
    }
}

public enum DennyFaceGestureAdmission {
    /// A gesture may resize the lightweight face surface, but must never
    /// replace the explicitly-open file/media tray or an active drag target.
    public static func canStart(in surfaceState: NotchSurfaceState) -> Bool {
        surfaceState == .closed || surfaceState == .nook
    }
}

public enum DennyFaceHandAsset: String, Hashable, Sendable {
    case open
    case index
    case fistLeft
    case fistRight
    case hugLeft
    case hugRight
    case shyLeft
    case shyRight
    case thumb
}

public struct DennyFaceHandPlacement: Equatable, Sendable {
    public let asset: DennyFaceHandAsset
    public let x: Double
    public let y: Double
    public let rotation: Double
    public let mirrored: Bool
    public let scale: Double
    public let opacity: Double

    public init(
        asset: DennyFaceHandAsset,
        x: Double,
        y: Double,
        rotation: Double = 0,
        mirrored: Bool = false,
        scale: Double = 1,
        opacity: Double = 1
    ) {
        self.asset = asset
        self.x = x
        self.y = y
        self.rotation = rotation
        self.mirrored = mirrored
        self.scale = scale
        self.opacity = opacity
    }
}

/// A pure, renderer-independent sample of the approved motion. The mouth is
/// deliberately absent: production speech continues to use audio-clocked
/// `SetMouth` poses, never the synthetic mouth sequence from the browser demo.
public struct DennyFaceMotionFrame: Equatable, Sendable {
    public var scale: Double = 1
    public var headX: Double = 0
    public var headY: Double = 0
    public var angle: Double = 0
    public var eyeX: Double = 0
    public var eyeY: Double = 0
    public var eyeClose: Double = 0
    public var leftEyeClose: Double = 0
    public var rightEyeClose: Double = 0
    public var browOffset: Double = 0
    public var browAsymmetry: Double = 0
    public var browTilt: Double = 0
    public var gazeX: Double = 0
    public var gazeY: Double = 0
    public var gestureMouthOpen: Double = 0
    public var blush: Double = 0
    public var pixelBlush: Double = 0
    public var accent: Double = 0
    public var faceScaleX: Double = 1
    public var faceScaleY: Double = 1
    public var faceOpacity: Double = 1
    public var shutdownLine: Double = 0
    public var remoteLift: Double = 0
    public var remotePress: Double = 0
    public var remoteOpacity: Double = 0
    public var leftHandX: Double = 40
    public var leftHandY: Double = 174
    public var leftHandRotation: Double = 32
    public var rightHandX: Double = 150
    public var rightHandY: Double = 174
    public var rightHandRotation: Double = -32
    public var palmReveal: Double = 0
    public var hands: [DennyFaceHandPlacement] = []

    public init() {}
}

private struct MotionKeyframe {
    let at: TimeInterval
    let frame: DennyFaceMotionFrame
}

public enum DennyFaceMotionTimeline {
    public static func frame(
        presentationState: NotchPresentationState,
        presentationElapsed: TimeInterval,
        gesture: DennyFaceGesture?,
        gestureElapsed: TimeInterval,
        emotion: DennyFaceEmotion = .calm,
        reduceMotion: Bool
    ) -> DennyFaceMotionFrame {
        guard !reduceMotion else { return DennyFaceMotionFrame() }

        if let gesture {
            if gesture != .shutdown, gestureElapsed >= gesture.duration {
                return DennyFaceMotionFrame()
            }
            switch gesture {
            case .welcome:
                var result = interpolate(welcomeFrames, at: clamped(gestureElapsed, 0, gesture.duration))
                result.hands = welcomeHands(at: gestureElapsed)
                result.pixelBlush = pulse(gestureElapsed, 3.1, 3.55, 4.05, 4.65)
                return result
            case .blush, .shy:
                var result = interpolate(blushFrames, at: clamped(gestureElapsed, 0, gesture.duration))
                result.hands = blushHands(at: gestureElapsed, frame: result)
                return result
            case .approval:
                var result = interpolate(approvalFrames, at: clamped(gestureElapsed, 0, gesture.duration))
                result.hands = approvalHands(at: gestureElapsed)
                return result
            case .joy:
                var result = interpolate(joyFrames, at: clamped(gestureElapsed, 0, gesture.duration))
                result.hands = joyHands(at: gestureElapsed)
                return result
            case .listening:
                return listeningFrame(at: gestureElapsed)
            case .speaking:
                return speakingGestureFrame(at: gestureElapsed)
            case .thinking:
                return thinkingFrame(at: gestureElapsed)
            case .confirmation:
                return confirmationFrame(at: gestureElapsed)
            case .connectionLost:
                return connectionLostFrame(at: gestureElapsed)
            case .focus:
                return focusFrame(at: gestureElapsed)
            case .break:
                return breakFrame(at: gestureElapsed)
            case .singing:
                return singingFrame(at: gestureElapsed)
            case .misheard:
                return misheardFrame(at: gestureElapsed)
            case .oops:
                return oopsFrame(at: gestureElapsed)
            case .idea:
                return ideaFrame(at: gestureElapsed)
            case .reassurance:
                return reassuranceFrame(at: gestureElapsed)
            case .restReminder:
                return restReminderFrame(at: gestureElapsed)
            case .shutdown:
                return shutdownFrame(at: clamped(gestureElapsed, 0, gesture.duration))
            }
        }

        if emotion == .focus {
            return focusFrame(at: presentationElapsed)
        }

        switch presentationState {
        case .listening:
            return listeningFrame(at: presentationElapsed)
        case .talking:
            let cycle = Int(max(0, presentationElapsed) / 14) % 3
            var result = interpolate(speakingFrames, at: positiveRemainder(presentationElapsed, 14))
            if cycle == 1 {
                result.headX *= -1
                result.angle *= -1
                result.eyeX *= -1
                result.browAsymmetry *= -1
                result.browTilt *= -1
            }
            result.hands = speakingHands(at: presentationElapsed)
            return result
        case .thinking:
            return thinkingFrame(at: presentationElapsed)
        case .error:
            return connectionLostFrame(at: presentationElapsed)
        default:
            return DennyFaceMotionFrame()
        }
    }

    private static let speakingFrames: [MotionKeyframe] = [
        key(0),
        key(0.7, headX: -1, angle: -2, browAsymmetry: -1, browTilt: -2),
        key(1.45, headX: -2, headY: 1, angle: -3, eyeClose: 0.18, browAsymmetry: -1.5, browTilt: -3),
        key(2.35, headX: -1, angle: -1, browOffset: -1),
        key(3.1),
        key(5.6, headX: 1, angle: 1),
        key(7.35, headX: 2, headY: 1, angle: 3, eyeClose: 0.14, browAsymmetry: 1.5, browTilt: 3),
        key(8.35, headX: 1, angle: 1, browOffset: -1),
        key(9.1),
        key(12.4, headY: 0.5, eyeClose: 0.12),
        key(14)
    ]

    private static let welcomeFrames: [MotionKeyframe] = [
        key(0),
        key(0.35, headY: -1, eyeY: -1, browOffset: -2, gestureMouthOpen: 4),
        key(0.75, headY: -3, eyeY: -1, browOffset: -3, gestureMouthOpen: 12),
        key(1.05, headY: -2, browOffset: -3, gestureMouthOpen: 12),
        key(1.35, headY: -2, browOffset: -3, gestureMouthOpen: 12),
        key(1.65, headY: -2, browOffset: -3, gestureMouthOpen: 12),
        key(1.95, headY: -1, browOffset: -2, gestureMouthOpen: 10),
        key(2.4, browOffset: -2, gestureMouthOpen: 9),
        key(2.95, headY: 2, eyeY: 1, eyeClose: 0.85, gestureMouthOpen: 9, blush: 0.35),
        key(3.55, headY: 2, eyeY: 1, eyeClose: 0.85, gestureMouthOpen: 7, blush: 0.35),
        key(4.1, eyeClose: 0.15, gestureMouthOpen: 4),
        key(4.7)
    ]

    private static let blushFrames: [MotionKeyframe] = [
        key(0),
        key(0.28, headY: 1.2, angle: -1, eyeX: -1.5, eyeY: 2, eyeClose: 0.18, browOffset: 1, gazeY: 3),
        key(0.85, headY: 2, angle: -2, eyeX: -3, eyeY: 4, eyeClose: 0.5, gazeY: 4, blush: 0.55, leftHandX: 56, leftHandY: 127, leftHandRotation: 48, rightHandX: 134, rightHandY: 129, rightHandRotation: -48),
        key(1.45, headY: 2, angle: -1, eyeX: 2, eyeY: 3, eyeClose: 0.48, gazeY: 3, blush: 0.8, leftHandX: 65, leftHandY: 123, leftHandRotation: 66, rightHandX: 125, rightHandY: 125, rightHandRotation: -66),
        key(1.85, headY: 1.5, angle: 1, eyeX: 3, eyeY: 2, eyeClose: 0.52, blush: 0.8, leftHandX: 63, leftHandY: 125, leftHandRotation: 58, rightHandX: 127, rightHandY: 123, rightHandRotation: -58),
        key(2.2, headY: 1, eyeX: 1, eyeY: 2, eyeClose: 0.9, blush: 0.65, leftHandX: 60, leftHandY: 130, leftHandRotation: 55, rightHandX: 130, rightHandY: 130, rightHandRotation: -55),
        key(2.6, headY: -0.5, angle: 1, eyeX: 2, eyeY: -2, eyeClose: 0.88, gestureMouthOpen: 9, blush: 0.6, leftHandX: 46, leftHandY: 124, leftHandRotation: -10, rightHandX: 144, rightHandY: 124, rightHandRotation: 10, palmReveal: 1),
        key(3.25, headY: -1, angle: -1, eyeX: -2, eyeY: -3, eyeClose: 0.88, gestureMouthOpen: 12, blush: 0.65, leftHandX: 43, leftHandY: 119, leftHandRotation: -17, rightHandX: 147, rightHandY: 121, rightHandRotation: 17, palmReveal: 1),
        key(3.8, eyeX: 1, eyeY: -1, eyeClose: 0.72, gestureMouthOpen: 5, blush: 0.45, leftHandX: 48, leftHandY: 127, leftHandRotation: -5, rightHandX: 142, rightHandY: 127, rightHandRotation: 5, palmReveal: 1),
        key(4.35, headY: 0.5, eyeClose: 0.2, blush: 0.1, leftHandX: 40, leftHandY: 156, leftHandRotation: 20, rightHandX: 150, rightHandY: 156, rightHandRotation: -20, palmReveal: 1),
        key(4.9)
    ]

    private static let approvalFrames: [MotionKeyframe] = [
        key(0),
        key(0.35, eyeX: -2, browOffset: -1),
        key(0.85, headX: -1, angle: -2, browOffset: -3, gestureMouthOpen: 5),
        key(1.3, headX: -2, angle: -3, leftEyeClose: 1, browOffset: -3, browAsymmetry: -2, gestureMouthOpen: 12, accent: 1),
        key(1.75, headX: -1, angle: -2, leftEyeClose: 1, browOffset: -2, gestureMouthOpen: 9, accent: 0.65),
        key(2.15, gestureMouthOpen: 4),
        key(2.5)
    ]

    private static let joyFrames: [MotionKeyframe] = [
        key(0, browOffset: -1, gestureMouthOpen: 4),
        key(0.55, scale: 0.97, headY: 2, eyeClose: 0.25, browOffset: -2, gestureMouthOpen: 5),
        key(1.05, scale: 0.95, headY: 3, eyeClose: 0.72, browOffset: -3, gestureMouthOpen: 8),
        key(1.45, scale: 1.02, headY: -3, eyeClose: 1, browOffset: -4, gestureMouthOpen: 14, accent: 1),
        key(1.95, headY: -2, eyeClose: 1, browOffset: -3, gestureMouthOpen: 13, accent: 0.7),
        key(2.4, eyeClose: 0.2, gestureMouthOpen: 6),
        key(2.9)
    ]

    private static func listeningFrame(at elapsed: TimeInterval) -> DennyFaceMotionFrame {
        let opening = clamped(elapsed, 0, 4.4)
        let lean = pulse(opening, 0.15, 0.7, 3.2, 4.1)
        let nod = pulse(opening, 2.85, 3.15, 3.25, 3.65)
            + 0.5 * pulse(positiveRemainder(max(0, elapsed - 5), 17.5), 5.1, 5.34, 5.5, 5.82)
            + 0.35 * pulse(positiveRemainder(max(0, elapsed - 5), 17.5), 13.2, 13.42, 13.58, 13.9)
        var result = DennyFaceMotionFrame()
        result.headX = -2.5 * lean
        result.headY = 2 * nod
        result.angle = -4 * lean
        result.eyeX = -3 * lean
        result.eyeY = nod
        result.browOffset = -1.5 * lean
        let hand = pulse(opening, 0.45, 0.95, 3.05, 3.9)
        if hand > 0.001 {
            result.hands = [DennyFaceHandPlacement(
                asset: .open,
                x: 39 - 3 * hand,
                y: 155 - 60 * hand,
                rotation: -82 + 8 * hand,
                opacity: min(1, hand * 4)
            )]
        }
        return result
    }

    private static func speakingHands(at elapsed: TimeInterval) -> [DennyFaceHandPlacement] {
        let value = positiveRemainder(elapsed, 14)
        let cycle = Int(max(0, elapsed) / 14) % 3
        let explainStart = cycle == 1 ? 1.4 : (cycle == 2 ? 0.9 : 0.65)
        let accentStart = cycle == 1 ? 8.5 : (cycle == 2 ? 6.3 : 7)
        let side = cycle == 1 ? -1.0 : 1.0
        // Head/gaze keyframes begin first. Hands intentionally lag by about
        // 180ms so the whole character does not move like one rigid part.
        let explain = beat(
            value,
            explainStart + 0.18,
            explainStart + 0.68,
            explainStart + 1.45,
            explainStart + 2.05
        )
        if explain > 0.001 {
            return [articulatedHand(side: side, k: explain, lag: explain, asset: .open)]
        }
        let accent = beat(
            value,
            accentStart + 0.18,
            accentStart + 0.5,
            accentStart + 0.98,
            accentStart + 1.48
        )
        if accent > 0.001 {
            return [articulatedHand(side: side, k: accent, lag: accent, asset: .index)]
        }
        return []
    }

    private static func speakingGestureFrame(at elapsed: TimeInterval) -> DennyFaceMotionFrame {
        let explain = pulse(elapsed, 0.2, 0.55, 1.45, 2.05)
        let emphasis = pulse(elapsed, 2.3, 2.7, 3.65, 4.3)
        var result = DennyFaceMotionFrame()
        result.headX = -2 * explain + 2 * emphasis
        result.headY = -0.8 * (explain + emphasis)
        result.angle = -2.5 * explain + 2.5 * emphasis
        result.eyeX = -2 * explain + 2 * emphasis
        result.browOffset = -1.5 * (explain + emphasis)
        result.browAsymmetry = -1.5 * explain + 1.5 * emphasis
        if explain > 0.001 {
            result.hands = [articulatedHand(side: -1, k: explain, lag: explain, asset: .open)]
        } else if emphasis > 0.001 {
            result.hands = [articulatedHand(side: 1, k: emphasis, lag: emphasis, asset: .index)]
        }
        // Speech owns the mouth through SetMouth. The reaction contributes
        // only gaze, brows, head motion and occasional hand accents.
        result.gestureMouthOpen = 0
        return result
    }

    private static func thinkingFrame(at elapsed: TimeInterval) -> DennyFaceMotionFrame {
        let look = pulse(elapsed, 0.08, 0.42, 3.15, 4.05)
        let hand = pulse(elapsed, 0.38, 0.82, 2.75, 3.7)
        var result = DennyFaceMotionFrame()
        result.angle = 2.5 * look
        result.eyeX = 3.5 * look
        result.eyeY = -4 * look
        result.browOffset = -1 * look
        result.browTilt = 4 * look
        if hand > 0.001 {
            result.hands = [DennyFaceHandPlacement(
                asset: .index,
                x: 136 - 13 * hand,
                y: 155 - 42 * hand,
                rotation: -58,
                opacity: min(1, hand * 4)
            )]
        }
        return result
    }

    private static func connectionLostFrame(at elapsed: TimeInterval) -> DennyFaceMotionFrame {
        let puzzled = pulse(elapsed, 0.05, 0.42, 2.75, 3.7)
        let hands = pulse(elapsed, 0.42, 0.88, 2.4, 3.4)
        var result = DennyFaceMotionFrame()
        result.headY = 1.5 * puzzled
        result.angle = -1.5 * puzzled
        result.eyeX = -3 * puzzled
        result.browOffset = 1.5 * puzzled
        result.browTilt = -5 * puzzled
        if hands > 0.001 {
            result.hands = [
                DennyFaceHandPlacement(
                    asset: .open,
                    x: 46,
                    y: 164 - 39 * hands,
                    rotation: 63,
                    mirrored: true,
                    opacity: min(1, hands * 4)
                ),
                DennyFaceHandPlacement(
                    asset: .open,
                    x: 144,
                    y: 164 - 39 * hands,
                    rotation: -63,
                    opacity: min(1, hands * 4)
                )
            ]
        }
        return result
    }

    private static func confirmationFrame(at elapsed: TimeInterval) -> DennyFaceMotionFrame {
        let ask = pulse(elapsed, 0.08, 0.48, 3.35, 4.55)
        let hands = pulse(elapsed, 0.5, 0.95, 3.05, 4.15)
        var result = DennyFaceMotionFrame()
        result.headY = -ask
        result.angle = -2 * ask
        result.eyeX = -2 * ask
        result.browOffset = -2 * ask
        result.browAsymmetry = 2.5 * ask
        result.gestureMouthOpen = 4 * ask
        if hands > 0.001 {
            result.hands = [
                DennyFaceHandPlacement(
                    asset: .open,
                    x: 50,
                    y: 165 - 45 * hands,
                    rotation: 28,
                    mirrored: true,
                    opacity: min(1, hands * 4)
                ),
                DennyFaceHandPlacement(
                    asset: .open,
                    x: 140,
                    y: 165 - 45 * hands,
                    rotation: -28,
                    opacity: min(1, hands * 4)
                )
            ]
        }
        return result
    }

    private static func breakFrame(at elapsed: TimeInterval) -> DennyFaceMotionFrame {
        let stretch = pulse(elapsed, 0.12, 0.72, 3.15, 4.55)
        var result = DennyFaceMotionFrame()
        result.scale = 1 - 0.03 * stretch
        result.headY = 3 * stretch
        result.eyeClose = 0.8 * stretch
        result.browOffset = -2 * stretch
        result.gestureMouthOpen = 8 * stretch
        result.hands = stretch > 0.001 ? [
            DennyFaceHandPlacement(
                asset: .fistLeft,
                x: 52,
                y: 169 - 80 * stretch,
                rotation: -15,
                opacity: min(1, stretch * 4)
            ),
            DennyFaceHandPlacement(
                asset: .fistRight,
                x: 138,
                y: 169 - 80 * stretch,
                rotation: 15,
                opacity: min(1, stretch * 4)
            )
        ] : []
        return result
    }

    private static func singingFrame(at elapsed: TimeInterval) -> DennyFaceMotionFrame {
        // Mirrors the approved textured-rig story: notice the music, lift
        // both fists, sway for two unhurried beats, then settle. The former
        // implementation anchored the fists below the 145pt canvas, leaving
        // only tiny disconnected fingertips visible in the real notch.
        let envelope = pulse(elapsed, 0.18, 0.72, 4.18, 5.08)
        let hands = pulse(elapsed, 0.48, 1.02, 3.92, 4.68)
        let rhythmEnvelope = pulse(elapsed, 0.82, 1.16, 3.72, 4.28)
        let rhythm = sin((elapsed - 0.92) * .pi * 1.7)
        var result = DennyFaceMotionFrame()
        result.headX = 0.8 * rhythm * rhythmEnvelope
        result.headY = -0.9 * abs(rhythm) * rhythmEnvelope
        result.angle = 1.35 * rhythm * rhythmEnvelope
        result.eyeClose = 0.18 * envelope
        result.browOffset = -1.4 * envelope
        result.gestureMouthOpen = (5.2 + 1.1 * max(0, rhythm)) * envelope
        result.accent = 0.55 * rhythmEnvelope
        if hands > 0.001 {
            let alternatingLift = 7 * rhythm * rhythmEnvelope
            result.hands = [
                DennyFaceHandPlacement(
                    asset: .fistLeft,
                    x: 49,
                    y: 116 - alternatingLift,
                    rotation: -7 + 4 * rhythm * rhythmEnvelope,
                    scale: 1.28,
                    opacity: min(1, hands * 4)
                ),
                DennyFaceHandPlacement(
                    asset: .fistRight,
                    x: 141,
                    y: 116 + alternatingLift,
                    rotation: 7 - 4 * rhythm * rhythmEnvelope,
                    scale: 1.28,
                    opacity: min(1, hands * 4)
                )
            ]
        }
        return result
    }

    private static func misheardFrame(at elapsed: TimeInterval) -> DennyFaceMotionFrame {
        let listen = pulse(elapsed, 0.08, 0.55, 3.25, 4.55)
        let hand = pulse(elapsed, 0.5, 0.95, 3.05, 4.15)
        var result = DennyFaceMotionFrame()
        result.headX = -2 * listen
        result.angle = -4 * listen
        result.eyeX = -3 * listen
        result.browOffset = -listen
        result.browAsymmetry = 3 * listen
        result.gestureMouthOpen = 2 * listen
        if hand > 0.001 {
            result.hands = [DennyFaceHandPlacement(
                asset: .open,
                x: 39,
                y: 157 - 57 * hand,
                rotation: -78,
                opacity: min(1, hand * 4)
            )]
        }
        return result
    }

    private static func oopsFrame(at elapsed: TimeInterval) -> DennyFaceMotionFrame {
        let notice = pulse(elapsed, 0.05, 0.35, 3.45, 4.55)
        let hand = pulse(elapsed, 0.55, 0.95, 2.9, 4.05)
        var result = DennyFaceMotionFrame()
        result.headY = 2 * notice
        result.angle = 2.5 * notice
        result.eyeY = 2 * notice
        result.eyeClose = 0.24 * notice
        result.browOffset = 1.5 * notice
        result.browAsymmetry = -2 * notice
        result.gestureMouthOpen = 4 * notice
        result.blush = 0.35 * notice
        if hand > 0.001 {
            result.hands = [DennyFaceHandPlacement(
                asset: .open,
                x: 135,
                y: 159 - 67 * hand,
                rotation: -48,
                opacity: min(1, hand * 4)
            )]
        }
        return result
    }

    private static func ideaFrame(at elapsed: TimeInterval) -> DennyFaceMotionFrame {
        let thought = pulse(elapsed, 0.06, 0.45, 3.1, 4.25)
        let hand = pulse(elapsed, 0.45, 0.85, 2.9, 3.95)
        let found = pulse(elapsed, 1.55, 1.85, 2.8, 3.55)
        var result = DennyFaceMotionFrame()
        result.headY = -2 * found
        result.angle = 2 * thought
        result.eyeX = 3 * thought
        result.eyeY = -3 * thought
        result.browOffset = -3 * found
        result.gestureMouthOpen = 7 * found
        result.accent = found
        if hand > 0.001 {
            result.hands = [DennyFaceHandPlacement(
                asset: .index,
                x: 48,
                y: 159 - 61 * hand,
                rotation: 55,
                mirrored: true,
                opacity: min(1, hand * 4)
            )]
        }
        return result
    }

    private static func reassuranceFrame(at elapsed: TimeInterval) -> DennyFaceMotionFrame {
        let support = pulse(elapsed, 0.08, 0.55, 3.7, 4.95)
        let hand = pulse(elapsed, 0.65, 1.05, 3.3, 4.55)
        let nod = pulse(elapsed, 2.05, 2.35, 2.55, 2.9)
        var result = DennyFaceMotionFrame()
        result.headY = 1.5 * nod
        result.angle = -2 * support
        result.eyeX = 2 * support
        result.browOffset = -1.5 * support
        result.gestureMouthOpen = 4 * support
        if hand > 0.001 {
            result.hands = [DennyFaceHandPlacement(
                asset: .open,
                x: 142,
                y: 164 - 43 * hand,
                rotation: -12,
                opacity: min(1, hand * 4)
            )]
        }
        return result
    }

    private static func restReminderFrame(at elapsed: TimeInterval) -> DennyFaceMotionFrame {
        let tired = pulse(elapsed, 0.08, 0.55, 4.05, 5.15)
        let hand = pulse(elapsed, 0.8, 1.2, 3.45, 4.7)
        var result = DennyFaceMotionFrame()
        result.headY = 2.5 * tired
        result.angle = 2 * tired
        result.eyeClose = 0.72 * tired
        result.browOffset = 1.5 * tired
        result.gestureMouthOpen = 7 * tired
        if hand > 0.001 {
            result.hands = [DennyFaceHandPlacement(
                asset: .shyRight,
                x: 137,
                y: 160 - 54 * hand,
                rotation: -22,
                opacity: min(1, hand * 4)
            )]
        }
        return result
    }

    private static func focusFrame(at elapsed: TimeInterval) -> DennyFaceMotionFrame {
        let intent = pulse(elapsed, 0.08, 0.4, 2.65, 3.55)
        let hand = pulse(elapsed, 0.44, 0.82, 2.25, 3.2)
        var result = DennyFaceMotionFrame()
        result.headY = intent
        result.eyeY = 1.5 * intent
        result.browOffset = intent
        result.eyeClose = 0.16 * intent
        if hand > 0.001 {
            result.hands = [DennyFaceHandPlacement(
                asset: .index,
                x: 136 - 18 * hand,
                y: 157 - 48 * hand,
                rotation: -67,
                opacity: min(1, hand * 4)
            )]
        }
        return result
    }

    private static func articulatedHand(
        side: Double,
        k: Double,
        lag: Double,
        asset: DennyFaceHandAsset
    ) -> DennyFaceHandPlacement {
        let shoulderX = 95 + side * 47
        let shoulderY = 149.0
        let upper = (75 - 72 * k) * .pi / 180
        let lower = (88 - 185 * k) * .pi / 180
        let elbowX = shoulderX + side * 27 * cos(upper)
        let elbowY = shoulderY + 27 * sin(upper)
        let x = elbowX + side * 29 * cos(lower)
        let y = elbowY + 29 * sin(lower)
        let rotation = asset == .index ? side * (6 - 9 * lag) : side * (12 - 28 * lag)
        return DennyFaceHandPlacement(
            asset: asset,
            x: x,
            y: y,
            rotation: rotation,
            mirrored: side < 0,
            opacity: min(1, k * 4)
        )
    }

    private static func welcomeHands(at elapsed: TimeInterval) -> [DennyFaceHandPlacement] {
        let value = clamped(elapsed, 0, DennyFaceGesture.welcome.duration)
        if value < 2.18 {
            let lift = smooth((value - 0.35) / 0.45)
            let down = smooth((value - 1.78) / 0.4)
            let swing = value > 0.8 && value < 1.8
                ? sin((value - 0.8) * .pi * 4) * 13
                : 0
            let y = mix(179, 113, lift * (1 - down))
            return [DennyFaceHandPlacement(asset: .open, x: 160, y: y, rotation: swing)]
        }

        let reach = smooth((value - 2.18) / 0.32)
        let hug = smooth((value - 2.5) / 0.6)
        let release = smooth((value - 3.6) / 0.7)
        let x = mix(mix(32, 70, hug), 42, release)
        let y = mix(mix(166, 140, reach), 172, release)
        return [
            DennyFaceHandPlacement(asset: .hugLeft, x: x, y: y, rotation: -8 * (1 - hug)),
            DennyFaceHandPlacement(asset: .hugRight, x: 190 - x, y: y, rotation: 8 * (1 - hug))
        ]
    }

    private static func blushHands(at elapsed: TimeInterval, frame: DennyFaceMotionFrame) -> [DennyFaceHandPlacement] {
        // Hand coordinates are intentionally interpolated separately because
        // the final approved palm correction changes only palm orientation.
        let palm = frame.palmReveal
        let leftPointRotation = (frame.leftHandRotation - 60) * 0.3
        let rightPointRotation = (frame.rightHandRotation + 60) * 0.3
        if elapsed >= 3.45 {
            let settle = pulse(elapsed, 3.45, 3.75, 4.15, 4.75)
            return [DennyFaceHandPlacement(
                asset: .open,
                x: 95,
                y: 153 - 24 * settle,
                rotation: -8,
                opacity: min(1, settle * 4)
            )]
        }
        return [
            DennyFaceHandPlacement(asset: .shyLeft, x: frame.leftHandX, y: frame.leftHandY + 9, rotation: leftPointRotation, opacity: 1 - palm),
            DennyFaceHandPlacement(asset: .shyRight, x: frame.rightHandX, y: frame.rightHandY + 9, rotation: rightPointRotation, opacity: 1 - palm),
            DennyFaceHandPlacement(asset: .open, x: frame.leftHandX, y: frame.leftHandY + 9, rotation: -28, opacity: palm),
            DennyFaceHandPlacement(asset: .open, x: frame.rightHandX, y: frame.rightHandY + 9, rotation: 28, mirrored: true, opacity: palm)
        ].filter { $0.opacity > 0.001 }
    }

    private static func approvalHands(at elapsed: TimeInterval) -> [DennyFaceHandPlacement] {
        let lift = pulse(elapsed, 0.25, 0.65, 1.85, 2.42)
        guard lift > 0.001 else { return [] }
        return [DennyFaceHandPlacement(
            asset: .thumb,
            x: 43,
            y: 162 - 58 * lift,
            rotation: -5,
            opacity: min(1, lift * 4)
        )]
    }

    private static func joyHands(at elapsed: TimeInterval) -> [DennyFaceHandPlacement] {
        let lift = pulse(elapsed, 0.18, 0.62, 2.05, 2.75)
        guard lift > 0.001 else { return [] }
        let fists = smooth((elapsed - 0.82) / 0.28)
        let leftAsset: DennyFaceHandAsset = fists > 0.5 ? .fistLeft : .open
        let rightAsset: DennyFaceHandAsset = fists > 0.5 ? .fistRight : .open
        return [
            DennyFaceHandPlacement(
                asset: leftAsset,
                x: 54 - 7 * lift,
                y: 169 - 65 * lift,
                rotation: -12 + 8 * lift,
                mirrored: leftAsset == .open,
                opacity: min(1, lift * 4)
            ),
            DennyFaceHandPlacement(
                asset: rightAsset,
                x: 136 + 7 * lift,
                y: 169 - 65 * lift,
                rotation: 12 - 8 * lift,
                opacity: min(1, lift * 4)
            )
        ]
    }

    private static func shutdownFrame(at elapsed: TimeInterval) -> DennyFaceMotionFrame {
        var result = DennyFaceMotionFrame()
        result.browOffset = -1
        result.gestureMouthOpen = 5
        result.remoteLift = smooth(elapsed / 0.3)
        result.remotePress = smooth((elapsed - 0.45) / 0.15)
            * (1 - smooth((elapsed - 0.75) / 0.15))
        result.remoteOpacity = 1 - smooth((elapsed - 0.85) / 0.2)
        let squeeze = smooth((elapsed - 0.75) / 0.3)
        result.faceScaleX = 1 - 0.2 * squeeze
        result.faceScaleY = max(0.001, 1 - squeeze)
        result.faceOpacity = 1 - smooth((elapsed - 1.05) / 0.32)
        result.shutdownLine = smooth((elapsed - 0.88) / 0.24)
            * (1 - smooth((elapsed - 1.12) / 0.25))
        return result
    }

    private static func interpolate(_ keyframes: [MotionKeyframe], at time: TimeInterval) -> DennyFaceMotionFrame {
        guard let first = keyframes.first, time > first.at else { return keyframes.first?.frame ?? DennyFaceMotionFrame() }
        guard let upperIndex = keyframes.firstIndex(where: { $0.at >= time }) else {
            return keyframes.last?.frame ?? DennyFaceMotionFrame()
        }
        let lower = keyframes[upperIndex - 1]
        let upper = keyframes[upperIndex]
        let progress = smooth((time - lower.at) / (upper.at - lower.at))
        return lerp(lower.frame, upper.frame, progress)
    }

    private static func lerp(_ a: DennyFaceMotionFrame, _ b: DennyFaceMotionFrame, _ t: Double) -> DennyFaceMotionFrame {
        func value(_ lhs: Double, _ rhs: Double) -> Double { mix(lhs, rhs, t) }
        var result = DennyFaceMotionFrame()
        result.scale = value(a.scale, b.scale)
        result.headX = value(a.headX, b.headX)
        result.headY = value(a.headY, b.headY)
        result.angle = value(a.angle, b.angle)
        result.eyeX = value(a.eyeX, b.eyeX)
        result.eyeY = value(a.eyeY, b.eyeY)
        result.eyeClose = value(a.eyeClose, b.eyeClose)
        result.leftEyeClose = value(a.leftEyeClose, b.leftEyeClose)
        result.rightEyeClose = value(a.rightEyeClose, b.rightEyeClose)
        result.browOffset = value(a.browOffset, b.browOffset)
        result.browAsymmetry = value(a.browAsymmetry, b.browAsymmetry)
        result.browTilt = value(a.browTilt, b.browTilt)
        result.gazeX = value(a.gazeX, b.gazeX)
        result.gazeY = value(a.gazeY, b.gazeY)
        result.gestureMouthOpen = value(a.gestureMouthOpen, b.gestureMouthOpen)
        result.blush = value(a.blush, b.blush)
        result.accent = value(a.accent, b.accent)
        result.leftHandX = value(a.leftHandX, b.leftHandX)
        result.leftHandY = value(a.leftHandY, b.leftHandY)
        result.leftHandRotation = value(a.leftHandRotation, b.leftHandRotation)
        result.rightHandX = value(a.rightHandX, b.rightHandX)
        result.rightHandY = value(a.rightHandY, b.rightHandY)
        result.rightHandRotation = value(a.rightHandRotation, b.rightHandRotation)
        result.palmReveal = value(a.palmReveal, b.palmReveal)
        return result
    }

    private static func key(
        _ at: TimeInterval,
        scale: Double = 1,
        headX: Double = 0,
        headY: Double = 0,
        angle: Double = 0,
        eyeX: Double = 0,
        eyeY: Double = 0,
        eyeClose: Double = 0,
        leftEyeClose: Double = 0,
        rightEyeClose: Double = 0,
        browOffset: Double = 0,
        browAsymmetry: Double = 0,
        browTilt: Double = 0,
        gazeX: Double = 0,
        gazeY: Double = 0,
        gestureMouthOpen: Double = 0,
        blush: Double = 0,
        accent: Double = 0,
        leftHandX: Double = 40,
        leftHandY: Double = 174,
        leftHandRotation: Double = 32,
        rightHandX: Double = 150,
        rightHandY: Double = 174,
        rightHandRotation: Double = -32,
        palmReveal: Double = 0
    ) -> MotionKeyframe {
        var frame = DennyFaceMotionFrame()
        frame.scale = scale
        frame.headX = headX
        frame.headY = headY
        frame.angle = angle
        frame.eyeX = eyeX
        frame.eyeY = eyeY
        frame.eyeClose = eyeClose
        frame.leftEyeClose = leftEyeClose
        frame.rightEyeClose = rightEyeClose
        frame.browOffset = browOffset
        frame.browAsymmetry = browAsymmetry
        frame.browTilt = browTilt
        frame.gazeX = gazeX
        frame.gazeY = gazeY
        frame.gestureMouthOpen = gestureMouthOpen
        frame.blush = blush
        frame.accent = accent
        frame.leftHandX = leftHandX
        frame.leftHandY = leftHandY
        frame.leftHandRotation = leftHandRotation
        frame.rightHandX = rightHandX
        frame.rightHandY = rightHandY
        frame.rightHandRotation = rightHandRotation
        frame.palmReveal = palmReveal
        return MotionKeyframe(at: at, frame: frame)
    }

    private static func pulse(_ value: Double, _ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
        smooth((value - a) / (b - a)) * (1 - smooth((value - c) / (d - c)))
    }

    private static func beat(_ value: Double, _ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
        pulse(value, a, b, c, d)
    }

    private static func smooth(_ value: Double) -> Double {
        let bounded = clamped(value, 0, 1)
        return bounded * bounded * (3 - 2 * bounded)
    }

    private static func mix(_ a: Double, _ b: Double, _ amount: Double) -> Double {
        a + (b - a) * amount
    }

    private static func clamped(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(upper, max(lower, value))
    }

    private static func positiveRemainder(_ value: Double, _ divisor: Double) -> Double {
        let result = value.truncatingRemainder(dividingBy: divisor)
        return result >= 0 ? result : result + divisor
    }
}
