import Foundation

public enum DennyFaceAge: String, CaseIterable, Codable, Equatable, Sendable {
    case child
    case teenager
    case adult

    public init?(normalizing rawValue: String) {
        self.init(rawValue: rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    public static func forGrowthStage(_ stage: String) -> DennyFaceAge {
        switch stage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "kindred": return .adult
        case "familiar": return .teenager
        default: return .child
        }
    }
}

/// Compatibility name retained on the wire while Denny now has one permanent
/// face. Age changes movement character only; it never selects different face
/// geometry or a different set of speech poses.
public struct DennyFaceMotionProfile: Equatable, Sendable {
    public let movementScale: Double
    public let gazeScale: Double
    public let breathingAmplitude: Double
    public let blinkInterval: Double

    public static func forAge(_ age: DennyFaceAge) -> DennyFaceMotionProfile {
        switch age {
        case .child:
            return DennyFaceMotionProfile(
                movementScale: 1,
                gazeScale: 1,
                breathingAmplitude: 0.55,
                blinkInterval: 4.8
            )
        case .teenager:
            return DennyFaceMotionProfile(
                movementScale: 0.84,
                gazeScale: 0.86,
                breathingAmplitude: 0.44,
                blinkInterval: 5.7
            )
        case .adult:
            return DennyFaceMotionProfile(
                movementScale: 0.66,
                gazeScale: 0.62,
                breathingAmplitude: 0.32,
                blinkInterval: 6.4
            )
        }
    }
}

public enum DennyFaceExpression: String, CaseIterable, Equatable, Sendable {
    case attention
    case doubt
    case joy
    case anxiety
}

/// The single approved Denny face has twelve semantic poses. These are kept
/// separate from `NotchPresentationState`: changing an eyebrow or gaze must
/// never, by itself, expand the native surface over the user's work.
public enum DennyFaceEmotion: String, CaseIterable, Codable, Equatable, Sendable {
    case calm
    case curiosity
    case listening
    case thinking
    case understood
    case satisfied
    case joy
    case surprise
    case unsure
    case support
    case focus
    case sleepy

    public init(normalizing rawValue: String) {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "curious", "curiosity": self = .curiosity
        case "listening": self = .listening
        case "thinking", "tool": self = .thinking
        case "understood": self = .understood
        case "ready", "approval", "approved", "satisfied": self = .satisfied
        case "celebrate", "joy", "happy", "tongue", "money": self = .joy
        case "surprise", "surprised", "notify": self = .surprise
        case "confused", "doubt", "unsure", "error", "angry": self = .unsure
        case "support", "touched", "love", "shy": self = .support
        case "focus": self = .focus
        case "sleep", "sleepy": self = .sleepy
        default: self = .calm
        }
    }
}

public enum DennyFaceMouthPose: String, CaseIterable, Codable, Equatable, Sendable {
    case rest
    case mbp
    case a
    case e
    case o
    case u
    case fv
    case i
    case y
    case l
    case sz
    case sh
    case dtn
    case kg
    case ch
    case r
    case reduced
    case happy

    public init(normalizing rawValue: String) {
        self = DennyFaceMouthPose(
            rawValue: rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ) ?? .rest
    }
}

public enum DennyFacePresentationResolver {
    public static func expression(for state: NotchPresentationState) -> DennyFaceExpression {
        switch state {
        case .thinking, .extracting:
            return .doubt
        case .talking, .ready:
            return .joy
        case .error:
            return .anxiety
        case .idle, .listening, .downloading, .notification, .unknown:
            return .attention
        }
    }
}

/// State target copied from the approved `denny-face-approval` prototype.
/// These values move retained eye/brow/mouth layers; they are not pre-rendered
/// age-specific faces.
public struct DennyRobotFaceTarget: Equatable, Sendable {
    public let mouthOpen: Double
    public let mouthWide: Double
    public let leftBrowOffset: Double
    public let rightBrowOffset: Double
    public let leftBrowTilt: Double
    public let rightBrowTilt: Double
    public let gazeX: Double
    public let gazeY: Double
    public let leftEyeScale: Double
    public let rightEyeScale: Double
    public let leftEyeClose: Double
    public let rightEyeClose: Double
    public let isFrowning: Bool
    public let isNeutralMouth: Bool
    public let showsTeeth: Bool
    public let showsTongue: Bool

