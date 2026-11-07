import CoreGraphics
import Foundation

/// Everything the line figure needs for one frame.
public struct FigureState: Sendable {
    public var pose: HeadPose
    /// Earlier poses, oldest first. They fade out behind the head as motion echoes.
    public var echoes: [HeadPose]
    /// 0...1 while a recognised gesture's pulse travels outward; nil otherwise.
    public var pulse: Double?
    /// 0...1: how alive the AirPods look.
    public var budGlow: Double
    /// Dims the whole figure while there is no sensor data.
    public var dimmed: Bool

    public init(pose: HeadPose = .zero, echoes: [HeadPose] = [], pulse: Double? = nil,
                budGlow: Double = 0, dimmed: Bool = false) {
        self.pose = pose
        self.echoes = echoes
        self.pulse = pulse
        self.budGlow = budGlow
        self.dimmed = dimmed
    }
}

public struct FigureStyle: @unchecked Sendable {
    public var ink: CGColor
    public var accent: CGColor
    /// Fill behind the head, so far-side lines and the neck are hidden like real line art.
    public var paper: CGColor

    public init(ink: CGColor, accent: CGColor, paper: CGColor) {
        self.ink = ink
        self.accent = accent
        self.paper = paper
    }
}

private struct V3 {
    var x, y, z: Double
    init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
    static func + (a: V3, b: V3) -> V3 { V3(a.x + b.x, a.y + b.y, a.z + b.z) }
    static func - (a: V3, b: V3) -> V3 { V3(a.x - b.x, a.y - b.y, a.z - b.z) }
    static func * (a: V3, s: Double) -> V3 { V3(a.x * s, a.y * s, a.z * s) }
    var normalized: V3 {
        let l = (x * x + y * y + z * z).squareRoot()
        return l > 0 ? self * (1 / l) : self
    }
}

private struct M3 {
    var r0, r1, r2: V3
    func apply(_ v: V3) -> V3 {
        V3(r0.x * v.x + r0.y * v.y + r0.z * v.z,
           r1.x * v.x + r1.y * v.y + r1.z * v.z,
           r2.x * v.x + r2.y * v.y + r2.z * v.z)
    }
    static func * (a: M3, b: M3) -> M3 {
        func col(_ c: V3) -> V3 { a.apply(c) }
        let c0 = col(V3(b.r0.x, b.r1.x, b.r2.x))
        let c1 = col(V3(b.r0.y, b.r1.y, b.r2.y))
        let c2 = col(V3(b.r0.z, b.r1.z, b.r2.z))
        return M3(r0: V3(c0.x, c1.x, c2.x), r1: V3(c0.y, c1.y, c2.y), r2: V3(c0.z, c1.z, c2.z))
    }
    static func rotY(_ a: Double) -> M3 {
        M3(r0: V3(cos(a), 0, sin(a)), r1: V3(0, 1, 0), r2: V3(-sin(a), 0, cos(a)))
    }
    static func rotX(_ a: Double) -> M3 {
        M3(r0: V3(1, 0, 0), r1: V3(0, cos(a), -sin(a)), r2: V3(0, sin(a), cos(a)))
    }
    static func rotZ(_ a: Double) -> M3 {
        M3(r0: V3(cos(a), -sin(a), 0), r1: V3(sin(a), cos(a), 0), r2: V3(0, 0, 1))
    }
}

/// Draws a calm bust in single-weight line, driven by a real head pose.
///
/// The head is a lofted 3-D surface. Its outline is the convex hull of the projected surface,
/// and every facial line lives *on* the surface, fading as it turns away. That is what makes
/// a few dozen lines read as a person looking around rather than a sticker being rotated.
/// The figure mirrors the user: turn left, and it turns toward the left of the screen.
public enum FigureRenderer {
    /// Height, half-width, front depth, back depth of each head cross-section.
    private static let loft: [(y: Double, rx: Double, front: Double, back: Double)] = [
        (1.06, 0.06, 0.06, 0.08),
        (0.98, 0.36, 0.40, 0.46),
        (0.82, 0.60, 0.64, 0.74),
        (0.56, 0.76, 0.80, 0.93),
        (0.24, 0.81, 0.85, 0.99),
        (-0.06, 0.79, 0.87, 0.88),
        (-0.34, 0.75, 0.85, 0.62),
        (-0.60, 0.69, 0.79, 0.40),
        (-0.84, 0.58, 0.71, 0.26),
        (-1.02, 0.42, 0.61, 0.17),
        (-1.14, 0.20, 0.50, 0.10),
    ]

