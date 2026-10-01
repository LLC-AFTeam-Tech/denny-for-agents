import AppKit
import SwiftUI

/// Long-lived observable state for the face. Mouth poses arrive at audio-frame
/// cadence, so they update retained SwiftUI layers instead of replacing the
/// hosting view (which would also disturb the native music and file surfaces).
final class DennyFaceViewModel: ObservableObject {
    @Published private(set) var presentationState: NotchPresentationState
    @Published private(set) var emotion: DennyFaceEmotion
    @Published private(set) var age: DennyFaceAge
    @Published private(set) var mouthPose: DennyFaceMouthPose
    @Published private(set) var reduceMotion: Bool
    @Published private(set) var presentationStartedAt: TimeInterval
    @Published private(set) var activeGesture: DennyFaceGesture?
    @Published private(set) var gestureStartedAt: TimeInterval

    init(
        presentationState: NotchPresentationState = .idle,
        emotion: DennyFaceEmotion = .calm,
        age: DennyFaceAge = .child,
        mouthPose: DennyFaceMouthPose = .rest,
        reduceMotion: Bool = false
    ) {
        self.presentationState = presentationState
        self.emotion = emotion
        self.age = age
        self.mouthPose = mouthPose
        self.reduceMotion = reduceMotion
        let now = ProcessInfo.processInfo.systemUptime
        self.presentationStartedAt = now
        self.activeGesture = nil
        self.gestureStartedAt = now
    }

    func update(
        presentationState: NotchPresentationState,
        emotion: DennyFaceEmotion,
        age: DennyFaceAge,
        mouthPose: DennyFaceMouthPose,
        reduceMotion: Bool
    ) {
        if self.presentationState != presentationState {
            self.presentationState = presentationState
            self.presentationStartedAt = ProcessInfo.processInfo.systemUptime
            if activeGesture != .shutdown {
                activeGesture = nil
            }
        }
        if self.emotion != emotion {
            self.emotion = emotion
        }
        if self.age != age {
            self.age = age
        }
        if self.mouthPose != mouthPose {
            self.mouthPose = mouthPose
        }
        if self.reduceMotion != reduceMotion {
            self.reduceMotion = reduceMotion
        }
    }

    func playGesture(_ gesture: DennyFaceGesture) {
        activeGesture = gesture
        gestureStartedAt = ProcessInfo.processInfo.systemUptime
    }

    func cancelGesture(_ gesture: DennyFaceGesture? = nil) {
        guard gesture == nil || activeGesture == gesture else { return }
        activeGesture = nil
    }
}

/// The approved single black-and-white Denny face, ported from
/// `denny-face-approval-v1/face.js`. Geometry never changes with age; the
/// compatibility age value only controls the restraint of ambient movement.
struct DennyRobotFaceView: View {
    @ObservedObject var model: DennyFaceViewModel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private let canvasSize = CGSize(width: 190, height: 145)

    private var animationInterval: TimeInterval {
        if model.activeGesture != nil || model.emotion == .focus || DennyEyeMotion.frame(at: ProcessInfo.processInfo.systemUptime - model.presentationStartedAt).isMoving {
            return 1.0 / 30.0
        }
        switch model.presentationState {
        case .talking, .listening, .thinking, .error:
            return 1.0 / 30.0
        default:
            return 1.0 / 10.0
        }
    }

    private var reduceMotion: Bool { systemReduceMotion || model.reduceMotion }