    public static func forEmotion(_ emotion: DennyFaceEmotion) -> DennyRobotFaceTarget {
        switch emotion {
        case .calm:
            return target(mouthWide: 1)
        case .curiosity:
            return target(
                mouthWide: -1,
                leftBrowOffset: -4,
                rightBrowOffset: -1,
                leftBrowTilt: -5,
                rightBrowTilt: 3,
                gazeX: 5,
                gazeY: -1,
                leftEyeScale: 1.04,
                rightEyeScale: 1.04
            )
        case .listening:
            return target(
                mouthWide: -7,
                leftBrowOffset: -2,
                rightBrowOffset: -2,
                gazeX: -1,
                leftEyeScale: 1.04,
                rightEyeScale: 1.04,
                isNeutralMouth: true
            )
        case .thinking:
            return target(
                mouthWide: -3,
                leftBrowOffset: -1,
                rightBrowOffset: -1,
                leftBrowTilt: 8,
                rightBrowTilt: -8,
                gazeX: 4,
                gazeY: -5,
                leftEyeScale: 0.96,
                rightEyeScale: 0.96,
                isFrowning: true
            )
        case .understood:
            return target(
                mouthOpen: 12,
                mouthWide: 5,
                leftBrowOffset: -3,
                rightBrowOffset: -3,
                rightEyeScale: 1.04,
                leftEyeClose: 1,
                showsTeeth: true,
                showsTongue: true
            )
        case .satisfied:
            return target(
                mouthWide: 8,
                leftBrowOffset: -2,
                rightBrowOffset: -2,
                leftEyeClose: 0.45,
                rightEyeClose: 0.45
            )
        case .joy:
            return target(
                mouthOpen: 13,
                mouthWide: 7,
                leftBrowOffset: -4,
                rightBrowOffset: -4,
                leftEyeClose: 1,
                rightEyeClose: 1,
                showsTongue: true
            )
        case .surprise:
            return target(
                mouthOpen: 14,
                mouthWide: -9,
                leftBrowOffset: -7,
                rightBrowOffset: -7,
                leftEyeScale: 1.11,
                rightEyeScale: 1.11,
                showsTongue: true
            )
        case .unsure:
            return target(
                mouthWide: -4,
                leftBrowOffset: -1,
                rightBrowOffset: 3,
                leftBrowTilt: -8,
                rightBrowTilt: 8,
                gazeX: -5,
                rightEyeScale: 0.91,
                isFrowning: true
            )
        case .support:
            return target(
                mouthWide: 1,
                leftBrowOffset: -1,
                rightBrowOffset: -1,
                leftBrowTilt: -4,
                rightBrowTilt: 4,
                gazeY: 1,
                leftEyeScale: 1.02,
                rightEyeScale: 1.02
            )
        case .focus:
            // Deliberately softer than the first concept: shallow brow angles
            // communicate concentration without reading as anger.
            return target(
                mouthWide: 3,
                leftBrowOffset: 1,
                rightBrowOffset: 1,
                leftBrowTilt: 5,
                rightBrowTilt: -5,
                gazeY: 1,
                leftEyeScale: 0.87,
                rightEyeScale: 0.87,
                leftEyeClose: 0.22,
                rightEyeClose: 0.22,
                isNeutralMouth: true
            )
        case .sleepy:
            return target(
                mouthOpen: 11,
                mouthWide: -8,
                leftBrowOffset: 2,
                rightBrowOffset: 2,
                leftEyeClose: 1,
                rightEyeClose: 1,
                showsTongue: true
            )
        }
    }