    private static func section(_ y: Double) -> (rx: Double, front: Double, back: Double) {
        let rows = loft
        if y >= rows[0].y { return (rows[0].rx, rows[0].front, rows[0].back) }
        for (a, b) in zip(rows, rows.dropFirst()) where y >= b.y {
            let t = smoothstep(0, 1, (a.y - y) / (a.y - b.y)) * 0.5 + (a.y - y) / (a.y - b.y) * 0.5
            return (lerp(a.rx, b.rx, t), lerp(a.front, b.front, t), lerp(a.back, b.back, t))
        }
        let last = rows[rows.count - 1]
        return (last.rx, last.front, last.back)
    }

    /// A point on the head. `theta` is degrees around the head, 0 = straight ahead, + = the
    /// person's left (screen right). `lift` raises it off the surface.
    private static func surface(_ theta: Double, _ y: Double, lift: Double = 0) -> (point: V3, normal: V3) {
        let s = section(y)
        let a = Angle.radians(theta)
        let depth = cos(a) >= 0 ? s.front : s.back
        let rx = s.rx + lift
        let rz = depth + lift
        let point = V3(rx * sin(a), y, rz * cos(a))
        let normal = V3(sin(a) / max(rx, 0.1), y * 0.35, cos(a) / max(rz, 0.1)).normalized
        return (point, normal)
    }

    private static let hullPoints: [V3] = {
        var points: [V3] = []
        var y = 1.06
        while y >= -1.14 {
            for theta in stride(from: 0.0, to: 360.0, by: 12.0) { points.append(surface(theta, y).point) }
            y -= 0.07
        }
        return points
    }()

    private struct Feature {
        var points: [(point: V3, normal: V3)]
        var weight: Double
        var opacity: Double
        /// Set on ears: -1 or +1, the side of the head it belongs to.
        var earSide: Double?
    }

    private static func catmull(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double, _ t: Double) -> Double {
        0.5 * (2 * p1 + (p2 - p0) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t + (3 * p1 - p0 - 3 * p2 + p3) * t * t * t)
    }

    /// A smooth stroke through (theta, y, lift) control points. `faceTheta` overrides which way
    /// the stroke counts as facing, for parts like the ear that stand off the surface.
    private static func line(_ weight: Double = 1, _ opacity: Double = 1, faceTheta: Double? = nil,
                             _ spec: [(theta: Double, y: Double, lift: Double)]) -> Feature {
        var dense: [(point: V3, normal: V3)] = []
        func add(_ theta: Double, _ y: Double, _ lift: Double) {
            let hit = surface(theta, y, lift: lift)
            let normal = faceTheta.map { surface($0, y).normal } ?? hit.normal
            dense.append((hit.point, normal))
        }
        for i in 0..<(spec.count - 1) {
            let p0 = spec[max(i - 1, 0)], p1 = spec[i], p2 = spec[i + 1], p3 = spec[min(i + 2, spec.count - 1)]
            for step in 0..<10 {
                let t = Double(step) / 10
                add(catmull(p0.theta, p1.theta, p2.theta, p3.theta, t),
                    catmull(p0.y, p1.y, p2.y, p3.y, t),
                    catmull(p0.lift, p1.lift, p2.lift, p3.lift, t))
            }
        }
        if let last = spec.last { add(last.theta, last.y, last.lift) }
        return Feature(points: dense, weight: weight, opacity: opacity, earSide: faceTheta.map { $0 < 0 ? -1 : 1 })
    }