    var body: some View {
        GeometryReader { geometry in
            let scale = min(
                geometry.size.width / canvasSize.width,
                geometry.size.height / canvasSize.height
            )

            Group {
                if reduceMotion {
                    DennyRobotFaceCanvas(
                        state: model.presentationState,
                        emotion: model.emotion,
                        age: model.age,
                        mouthPose: model.mouthPose,
                        time: ProcessInfo.processInfo.systemUptime,
                        presentationStartedAt: model.presentationStartedAt,
                        gesture: model.activeGesture,
                        gestureStartedAt: model.gestureStartedAt,
                        reduceMotion: true
                    )
                } else {
                    TimelineView(.animation(minimumInterval: animationInterval)) { _ in
                        DennyRobotFaceCanvas(
                            state: model.presentationState,
                            emotion: model.emotion,
                            age: model.age,
                            mouthPose: model.mouthPose,
                            time: ProcessInfo.processInfo.systemUptime,
                            presentationStartedAt: model.presentationStartedAt,
                            gesture: model.activeGesture,
                            gestureStartedAt: model.gestureStartedAt,
                            reduceMotion: false
                        )
                    }
                }
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .scaleEffect(scale)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Denny: \(model.emotion.rawValue)")
    }
}

private struct DennyRobotFaceCanvas: View {
    let state: NotchPresentationState
    let emotion: DennyFaceEmotion
    let age: DennyFaceAge
    let mouthPose: DennyFaceMouthPose
    let time: TimeInterval
    let presentationStartedAt: TimeInterval
    let gesture: DennyFaceGesture?
    let gestureStartedAt: TimeInterval
    let reduceMotion: Bool

    /// Keeps facial features below the physical camera. The parent notch
    /// owns the only background; this canvas remains transparent.
    private let cameraClearanceOffset: CGFloat = 14

    private var faceTarget: DennyRobotFaceTarget {
        DennyRobotFaceTarget.forEmotion(emotion)
    }

    private var motion: DennyFaceMotionProfile {
        DennyFaceMotionProfile.forAge(age)
    }

    private var mouthTarget: DennyRobotMouthTarget {
        if state == .talking {
            return DennyRobotMouthTarget.forPose(mouthPose)
        }
        if gesture != nil && motionFrame.gestureMouthOpen > 0 {
            return DennyRobotMouthTarget.forPose(.happy)
        }
        if state == .ready {
            return DennyRobotMouthTarget.forPose(.happy)
        }
        return DennyRobotMouthTarget.forPose(.rest)
    }

    private var renderedMouthOpen: CGFloat {
        if state == .talking { return CGFloat(mouthTarget.open) }
        if gesture != nil { return CGFloat(motionFrame.gestureMouthOpen) }
        return CGFloat(faceTarget.mouthOpen)
    }

    private var renderedMouthWide: CGFloat {
        if state == .talking { return CGFloat(mouthTarget.wide) }
        if gesture != nil { return motionFrame.gestureMouthOpen > 2 ? 5 : 0 }
        return CGFloat(faceTarget.mouthWide)
    }

    private var motionFrame: DennyFaceMotionFrame {
        DennyFaceMotionTimeline.frame(
            presentationState: state,
            presentationElapsed: max(0, time - presentationStartedAt),
            gesture: gesture,
            gestureElapsed: max(0, time - gestureStartedAt),
            emotion: emotion,
            reduceMotion: reduceMotion
        )
    }

    private var livingGaze: DennyEyeMotionFrame {
        DennyEyeMotion.frame(at: max(0, time - presentationStartedAt), reduceMotion: reduceMotion)
    }

    private var ambientBlinkAmount: CGFloat {
        guard !reduceMotion else { return 0 }
        return max(CGFloat(motionFrame.eyeClose), CGFloat(livingGaze.blink))
    }

    private var ambientGazeX: CGFloat {
        guard !reduceMotion else { return 0 }
        let ambient = gesture == nil && emotion != .focus ? livingGaze.x * 7 * motion.gazeScale : 0
        return CGFloat(ambient + motionFrame.gazeX)
    }

    private var ambientGazeY: CGFloat {
        guard !reduceMotion else { return 0 }
        let ambient = gesture == nil && emotion != .focus ? livingGaze.y * 8 * motion.gazeScale : 0
        return CGFloat(ambient + motionFrame.gazeY)
    }

    private func softPulse(
        _ value: Double,
        _ start: Double,
        _ peak: Double,
        _ hold: Double,
        _ end: Double
    ) -> Double {
        func smooth(_ raw: Double) -> Double {
            let bounded = min(1, max(0, raw))
            return bounded * bounded * (3 - 2 * bounded)
        }
        return smooth((value - start) / (peak - start))
            * (1 - smooth((value - hold) / (end - hold)))
    }

    private var breathingOffset: CGFloat {
        guard !reduceMotion else { return 0 }
        return CGFloat(sin(time * 1.25) * motion.breathingAmplitude)
    }

    private var activityProgress: CGFloat {
        guard !reduceMotion else { return 0.45 }
        return CGFloat((sin(time * 1.8) + 1) * 0.5)
    }

    var body: some View {
        ZStack {
            ZStack {
                DennyRobotBrow(
                    centerX: 64,
                    offsetY: CGFloat((faceTarget.leftBrowOffset + motionFrame.browOffset + motionFrame.browAsymmetry) * motion.movementScale),
                    tilt: CGFloat((faceTarget.leftBrowTilt + motionFrame.browTilt) * motion.movementScale)
                )
                DennyRobotBrow(
                    centerX: 126,
                    offsetY: CGFloat((faceTarget.rightBrowOffset + motionFrame.browOffset - motionFrame.browAsymmetry) * motion.movementScale),
                    tilt: CGFloat((faceTarget.rightBrowTilt + motionFrame.browTilt) * motion.movementScale),
                    mirrored: true
                )

                DennyRobotEye(
                    centerX: 64,
                    gazeX: CGFloat(faceTarget.gazeX * motion.movementScale + motionFrame.eyeX) + ambientGazeX + 0.4,
                    gazeY: CGFloat(faceTarget.gazeY * motion.movementScale + motionFrame.eyeY) + ambientGazeY,
                    eyeScale: 1 + CGFloat((faceTarget.leftEyeScale - 1) * motion.movementScale),
                    blinkAmount: max(ambientBlinkAmount, CGFloat(max(faceTarget.leftEyeClose, motionFrame.leftEyeClose))),
                    highlightOffset: 4
                )
                DennyRobotEye(
                    centerX: 126,
                    gazeX: CGFloat(faceTarget.gazeX * motion.movementScale + motionFrame.eyeX) + ambientGazeX - 0.4,
                    gazeY: CGFloat(faceTarget.gazeY * motion.movementScale + motionFrame.eyeY) + ambientGazeY,
                    eyeScale: 1 + CGFloat((faceTarget.rightEyeScale - 1) * motion.movementScale),
                    blinkAmount: max(ambientBlinkAmount, CGFloat(max(faceTarget.rightEyeClose, motionFrame.rightEyeClose))),
                    highlightOffset: 0
                )

                DennyRobotMouth(
                    open: renderedMouthOpen,
                    wide: renderedMouthWide,
                    frowning: faceTarget.isFrowning && state != .talking,
                    neutral: faceTarget.isNeutralMouth && state != .talking,
                    showsTeeth: state == .talking ? mouthTarget.showsTeeth : faceTarget.showsTeeth,
                    showsTongue: state == .talking
                        ? mouthTarget.showsTongue
                        : ((gesture != nil && motionFrame.gestureMouthOpen > 2) || faceTarget.showsTongue),
                    lowerLipRaised: mouthTarget.lowerLipRaised,
                    tongueAtUpperTeeth: mouthTarget.tongueAtUpperTeeth
                )

                if motionFrame.blush > 0 {
                    DennySoftBlush(opacity: CGFloat(motionFrame.blush))
                }

                if motionFrame.pixelBlush > 0 {
                    DennyPixelBlush(time: time, opacity: CGFloat(motionFrame.pixelBlush))
                }

                if motionFrame.accent > 0 {
                    DennyGestureAccent(opacity: CGFloat(motionFrame.accent))
                }
            }
            .scaleEffect(
                x: CGFloat(motionFrame.scale * motionFrame.faceScaleX),
                y: CGFloat(motionFrame.scale * motionFrame.faceScaleY),
                anchor: UnitPoint(x: 0.5, y: 0.58)
            )
            .rotationEffect(.degrees(motionFrame.angle), anchor: UnitPoint(x: 0.5, y: 0.58))
            .offset(
                x: CGFloat(motionFrame.headX),
                y: cameraClearanceOffset + breathingOffset + CGFloat(motionFrame.headY)
            )
            .opacity(motionFrame.faceOpacity)
            .animation(
                reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.78),
                value: emotion.rawValue
            )
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.075),
                value: mouthPose
            )

            ForEach(Array(motionFrame.hands.enumerated()), id: \.offset) { _, hand in
                DennyMotionHandView(placement: hand)
            }

            if gesture == .shutdown {
                DennyShutdownRemote(
                    lift: CGFloat(motionFrame.remoteLift),
                    press: CGFloat(motionFrame.remotePress),
                    opacity: CGFloat(motionFrame.remoteOpacity)
                )
                if motionFrame.shutdownLine > 0 {
                    Capsule()
                        .fill(Color.white.opacity(motionFrame.shutdownLine))
                        .frame(width: 104 * CGFloat(1 - motionFrame.shutdownLine * 0.82), height: 2)
                        .position(x: 95, y: 84)
                }
            }

            if state == .downloading || state == .extracting {
                DennyRobotActivityBar(
                    progress: activityProgress,
                    extracting: state == .extracting
                )
            }
        }
        .frame(width: 190, height: 145)
        .clipped()
    }
}

