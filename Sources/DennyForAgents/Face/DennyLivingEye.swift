import SwiftUI

/// Native, resolution-independent eye. The dark pupil rides the curved globe;
/// eyelids clip the intact globe instead of scaling the pupil into a stripe.
struct DennyLivingEye: View {
    var gazeX: CGFloat
    var gazeY: CGFloat
    var openness: CGFloat = 1
    var eyeScale: CGFloat = 1
    var side: CGFloat = 1

    private var gx: CGFloat { min(1, max(-1, gazeX / 9)) }
    private var gy: CGFloat { min(1, max(-1, gazeY / 10)) }

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let globe = CGRect(x: 0, y: 0, width: w, height: h)
            let oval = Path(ellipseIn: globe)
            let opening = min(1, max(0, openness))
            let close = 1 - opening
            var c = context
            c.clip(to: oval)
            c.clip(to: aperture(width: w, height: h, close: close))
            c.fill(oval, with: .radialGradient(
                Gradient(stops: [
                    .init(color: .white, location: 0),
                    .init(color: Color(red: 0.985, green: 0.985, blue: 0.99), location: 0.4),
                    .init(color: Color(red: 0.83, green: 0.84, blue: 0.87), location: 0.75),
                    .init(color: Color(red: 0.49, green: 0.51, blue: 0.56), location: 1)
                ]),
                center: CGPoint(x: w * 0.28, y: h * 0.22),
                startRadius: 0, endRadius: h * 0.9
            ))
            let nx = gx * 0.7
            let ny = gy * 0.63
            let depth = sqrt(max(0.2, 1 - nx * nx - ny * ny))
            let pw = w * 0.48 * (0.78 + depth * 0.22)
            let ph = h * 0.51 * (0.87 + depth * 0.13)
            let px = w * (0.5 + gx * 0.235)
            let py = h * (0.56 + gy * 0.20)
            let pupil = Path(ellipseIn: CGRect(x: px - pw / 2, y: py - ph / 2, width: pw, height: ph))
            c.fill(pupil, with: .linearGradient(
                Gradient(colors: [Color(red: 0.065, green: 0.07, blue: 0.09), .black, Color(red: 0.025, green: 0.035, blue: 0.045)]),
                startPoint: CGPoint(x: px, y: py - ph / 2),
                endPoint: CGPoint(x: px, y: py + ph / 2)
            ))
            var glass = c
            glass.clip(to: pupil)
            // Reflections stay on the illuminated side as the eye rotates.
            glass.fill(Path(ellipseIn: CGRect(x: px - pw * 0.02 - gx * w * 0.025, y: py - ph * 0.39, width: pw * 0.29, height: ph * 0.25)),
                       with: .color(.white.opacity(0.98)))
            glass.fill(Path(ellipseIn: CGRect(x: px - pw * 0.3, y: py + ph * 0.23, width: pw * 0.57, height: ph * 0.22)),
                       with: .color(.white.opacity(0.065)))
            if opening < 0.12 {
                var seam = Path()
                seam.move(to: CGPoint(x: w * 0.14, y: h * 0.54))
                seam.addQuadCurve(to: CGPoint(x: w * 0.86, y: h * 0.54), control: CGPoint(x: w * 0.5, y: h * 0.66))
                context.stroke(seam, with: .color(Color(white: 0.72).opacity(Double(1 - opening / 0.12))),
                               style: StrokeStyle(lineWidth: w * 0.055, lineCap: .round))
            }
        }
        .frame(width: 37, height: 48 * eyeScale)
        .rotationEffect(.degrees(Double(-gx * 12 + side * abs(gx) * 2)))
        .offset(x: gx * 1.8, y: gy * 1.2)
        .accessibilityHidden(true)
    }

    private func aperture(width w: CGFloat, height h: CGFloat, close: CGFloat) -> Path {
        var p = Path()
        let upper = h * close * 0.59
        let lower = h * (1 - close * 0.41)
        p.move(to: CGPoint(x: -w, y: upper - h * 0.10 * close))
        p.addQuadCurve(to: CGPoint(x: 2 * w, y: upper - h * 0.10 * close),
                       control: CGPoint(x: w / 2, y: upper + h * 0.20 * close))
        p.addLine(to: CGPoint(x: 2 * w, y: lower + h * 0.08 * close))
        p.addQuadCurve(to: CGPoint(x: -w, y: lower + h * 0.08 * close),
                       control: CGPoint(x: w / 2, y: lower - h * 0.16 * close))
        p.closeSubpath()
        return p
    }
}