    private static let features: [Feature] = {
        var all: [Feature] = []
        for side in [-1.0, 1.0] {
            // Brow.
            all.append(line(1, 0.75, [(side * 12, 0.27, 0), (side * 27, 0.33, 0), (side * 49, 0.27, 0)]))
            // Closed, resting eye.
            all.append(line(1.05, 0.95, [(side * 16, 0.095, 0), (side * 28, 0.05, 0), (side * 43, 0.1, 0)]))
            // Nostril wing.
            all.append(line(0.9, 0.55, [(side * 3, -0.335, 0.13), (side * 10, -0.345, 0.06), (side * 13, -0.285, 0.035)]))
            // Ear: stands off the head, so it stays visible until the head has really turned away.
            let ear = 96.0
            let faceTheta = side * 80
            all.append(line(1.1, 0.95, faceTheta: faceTheta, [
                (side * (ear - 6), 0.12, 0.0), (side * (ear - 4), 0.2, 0.07), (side * ear, 0.23, 0.13),
                (side * (ear + 7), 0.19, 0.17), (side * (ear + 12), 0.06, 0.18), (side * (ear + 9), -0.12, 0.14),
                (side * (ear + 2), -0.26, 0.08), (side * (ear - 4), -0.31, 0.01),
            ]))
            all.append(line(0.85, 0.45, faceTheta: faceTheta, [
                (side * (ear + 1), 0.13, 0.07), (side * (ear + 6), 0.03, 0.09), (side * (ear + 3), -0.1, 0.06),
            ]))
            // Hairline: down from the forehead, round the temple, to the top of the ear.
            all.append(line(1, 0.65, [
                (0, 0.7, 0), (side * 26, 0.665, 0), (side * 50, 0.55, 0), (side * 68, 0.4, 0), (side * 80, 0.3, 0),
            ]))
        }
        // Nose: one continuous bridge line, the single most "human" stroke in the drawing.
        all.append(line(1.1, 0.9, [
            (0, 0.03, 0.04), (0, -0.16, 0.14), (0, -0.27, 0.2), (0, -0.335, 0.15), (0, -0.37, 0.05),
        ]))
        // Lips.
        all.append(line(1.05, 0.9, [(-20, -0.62, 0), (-8, -0.6, 0.015), (0, -0.625, 0.02), (8, -0.6, 0.015), (20, -0.62, 0)]))
        all.append(line(0.9, 0.42, [(-9, -0.725, 0.01), (0, -0.74, 0.015), (9, -0.725, 0.01)]))
        return all
    }()

    private struct Camera {
        var center: CGPoint
        var scale: Double
        func project(_ v: V3) -> CGPoint {
            let perspective = 9 / (9 - v.z)
            return CGPoint(x: center.x + v.x * scale * perspective, y: center.y + v.y * scale * perspective)
        }
    }

    /// Straight on: facing the screen must look like facing the screen.
    private static let view = M3.rotX(Angle.radians(3))
    private static let pivot = V3(0, -0.95, -0.12)

    private static func headRotation(_ pose: HeadPose) -> M3 {
        M3.rotY(Angle.radians(-pose.yaw)) * M3.rotX(Angle.radians(-pose.pitch)) * M3.rotZ(Angle.radians(-pose.roll))
    }

    private static func place(_ p: V3, rotation: M3, translate: V3) -> V3 {
        view.apply(rotation.apply(p - pivot) + pivot + translate)
    }

    /// The body answers the head a little, the way a real torso does.
    private static func bodyMotion(_ pose: HeadPose) -> (rotation: M3, translate: V3) {
        let eased = HeadPose(yaw: pose.yaw * 0.16, pitch: pose.pitch * 0.05, roll: pose.roll * 0.14)
        return (headRotation(eased), .init(0, 0, 0))
    }

    private static func hull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [CGPoint] = []
        for p in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [CGPoint] = []
        for p in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// Resamples a closed polygon evenly and rounds it into a smooth closed curve.
    private static func smoothClosed(_ polygon: [CGPoint], samples: Int = 56) -> CGPath {
        let path = CGMutablePath()
        guard polygon.count > 3 else { return path }
        var lengths = [0.0]
        for i in 0..<polygon.count {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            lengths.append(lengths[i] + hypot(b.x - a.x, b.y - a.y))
        }
        let total = lengths[polygon.count]
        var even: [CGPoint] = []
        var segment = 0
        for i in 0..<samples {
            let d = total * Double(i) / Double(samples)
            while segment < polygon.count - 1, lengths[segment + 1] < d { segment += 1 }
            let a = polygon[segment], b = polygon[(segment + 1) % polygon.count]
            let t = (d - lengths[segment]) / max(lengths[segment + 1] - lengths[segment], 0.0001)
            even.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        let mid = { (a: CGPoint, b: CGPoint) in CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        path.move(to: mid(even[samples - 1], even[0]))
        for i in 0..<samples {
            path.addQuadCurve(to: mid(even[i], even[(i + 1) % samples]), control: even[i])
        }
        path.closeSubpath()
        return path
    }

    private static func headOutline(_ pose: HeadPose, camera: Camera) -> CGPath {
        let rotation = headRotation(pose)
        return smoothClosed(hull(hullPoints.map { camera.project(place($0, rotation: rotation, translate: V3(0, 0, 0))) }))
    }

    private static func curve(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard points.count >= 2 else { return path }
        path.move(to: points[0])
        if points.count == 2 { path.addLine(to: points[1]); return path }
        for i in 1..<(points.count - 1) {
            let m = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: i == points.count - 2 ? points[i + 1] : m, control: points[i])
        }
        return path
    }

    public static func draw(in ctx: CGContext, rect: CGRect, state: FigureState, style: FigureStyle) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        // One layer, so the whole drawing dims as a unit and inner fades stay simple.
        ctx.setAlpha(state.dimmed ? 0.45 : 1)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { ctx.endTransparencyLayer() }

        let scale = min(rect.height / 4.15, rect.width / 4.2)
        let camera = Camera(center: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.655), scale: scale)
        let unit = min(scale / 62, 1.0 + scale / 300)