    private static func target(
        mouthOpen: Double = 0,
        mouthWide: Double = 0,
        leftBrowOffset: Double = 0,
        rightBrowOffset: Double = 0,
        leftBrowTilt: Double = 0,
        rightBrowTilt: Double = 0,
        gazeX: Double = 0,
        gazeY: Double = 0,
        leftEyeScale: Double = 1,
        rightEyeScale: Double = 1,
        leftEyeClose: Double = 0,
        rightEyeClose: Double = 0,
        isFrowning: Bool = false,
        isNeutralMouth: Bool = false,
        showsTeeth: Bool = false,
        showsTongue: Bool = false
    ) -> DennyRobotFaceTarget {
        DennyRobotFaceTarget(
            mouthOpen: mouthOpen,
            mouthWide: mouthWide,
            leftBrowOffset: leftBrowOffset,
            rightBrowOffset: rightBrowOffset,
            leftBrowTilt: leftBrowTilt,
            rightBrowTilt: rightBrowTilt,
            gazeX: gazeX,
            gazeY: gazeY,
            leftEyeScale: leftEyeScale,
            rightEyeScale: rightEyeScale,
            leftEyeClose: leftEyeClose,
            rightEyeClose: rightEyeClose,
            isFrowning: isFrowning,
            isNeutralMouth: isNeutralMouth,
            showsTeeth: showsTeeth,
            showsTongue: showsTongue
        )
    }
}

public struct DennyRobotMouthTarget: Equatable, Sendable {
    public let open: Double
    public let wide: Double
    public let showsTeeth: Bool
    public let showsTongue: Bool
    public let lowerLipRaised: Bool
    public let tongueAtUpperTeeth: Bool

    public static func forPose(_ pose: DennyFaceMouthPose) -> DennyRobotMouthTarget {
        switch pose {
        case .rest:
            return target()
        case .mbp:
            return target(wide: -1)
        case .a:
            return target(open: 13, wide: 7, showsTeeth: true, showsTongue: true)
        case .e:
            return target(open: 8, wide: 10, showsTeeth: true, showsTongue: true)
        case .o:
            return target(open: 15, wide: -7, showsTongue: true)
        case .u:
            return target(open: 8, wide: -9, showsTongue: true)
        case .fv:
            return target(open: 4, wide: 5, showsTeeth: true, lowerLipRaised: true)
        case .i:
            return target(open: 5, wide: 12, showsTeeth: true)
        case .y:
            return target(open: 6, wide: 6, showsTeeth: true, showsTongue: true)
        case .l:
            return target(open: 9, wide: 4, showsTeeth: true, showsTongue: true, tongueAtUpperTeeth: true)
        case .sz:
            return target(open: 4, wide: 5, showsTeeth: true)
        case .sh:
            return target(open: 7, wide: -2, showsTongue: true)
        case .dtn:
            return target(open: 6, wide: 3, showsTeeth: true, showsTongue: true, tongueAtUpperTeeth: true)
        case .kg:
            return target(open: 7, wide: 1, showsTongue: true)
        case .ch:
            return target(open: 6, wide: -1, showsTeeth: true, showsTongue: true)
        case .r:
            return target(open: 6, wide: 2, showsTongue: true)
        case .reduced:
            return target(open: 3, wide: 2, showsTongue: true)
        case .happy:
            return target(open: 12, wide: 7, showsTeeth: true, showsTongue: true)
        }
    }

    private static func target(
        open: Double = 0,
        wide: Double = 0,
        showsTeeth: Bool = false,
        showsTongue: Bool = false,
        lowerLipRaised: Bool = false,
        tongueAtUpperTeeth: Bool = false
    ) -> DennyRobotMouthTarget {
        DennyRobotMouthTarget(
            open: open,
            wide: wide,
            showsTeeth: showsTeeth,
            showsTongue: showsTongue,
            lowerLipRaised: lowerLipRaised,
            tongueAtUpperTeeth: tongueAtUpperTeeth
        )
    }
}