private struct DennyMotionHandView: View {
    let placement: DennyFaceHandPlacement

    private func edgeSafeOpacity(
        width: CGFloat,
        height: CGFloat,
        offsetX: CGFloat = 0,
        offsetY: CGFloat = 0
    ) -> Double {
        let scale = CGFloat(placement.scale)
        let centerX = CGFloat(placement.x) + offsetX * scale
        let centerY = CGFloat(placement.y) + offsetY * scale
        let halfWidth = width * scale / 2
        let halfHeight = height * scale / 2
        let horizontalOverflow = max(
            max(0, halfWidth - centerX),
            max(0, centerX + halfWidth - 190)
        )
        let verticalOverflow = max(
            max(0, halfHeight - centerY),
            max(0, centerY + halfHeight - 145)
        )
        let overflow = max(horizontalOverflow, verticalOverflow)
        // Fully drawn while inside the canvas; fade only the clipped entry
        // frames so a detached fingertip can never flash at an edge.
        let edgeVisibility = max(0, min(1, 1 - Double(overflow / 12)))
        return placement.opacity * edgeVisibility
    }

    var body: some View {
        if placement.asset == .thumb {
            DennyThumbsUpHand()
                .frame(width: 32, height: 42)
                .scaleEffect(
                    x: (placement.mirrored ? -1 : 1) * CGFloat(placement.scale),
                    y: CGFloat(placement.scale)
                )
                .rotationEffect(.degrees(placement.rotation))
                .position(x: CGFloat(placement.x), y: CGFloat(placement.y))
                .opacity(edgeSafeOpacity(width: 32, height: 42))
                .allowsHitTesting(false)
        } else if let asset = DennyMotionAssetCatalog.shared.hand(placement.asset) {
            ZStack {
                Image(nsImage: asset.image)
                    .resizable()
                    .frame(width: asset.width, height: asset.height)
                    .offset(x: asset.offsetX, y: asset.offsetY)
            }
            .frame(width: 1, height: 1)
            .scaleEffect(
                x: (placement.mirrored ? -1 : 1) * CGFloat(placement.scale),
                y: CGFloat(placement.scale)
            )
            .rotationEffect(.degrees(placement.rotation))
            .position(x: CGFloat(placement.x), y: CGFloat(placement.y))
            .opacity(edgeSafeOpacity(
                width: asset.width,
                height: asset.height,
                offsetX: asset.offsetX,
                offsetY: asset.offsetY
            ))
            .blendMode(.screen)
            .allowsHitTesting(false)
        }
    }
}