        if let pulse = state.pulse { drawPulse(ctx, camera: camera, unit: unit, progress: pulse, pose: state.pose, style: style) }
        drawBody(ctx, camera: camera, unit: unit, pose: state.pose, style: style)

        for (i, echo) in state.echoes.enumerated() {
            let strength = Double(i + 1) / Double(state.echoes.count + 1)
            let apart = (echo - state.pose).peak
            guard apart > 1.2 else { continue }
            ctx.setStrokeColor(style.ink)
            ctx.setAlpha(0.16 * strength * min(apart / 8, 1))
            ctx.setLineWidth(1.1 * unit)
            ctx.addPath(headOutline(echo, camera: camera))
            ctx.strokePath()
        }
        ctx.setAlpha(1)

        let rotation = headRotation(state.pose)
        drawNeck(ctx, camera: camera, unit: unit, pose: state.pose, style: style)

        // The far ear and AirPod go down first; the head then covers all but what sticks out.
        drawFeatures(ctx, camera: camera, unit: unit, rotation: rotation, style: style) { feature in
            guard let side = feature.earSide else { return false }
            return !isNear(side: side, rotation: rotation)
        }
        drawFarBud(ctx, camera: camera, unit: unit, rotation: rotation, state: state, style: style)

        // Solid paper head: everything behind it disappears, as in a real drawing.
        let outline = headOutline(state.pose, camera: camera)
        ctx.addPath(outline)
        ctx.setFillColor(style.paper)
        ctx.fillPath()

        ctx.addPath(outline)
        ctx.setStrokeColor(style.ink)
        ctx.setLineWidth(1.5 * unit)
        ctx.strokePath()