private struct DennyThumbsUpHand: View {
    private let handGradient = LinearGradient(
        colors: [.white, Color(red: 0.88, green: 0.9, blue: 0.93)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(handGradient)
                .frame(width: 21, height: 23)
                .offset(x: 3, y: 7)
            Capsule()
                .fill(handGradient)
                .frame(width: 9, height: 25)
                .rotationEffect(.degrees(-8))
                .offset(x: -7, y: -7)
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(handGradient)
                    .frame(width: 14, height: 6)
                    .offset(x: 5, y: CGFloat(index) * 5 + 1)
            }
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(red: 0.78, green: 0.81, blue: 0.86))
                .frame(width: 22, height: 6)
                .offset(x: 3, y: 20)
        }
        .shadow(color: .black.opacity(0.75), radius: 1.4, y: 1)
    }
}

private struct DennyGestureAccent: View {
    let opacity: CGFloat

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(index == 1 ? Color.white : Color(red: 0.38, green: 0.78, blue: 1))
                    .frame(width: 2.2, height: index == 1 ? 11 : 8)
                    .rotationEffect(.degrees(Double(index - 1) * 38 - 18))
                    .position(x: 27 + CGFloat(index) * 5, y: 62 - CGFloat(abs(index - 1)) * 5)
            }
            ForEach(0..<2, id: \.self) { index in
                DennySparkleShape()
                    .fill(index == 0 ? Color.white : Color(red: 0.35, green: 0.75, blue: 1))
                    .frame(width: index == 0 ? 9 : 7, height: index == 0 ? 9 : 7)
                    .position(x: index == 0 ? 154 : 164, y: index == 0 ? 51 : 67)
            }
        }
        .opacity(opacity)
        .allowsHitTesting(false)
    }
}

private struct DennySparkleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX + rect.width * 0.2, y: rect.midY - rect.height * 0.2))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX + rect.width * 0.2, y: rect.midY + rect.height * 0.2))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX - rect.width * 0.2, y: rect.midY + rect.height * 0.2))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX - rect.width * 0.2, y: rect.midY - rect.height * 0.2))
        path.closeSubpath()
        return path
    }
}

private struct DennySoftBlush: View {
    let opacity: CGFloat

    var body: some View {
        ZStack {
            Ellipse().fill(Color(red: 0.87, green: 0.43, blue: 0.57).opacity(0.44 * Double(opacity)))
                .frame(width: 16, height: 6).position(x: 47, y: 92)
            Ellipse().fill(Color(red: 0.87, green: 0.43, blue: 0.57).opacity(0.44 * Double(opacity)))
                .frame(width: 16, height: 6).position(x: 143, y: 92)
        }
    }
}

private struct DennyPixelBlush: View {
    let time: TimeInterval
    let opacity: CGFloat
    private let weights: [[CGFloat]] = [
        [0, 0.25, 0.5, 0.25, 0],
        [0.25, 0.6, 0.9, 0.6, 0.25],
        [0.4, 0.8, 1, 0.8, 0.4],
        [0.2, 0.5, 0.7, 0.5, 0.2],
        [0, 0.15, 0.3, 0.15, 0]
    ]

    var body: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { side in
                ForEach(0..<5, id: \.self) { row in
                    ForEach(0..<5, id: \.self) { column in
                        let weight = weights[row][column]
                        if weight > 0 {
                            let shimmer = 0.84 + 0.16 * sin(time * 4 + Double(row) * 1.4 + Double(column) * 1.7 + Double(side) * 0.8)
                            RoundedRectangle(cornerRadius: 0.2)
                                .fill(Color.white.opacity(Double(opacity * weight) * shimmer))
                                .frame(width: 1.8, height: 1.8)
                                .position(
                                    x: (side == 0 ? CGFloat(46) : CGFloat(144)) + CGFloat(column - 2) * 2.5,
                                    y: 94 + CGFloat(row - 2) * 2.5
                                )
                        }
                    }
                }
            }
        }
    }
}

private struct DennyShutdownRemote: View {
    let lift: CGFloat
    let press: CGFloat
    let opacity: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(red: 0.2, green: 0.22, blue: 0.25))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray, lineWidth: 0.7))
                .frame(width: 14, height: 29)
            Circle()
                .fill(press > 0.5 ? Color.white : Color(red: 0.94, green: 0.47, blue: 0.49))
                .frame(width: 6, height: 6)
                .offset(y: -9)
            Capsule().fill(Color.white.opacity(0.9)).frame(width: 8, height: 10)
                .offset(x: 5 - press * 4, y: -6 - press * 3)
        }
        .rotationEffect(.degrees(-14))
        .position(x: 143, y: 170 - 52 * lift)
        .opacity(Double(opacity))
        .allowsHitTesting(false)
    }
}