        drawHair(ctx, camera: camera, rotation: rotation, outline: outline, style: style)
        drawFeatures(ctx, camera: camera, unit: unit, rotation: rotation, style: style) { feature in
            guard let side = feature.earSide else { return true }
            return isNear(side: side, rotation: rotation)
        }
        drawNearBud(ctx, camera: camera, unit: unit, rotation: rotation, state: state, style: style)
    }

    private static func facing(_ normal: V3, rotation: M3) -> Double {
        view.apply(rotation.apply(normal)).z
    }

    private static func isNear(side: Double, rotation: M3) -> Bool {
        // Slightly past the horizon, so head-on both ears and AirPods sit in front of the head.
        facing(surface(side * 96, 0).normal, rotation: rotation) >= -0.2
    }

    /// Where the hair begins, by angle around the head.
    private static func hairEdge(_ theta: Double) -> Double {
        let keys: [(Double, Double)] = [(0, 0.7), (26, 0.665), (50, 0.55), (68, 0.4), (80, 0.3), (104, 0.26), (130, -0.1), (180, -0.5)]
        let a = abs(theta)
        for (lo, hi) in zip(keys, keys.dropFirst()) where a <= hi.0 {
            return lerp(lo.1, hi.1, (a - lo.0) / (hi.0 - lo.0))
        }
        return -0.5
    }

    private static let hairQuads: [(corners: [V3], normal: V3)] = {
        var quads: [(corners: [V3], normal: V3)] = []
        let rows = 7
        for theta in stride(from: -180.0, to: 180.0, by: 10.0) {
            let next = theta + 10
            let edgeA = hairEdge(theta), edgeB = hairEdge(next)
            for r in 0..<rows {
                let u0 = Double(r) / Double(rows), u1 = Double(r + 1) / Double(rows)
                let a0 = lerp(edgeA, 1.06, u0), a1 = lerp(edgeA, 1.06, u1)
                let b0 = lerp(edgeB, 1.06, u0), b1 = lerp(edgeB, 1.06, u1)
                let corners = [surface(theta, a0).point, surface(next, b0).point, surface(next, b1).point, surface(theta, a1).point]
                quads.append((corners, surface(theta + 5, (a0 + a1) / 2).normal))
            }
        }
        return quads
    }()

    private static func drawHair(_ ctx: CGContext, camera: Camera, rotation: M3, outline: CGPath, style: FigureStyle) {
        let path = CGMutablePath()
        let zero = V3(0, 0, 0)
        for quad in hairQuads where facing(quad.normal, rotation: rotation) > -0.05 {
            let points = quad.corners.map { camera.project(place($0, rotation: rotation, translate: zero)) }
            // Same winding for every quad, so the union fills without seams.
            let area = zip(points, points.dropFirst() + points.prefix(1)).reduce(0.0) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y }
            path.addLines(between: area < 0 ? points.reversed() : points)
            path.closeSubpath()
        }
        ctx.saveGState()
        ctx.addPath(outline)
        ctx.clip()
        ctx.addPath(path)
        ctx.setAlpha(0.075)
        ctx.setFillColor(style.ink)
        ctx.fillPath(using: .winding)
        ctx.restoreGState()
    }

    private static func drawFeatures(_ ctx: CGContext, camera: Camera, unit: Double, rotation: M3, style: FigureStyle,
                                     where include: (Feature) -> Bool) {
        ctx.setStrokeColor(style.ink)
        let zero = V3(0, 0, 0)
        for feature in features where include(feature) {
            ctx.setLineWidth(1.15 * feature.weight * unit)
            // Segments, so a line can fade continuously as it rolls over the horizon of the head.
            var run: [CGPoint] = []
            var runAlpha = -1.0
            func flush() {
                guard run.count >= 2, runAlpha > 0.02 else { run.removeAll(); return }
                ctx.saveGState()
                ctx.setAlpha(runAlpha * feature.opacity)
                ctx.addPath(curve(run))
                ctx.strokePath()
                ctx.restoreGState()
                run.removeAll(keepingCapacity: true)
            }
            for (point, normal) in feature.points {
                let alpha = feature.earSide != nil ? 1 : (smoothstep(0.02, 0.3, facing(normal, rotation: rotation)) * 5).rounded() / 5
                let projected = camera.project(place(point, rotation: rotation, translate: zero))
                if alpha != runAlpha {
                    if let last = run.last {
                        flush()
                        run.append(last)
                    }
                    runAlpha = alpha
                }
                run.append(projected)
            }
            flush()
        }
    }

    private static func budPoints(side: Double) -> (top: V3, bottom: V3, normal: V3) {
        // True to scale: an AirPods Pro stem is about a tenth of the head's height.
        let top = surface(side * 90, -0.07, lift: 0.07)
        let bottom = surface(side * 85, -0.31, lift: 0.09)
        return (top.point, bottom.point, surface(side * 72, -0.06).normal)
    }

    private static func drawBud(_ ctx: CGContext, side: Double, alpha: Double, camera: Camera, unit: Double,
                                rotation: M3, state: FigureState, style: FigureStyle) {
        guard alpha > 0.01 else { return }
        let bud = budPoints(side: side)
        let zero = V3(0, 0, 0)
        let a = camera.project(place(bud.top, rotation: rotation, translate: zero))
        let b = camera.project(place(bud.bottom, rotation: rotation, translate: zero))
        ctx.saveGState()
        ctx.setAlpha(alpha)
        if state.budGlow > 0.01 {
            ctx.setShadow(offset: .zero, blur: 7 * unit * state.budGlow, color: style.accent)
        }
        ctx.setLineCap(.round)
        // Stem, then head of the bud: a thick accent line with a paper core reads as white plastic.
        ctx.setStrokeColor(style.accent)
        ctx.setLineWidth(5.6 * unit)
        ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
        ctx.setFillColor(style.accent)
        ctx.fillEllipse(in: CGRect(x: a.x - 5.6 * unit, y: a.y - 5.6 * unit, width: 11.2 * unit, height: 11.2 * unit))
        ctx.setShadow(offset: .zero, blur: 0)
        ctx.setStrokeColor(style.paper)
        ctx.setLineWidth(3.2 * unit)
        ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
        ctx.setFillColor(style.paper)
        ctx.fillEllipse(in: CGRect(x: a.x - 4.2 * unit, y: a.y - 4.2 * unit, width: 8.4 * unit, height: 8.4 * unit))
        ctx.restoreGState()
    }

    private static func drawFarBud(_ ctx: CGContext, camera: Camera, unit: Double, rotation: M3,
                                   state: FigureState, style: FigureStyle) {
        for side in [-1.0, 1.0] where !isNear(side: side, rotation: rotation) {
            drawBud(ctx, side: side, alpha: 0.9, camera: camera, unit: unit, rotation: rotation, state: state, style: style)
        }
    }

    private static func drawNearBud(_ ctx: CGContext, camera: Camera, unit: Double, rotation: M3,
                                    state: FigureState, style: FigureStyle) {
        for side in [-1.0, 1.0] where isNear(side: side, rotation: rotation) {
            drawBud(ctx, side: side, alpha: 1, camera: camera, unit: unit, rotation: rotation, state: state, style: style)
        }
    }

    private static func drawNeck(_ ctx: CGContext, camera: Camera, unit: Double, pose: HeadPose, style: FigureStyle) {
        let head = headRotation(pose)
        let body = bodyMotion(pose)
        ctx.setStrokeColor(style.ink)
        ctx.setLineWidth(1.35 * unit)
        for side in [-1.0, 1.0] {
            let top = place(V3(side * 0.46, -0.66, -0.2), rotation: head, translate: V3(0, 0, 0))
            let mid = place(V3(side * 0.47, -1.24, -0.12), rotation: head.blendTowardIdentity(0.6), translate: V3(0, 0, 0))
            let low = place(V3(side * 0.54, -1.5, -0.08), rotation: body.rotation, translate: V3(0, 0, 0))
            let end = place(V3(side * 0.82, -1.7, -0.08), rotation: body.rotation, translate: V3(0, 0, 0))
            ctx.addPath(curve([top, mid, low, end].map(camera.project)))
            ctx.strokePath()
        }
    }

    private static func drawBody(_ ctx: CGContext, camera: Camera, unit: Double, pose: HeadPose, style: FigureStyle) {
        let body = bodyMotion(pose)
        func at(_ x: Double, _ y: Double, _ z: Double = -0.08) -> CGPoint {
            camera.project(place(V3(x, y, z), rotation: body.rotation, translate: V3(0, 0, 0)))
        }
        ctx.setStrokeColor(style.ink)
        ctx.setLineWidth(1.5 * unit)
        for side in [-1.0, 1.0] {
            // Trapezius into the shoulder, then the arm, dissolving at the bottom of the frame.
            ctx.addPath(curve([at(side * 0.82, -1.7), at(side * 1.25, -1.82), at(side * 1.62, -1.98),
                               at(side * 1.84, -2.3), at(side * 1.9, -2.58)]))
            ctx.strokePath()
            let fade = [at(side * 1.9, -2.58), at(side * 1.91, -2.72), at(side * 1.92, -2.84)]
            for (i, pair) in zip(fade, fade.dropFirst()).enumerated() {
                ctx.saveGState()
                ctx.setAlpha(i == 0 ? 0.55 : 0.2)
                ctx.move(to: pair.0); ctx.addLine(to: pair.1); ctx.strokePath()
                ctx.restoreGState()
            }
        }
        // Crew neckline.
        ctx.setLineWidth(1.15 * unit)
        ctx.saveGState()
        ctx.setAlpha(0.8)
        ctx.addPath(curve([at(-0.82, -1.7, 0.1), at(-0.5, -1.95, 0.3), at(0, -2.06, 0.42),
                           at(0.5, -1.95, 0.3), at(0.82, -1.7, 0.1)]))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func drawPulse(_ ctx: CGContext, camera: Camera, unit: Double, progress: Double,
                                  pose: HeadPose, style: FigureStyle) {
        let center = camera.project(place(V3(0, 0, 0), rotation: headRotation(pose), translate: V3(0, 0, 0)))
        for ring in 0..<2 {
            let p = progress - Double(ring) * 0.18
            guard p > 0 else { continue }
            let radius = (70 + 90 * (1 - pow(1 - p, 3))) * unit
            ctx.saveGState()
            ctx.setStrokeColor(style.accent)
            ctx.setAlpha((1 - p) * 0.7)
            ctx.setLineWidth(1.5 * unit)
            ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            ctx.restoreGState()
        }
    }
}

private extension M3 {
    func blendTowardIdentity(_ t: Double) -> M3 {
        func mix(_ a: V3, _ b: V3) -> V3 { V3(lerp(a.x, b.x, t), lerp(a.y, b.y, t), lerp(a.z, b.z, t)) }
        return M3(r0: mix(r0, V3(1, 0, 0)), r1: mix(r1, V3(0, 1, 0)), r2: mix(r2, V3(0, 0, 1)))
    }
}