private struct DennyRobotEye: View {
    let centerX: CGFloat
    let gazeX: CGFloat
    let gazeY: CGFloat
    let eyeScale: CGFloat
    let blinkAmount: CGFloat
    let highlightOffset: CGFloat

    var body: some View {
        DennyLivingEye(gazeX: gazeX, gazeY: gazeY,
                       openness: 1 - blinkAmount, eyeScale: eyeScale,
                       side: centerX < 95 ? -1 : 1)
            .position(x: centerX, y: 69)
    }
}

private struct DennyRobotBrow: View {
    let centerX: CGFloat
    let offsetY: CGFloat
    let tilt: CGFloat
    var mirrored = false

    var body: some View {
        DennyRobotBrowShape()
            .fill(
                LinearGradient(
                    colors: [.white, Color(red: 0.87, green: 0.89, blue: 0.92)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 31, height: 15)
            .scaleEffect(x: mirrored ? -1 : 1, y: 1)
            .rotationEffect(.degrees(tilt))
            .shadow(color: .black.opacity(0.85), radius: 1.2, y: 1.5)
            .position(x: centerX, y: 33 + offsetY)
    }
}

private struct DennyRobotBrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        let x = rect.minX
        let y = rect.minY
        let sx = rect.width / 31
        let sy = rect.height / 15
        func point(_ px: CGFloat, _ py: CGFloat) -> CGPoint {
            CGPoint(x: x + px * sx, y: y + py * sy)
        }

        var path = Path()
        path.move(to: point(0, 11))
        path.addCurve(to: point(24, 3), control1: point(-2, 5), control2: point(12, 0))
        path.addCurve(to: point(26, 10), control1: point(29, 4), control2: point(31, 9))
        path.addCurve(to: point(4, 12), control1: point(17, 7), control2: point(9, 8))
        path.addQuadCurve(to: point(0, 11), control: point(1, 14))
        path.closeSubpath()
        return path
    }
}

private struct DennyRobotMouth: View {
    let open: CGFloat
    let wide: CGFloat
    let frowning: Bool
    let neutral: Bool
    let showsTeeth: Bool
    let showsTongue: Bool
    let lowerLipRaised: Bool
    let tongueAtUpperTeeth: Bool

    private var width: CGFloat { max(7, 16 + wide) }

    var body: some View {
        ZStack {
            DennyRobotMouthShape(open: open, wide: wide, frowning: frowning, neutral: neutral)
                .fill(Color(red: 0.035, green: 0.008, blue: 0.02))

            if open < 1.2 && !frowning && !neutral {
                DennyRobotClosedMouthHighlight(width: width)
                    .fill(Color(red: 0.9, green: 0.91, blue: 0.92))
            }

            if open >= 1.2 {
                ZStack {
                    if showsTeeth {
                        DennyRobotTeethShape(width: width, lowerLipRaised: lowerLipRaised)
                            .fill(
                                LinearGradient(
                                    colors: [.white, Color(red: 0.84, green: 0.86, blue: 0.89)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }

                    if showsTongue || lowerLipRaised {
                        Ellipse()
                            .fill(
                                RadialGradient(
                                    colors: [Color(red: 1, green: 0.7, blue: 0.75), Color(red: 0.96, green: 0.49, blue: 0.59), Color(red: 0.79, green: 0.27, blue: 0.41)],
                                    center: UnitPoint(x: 0.4, y: 0.3),
                                    startRadius: 0,
                                    endRadius: 20
                                )
                            )
                            .frame(
                                width: tongueAtUpperTeeth
                                    ? max(8, width * 0.72)
                                    : max(10, width * 1.32),
                                height: tongueAtUpperTeeth ? 4 : (lowerLipRaised ? 5 : max(4, open * 0.62))
                            )
                            .position(
                                x: 95,
                                y: tongueAtUpperTeeth ? 107 : (lowerLipRaised ? 111 : 108 + open * 0.62)
                            )
                    }
                }
                .frame(width: 190, height: 145)
                .mask(DennyRobotMouthShape(open: open, wide: wide, frowning: frowning, neutral: neutral))
            }

            DennyRobotMouthShape(open: open, wide: wide, frowning: frowning, neutral: neutral)
                .stroke(Color(red: 0.15, green: 0.13, blue: 0.15), lineWidth: 0.85)
        }
        .frame(width: 190, height: 145)
    }
}

private struct DennyRobotMouthShape: Shape {
    var open: CGFloat
    var wide: CGFloat
    let frowning: Bool
    let neutral: Bool

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(open, wide) }
        set {
            open = newValue.first
            wide = newValue.second
        }
    }

    func path(in _: CGRect) -> Path {
        let width = max(7, 16 + wide)
        var path = Path()
        if open < 1.2 {
            let mouthY: CGFloat = frowning ? 108 : 104
            path.move(to: CGPoint(x: 95 - width, y: mouthY))
            if neutral {
                path.addLine(to: CGPoint(x: 95 + width, y: mouthY))
                path.addLine(to: CGPoint(x: 95 + width, y: mouthY + 2))
                path.addLine(to: CGPoint(x: 95 - width, y: mouthY + 2))
                path.closeSubpath()
                return path
            }
            path.addQuadCurve(
                to: CGPoint(x: 95 + width, y: mouthY),
                control: CGPoint(x: 95, y: frowning ? 98 : 111)
            )
            path.addQuadCurve(
                to: CGPoint(x: 95 - width, y: frowning ? 108 : 104),
                control: CGPoint(x: 95, y: frowning ? 104 : 116)
            )
        } else {
            path.move(to: CGPoint(x: 95 - width, y: 102))
            path.addQuadCurve(
                to: CGPoint(x: 95 + width, y: 102),
                control: CGPoint(x: 95, y: 104 + min(open * 0.1, 2))
            )
            path.addCurve(
                to: CGPoint(x: 95 - width, y: 102),
                control1: CGPoint(x: 95 + width, y: 109 + open),
                control2: CGPoint(x: 95 - width, y: 109 + open)
            )
        }
        path.closeSubpath()
        return path
    }
}

private struct DennyRobotClosedMouthHighlight: Shape {
    let width: CGFloat

    func path(in _: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 95 - width + 3, y: 105))
        path.addQuadCurve(to: CGPoint(x: 95 + width - 3, y: 105), control: CGPoint(x: 95, y: 110))
        path.addQuadCurve(to: CGPoint(x: 95 - width + 3, y: 105), control: CGPoint(x: 95, y: 113))
        path.closeSubpath()
        return path
    }
}

private struct DennyRobotTeethShape: Shape {
    let width: CGFloat
    let lowerLipRaised: Bool

    func path(in _: CGRect) -> Path {
        var path = Path()
        let inset: CGFloat = lowerLipRaised ? 2 : 1
        path.move(to: CGPoint(x: 95 - width + inset, y: 102))
        path.addQuadCurve(
            to: CGPoint(x: 95 + width - inset, y: 102),
            control: CGPoint(x: 95, y: 104)
        )
        path.addLine(to: CGPoint(x: 95 + width - 4, y: lowerLipRaised ? 106 : 107))
        path.addQuadCurve(
            to: CGPoint(x: 95 - width + 4, y: lowerLipRaised ? 106 : 107),
            control: CGPoint(x: 95, y: lowerLipRaised ? 107 : 109)
        )
        path.closeSubpath()
        return path
    }
}

private struct DennyRobotActivityBar: View {
    let progress: CGFloat
    let extracting: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color(red: 0.19, green: 0.2, blue: 0.22))
            Capsule()
                .fill(extracting ? Color(red: 0.7, green: 0.73, blue: 0.78) : Color.white.opacity(0.95))
                .frame(width: max(4, 78 * progress))
        }
        .frame(width: 78, height: 2.5)
        .position(x: 95, y: 130)
    }
}
