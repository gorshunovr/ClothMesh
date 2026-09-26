import Foundation
import simd

/// A scripted, demoscene-style run of the playground: camera moves, invisible "hands" that grab
/// the cloth, gravity / wind changes and an animated look. Everything is keyed on simulated time,
/// so the choreography stays in sync with the physics even if frames drop.
final class DemoDirector {
    static let duration = Float(Soundtrack.duration)
    static let denseResolution = 64

    /// Demo physics ignore the HUD sliders.
    static var baseParams: ClothSim.Params {
        var p = ClothSim.Params()
        p.floorY = floorY
        return p
    }
    private static let floorY: Float = -0.42

    private(set) var time: Float = 0
    private(set) var look = Look()
    var isFinished: Bool { time >= Self.duration }

    private unowned let renderer: Renderer
    private var sim: ClothSim { renderer.sim }

    private struct Hand {
        var id: Int
        var start: SIMD3<Float>
        var t0: Float
        var blend: Float
        var path: (Float) -> SIMD3<Float>
    }
    private var hands: [String: Hand] = [:]
    private var cues: [(time: Float, action: (DemoDirector) -> Void)] = []
    private var nextCue = 0
    private var flashes: [(time: Float, strength: Float)] = []
    private var prepared: [Int: [ClothSim]] = [:]
    private var caption: String?
    private var player: SoundtrackPlayer?

    /// `music: false` runs on simulated time without audio (offline rendering, tests).
    init(renderer: Renderer, music: Bool = true) {
        self.renderer = renderer
        renderer.replaceSim(ClothSim.draped(resolution: 48, params: Self.baseParams))
        // Pre-drape the sheets for the hard cuts so they don't stall a frame.
        prepare(resolution: 48)
        prepare(resolution: Self.denseResolution)
        cues = Self.script().sorted { $0.time < $1.time }
        updateFrame()
        // Start the music last, once the expensive setup above is done.
        let player = music ? SoundtrackPlayer() : nil
        self.player = (player?.start() ?? false) ? player : nil
    }

    deinit {
        player?.stop()
    }

    /// Drives the clock externally instead of the music (offline video rendering).
    var manualClock: Float?

    /// Where the demo should be now (music or manual clock); nil when free-running on simulated time.
    var clockTime: Float? {
        if let manualClock { return manualClock }
        guard let player else { return nil }
        return Float(player.time ?? 0)
    }

    /// The caption shown at `t` and its opacity (fades 0.5 s in and out).
    static func caption(at t: Float) -> (text: String, opacity: Float)? {
        guard let c = captions.first(where: { t >= $0.start - 0.5 && t < $0.end + 0.5 }) else { return nil }
        let opacity = min(max(min(t - c.start + 0.5, c.end + 0.5 - t), 0), 1)
        return (c.text, opacity)
    }

    // MARK: - Per substep / per frame

    func advance(dt: Float) {
        time += dt
        while nextCue < cues.count && cues[nextCue].time <= time {
            cues[nextCue].action(self)
            nextCue += 1
        }

        var p = Self.baseParams
        p.gravityScale = Self.gravity.value(time)
        let windAmp = Self.windAmount.value(time)
        p.wind = windAmp * SIMD3<Float>(sin(1.3 * time), 0.35 * sin(0.7 * time + 1), cos(1.1 * time))
        sim.params = p

        for hand in hands.values {
            let s = smooth01((time - hand.t0) / hand.blend)
            sim.moveGrab(hand.id, to: mix(hand.start, hand.path(time), t: s))
        }
    }

    /// Advances the script without physics (catching up after a stall).
    func skip(steps: Int, dt: Float) {
        for _ in 0..<steps { advance(dt: dt) }
    }

    func updateFrame() {
        let t = time

        var cam = OrbitCamera()
        cam.yaw = Math.radians(Self.camYaw.value(t))
        cam.pitch = Math.radians(Self.camPitch.value(t))
        // Punch in a touch on every kick.
        let kick = Soundtrack.kickLevel(at: Double(t))
        cam.distance = Self.camDistance.value(t) * (1 - 0.012 * kick)
        cam.target = SIMD3<Float>(0, Self.camTargetY.value(t), 0)
        renderer.camera = cam

        let hue = Self.hue.value(t)
        var l = Look()
        l.wireColor = rgba(hsv(hue, Self.wireSaturation.value(t), 1), 0.75 + 0.25 * kick)
        l.wireColor2 = rgba(hsv(hue + 0.33, 0.85, 1), 0.95)
        l.wave = SIMD4<Float>(Self.waveAmount.value(t), 9, 3, 0)
        l.fillColor = rgba(hsv(hue - 0.04, 0.75, 0.55), Self.fillAlpha.value(t))
        l.colliderColor = rgba(hsv(hue + 0.5, 0.45, 0.9), Self.colliderAlpha.value(t))
        l.additiveWires = true
        l.floorColor = rgba(hsv(hue + 0.12, 0.7, 0.9), Self.floorAlpha.value(t) * (1 + 0.8 * kick))
        l.floorY = Self.floorY
        l.showGrabDots = true
        l.showHeldVertices = false
        l.grabColor = rgba(hsv(hue + 0.5, 0.35, 1), 0.9)
        l.background = (top: rgba(hsv(hue + 0.1, 0.8, 0.10), 1),
                        bottom: SIMD4<Float>(0.008, 0.008, 0.015, 1),
                        glow: rgba(hsv(hue + 0.1, 0.8, 1), 0.06 + 0.07 * kick))
        l.fade = Self.fade.value(t)
        l.flash = min(1, flashes.reduce(0) { acc, f in
            t < f.time ? acc : acc + f.strength * exp(-(t - f.time) * 5)
        })
        l.vignette = 0.6 - 0.12 * kick
        l.scanlines = 0.08
        look = l

        let current = Self.captions.first { t >= $0.start && t < $0.end }?.text
        if current != caption {
            caption = current
            renderer.model.caption = current
        }
    }

    // MARK: - Script helpers

    private func gridIndex(_ fx: Float, _ fz: Float) -> (Int, Int) {
        let n = sim.mesh.nx
        return (Int((fx * Float(n - 1)).rounded()), Int((fz * Float(sim.mesh.ny - 1)).rounded()))
    }

    private func gridPos(_ fx: Float, _ fz: Float) -> SIMD3<Float> {
        let (x, z) = gridIndex(fx, fz)
        return sim.positions[sim.mesh.index(x, z)]
    }

    /// Grabs a patch at grid fraction (fx, fz) and eases it from where it is onto `path`.
    private func grab(_ name: String, _ fx: Float, _ fz: Float, blend: Float,
                      path: @escaping (Float) -> SIMD3<Float>) {
        release(name)
        let (x, z) = gridIndex(fx, fz)
        let id = sim.beginGrab(gridX: x, z: z, radius: max(1, sim.mesh.nx / 24))
        hands[name] = Hand(id: id, start: sim.grabs[id]!.target, t0: time, blend: blend, path: path)
    }

    private func release(_ name: String) {
        if let h = hands.removeValue(forKey: name) { sim.endGrab(h.id) }
    }

    private func releaseAll() {
        for name in Array(hands.keys) { release(name) }
    }

    /// Pushes free vertices away from the vertical axis through `center` (a jellyfish "pump").
    private func pulse(from center: SIMD3<Float>, outward: Float, up: Float) {
        sim.addVelocity { p in
            var d = p - center
            d.y = 0
            let len = max(length(d), 0.05)
            return d / len * outward * min(len / 0.4, 1) + SIMD3<Float>(0, up, 0)
        }
    }

    private func handTarget(_ name: String) -> SIMD3<Float>? {
        hands[name].flatMap { sim.grabs[$0.id]?.target }
    }

    private func flash(_ strength: Float = 0.8) {
        flashes.append((time, strength))
    }

    /// Hard cut to a freshly draped sheet (pre-built in the background when possible).
    private func cut(to resolution: Int) {
        hands.removeAll()
        let next = prepared[resolution]?.popLast()
            ?? ClothSim.draped(resolution: resolution, params: Self.baseParams)
        renderer.replaceSim(next)
        flash(1)
    }

    /// Hard cut to a flat, undraped sheet hanging in the air at `height`.
    private func cutToFlatSheet(resolution: Int, height: Float) {
        hands.removeAll()
        renderer.replaceSim(ClothSim(mesh: ClothMesh(nx: resolution, ny: resolution, height: height),
                                     params: Self.baseParams))
        flash(1)
    }

    private func prepare(resolution: Int) {
        let params = Self.baseParams
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let s = ClothSim.draped(resolution: resolution, params: params)
            DispatchQueue.main.async { self?.prepared[resolution, default: []].append(s) }
        }
    }

    // MARK: - The script

    /// Scenes change on 4-bar phrases (8 s at 120 BPM); grabs and releases land on beats.
    private static func script() -> [(time: Float, action: (DemoDirector) -> Void)] {
        var cues: [(time: Float, action: (DemoDirector) -> Void)] = [
            // 8–16: two hands lift opposite corners into a sail over the ball, sway, let go.
            (8, { d in
                d.grab("L", 0, 0, blend: 2.5) { t in SIMD3(-0.78, 0.9 + 0.12 * sin(.pi * (t - 8)), -0.78) }
                d.grab("R", 1, 1, blend: 2.5) { t in SIMD3(0.78, 0.9 - 0.12 * sin(.pi * (t - 8)), 0.78) }
            }),
            (14, { d in d.release("L"); d.release("R") }),

            // 16–24: the ball appears; the crown is pulled up in a vortex, one turn per 2 bars.
            (17, { d in
                d.grab("C", 0.5, 0.5, blend: 1.0) { t in
                    let u = t - 17
                    let lift = 0.45 * smooth01(u / 2)
                    return SIMD3(0.22 * cos(.pi * u), 0.74 + lift + 0.05 * sin(2 * .pi * u), 0.22 * sin(.pi * u))
                }
            }),
            (23, { d in d.release("C") }),

            // 24–32: breakdown, zero gravity: a jellyfish pumping on every bar.
            (24.25, { d in
                d.grab("J", 0.5, 0.5, blend: 1.5) { t in
                    let u = t - 24.25
                    return SIMD3(0.18 * sin(0.8 * u),
                                 1.0 + 0.2 * smooth01(u / 2) + 0.16 * sin(.pi * (t - 24)),
                                 0.18 * cos(0.8 * u) - 0.18)
                }
            }),
            (31.5, { d in d.release("J") }),

            // 32–36: gravity returns on the drop. 36–48: fresh sheet, folded over itself twice.
            (36, { d in d.cut(to: 48) }),
            (37, { d in
                let p0 = d.gridPos(0.5, 1)
                d.grab("F1", 0.5, 1, blend: 0.01) { t in
                    bezier(p0, SIMD3(0, 1.1, 0.45), SIMD3(0, 0.84, -0.15), smooth01((t - 37) / 4))
                }
            }),
            (40.5, { d in
                let p0 = d.gridPos(0, 0.5)
                d.grab("F2", 0, 0.5, blend: 0.01) { t in
                    bezier(p0, SIMD3(-0.45, 1.1, 0), SIMD3(0.15, 0.92, 0.05), smooth01((t - 40.5) / 3.5))
                }
            }),
            (46, { d in d.releaseAll() }),

            // 48–56: the drop. Hard cut to a dense net; drag it off the ball onto the floor.
            (48, { d in d.cut(to: denseResolution) }),
            (49, { d in
                let p0 = d.gridPos(0.5, 0.02)
                d.grab("P", 0.5, 0.02, blend: 0.01) { t in
                    bezier(p0, SIMD3(0, 0.25, -1.3), SIMD3(0.35, -0.3, -1.9), smooth01((t - 49) / 4.5))
                }
            }),
            (55, { d in d.release("P") }),

            // 56–64: build. A flat sheet falls onto the ball, then two hands shake it like a rug,
            // one snap per beat, and let go just before the downbeat at 64.
            (56, { d in d.cutToFlatSheet(resolution: 48, height: 1.9) }),
            (58.5, { d in
                for (name, fx, side) in [("S0", Float(0), Float(-1)), ("S1", 1, 1)] {
                    d.grab(name, fx, 0.5, blend: 1.5) { t in
                        let shake = t < 60 ? 0 : 0.22 * sin(2 * .pi * 2 * (t - 60)) * side
                        return SIMD3(0.95 * side, 0.8 + shake, 0)
                    }
                }
            }),
            (63.5, { d in d.releaseAll() }),
        ]
        // Jellyfish pumps on each bar of the breakdown.
        for t: Float in [26, 28, 30] {
            cues.append((t, { d in if let c = d.handTarget("J") { d.pulse(from: c, outward: 1.6, up: -0.4) } }))
        }
        // A flash on every crash cymbal (cuts add their own).
        for t in Soundtrack.crashTimes where ![48, 56].contains(t) {
            cues.append((Float(t), { d in d.flash(0.6) }))
        }
        return cues
    }

    private static let captions: [(start: Float, end: Float, text: String)] = [
        (24.5, 28.5, "GRAVITY OFF"),
        (32, 35, "GRAVITY ON"),
        (37, 41, "SELF-COLLISION"),
        (48.5, 52.5, "\(denseResolution) × \(denseResolution) · \(denseResolution * denseResolution) VERTICES"),
    ]

    // MARK: - Tracks

    private static let camYaw = Track(smooth: true, [
        (0, 200), (6.67, 250), (16, 330), (17.6, 360), (23.2, 420), (25.09, 430), (32.73, 520), (36, 540),
        (38.18, 560), (47.97, 620), (48, 620), (55.97, 800), (56, 810), (63.53, 900), (68.94, 930), (76, 950),
    ])
    private static let camPitch = Track(smooth: true, [
        (0, 35), (6.67, 25), (16, 18), (17.6, 8), (23.2, 12), (25.09, 20), (32.73, 15), (36, 30),
        (38.18, 55), (47.97, 45), (48, 25), (55.97, 20), (56, 20), (63.53, 30), (68.94, 28), (76, 35),
    ])
    private static let camDistance = Track(smooth: true, [
        (0, 7.5), (6.67, 3.8), (16, 3.4), (17.6, 2.7), (23.2, 2.8), (25.09, 3.6), (32.73, 3.8), (36, 3.4),
        (38.18, 3.0), (47.97, 3.2), (48, 3.0), (55.97, 3.4), (56, 4.6), (58, 3.9), (61.5, 3.7), (63.5, 4.3), (65, 3.9), (68.94, 4.8), (76, 6.5),
    ])
    private static let camTargetY = Track(smooth: true, [
        (0, 0.1), (6.67, 0.15), (16, 0.3), (17.6, 0.25), (23.2, 0.3), (25.09, 0.6), (32.73, 0.5), (36, 0.2),
        (38.18, 0.2), (47.97, 0.2), (48, 0.1), (55.97, 0.0), (56, 0.95), (58, 0.4), (61.5, 0.45), (63.5, 0.6), (65, 0.3), (68.94, 0.2), (76, 0.1),
    ])
    /// Continuous hue (wraps mod 1), so ramps sweep through the palette.
    private static let hue = Track([
        (0, 0.50), (12.8, 0.46), (16.4, 0.46), (17.6, 1.08), (23.2, 1.08), (25.09, 1.80), (32.73, 2.10), (36, 2.08),
        (38.18, 2.95), (47.97, 2.95), (48, 3.0), (55.97, 4.0), (56, 3.48), (63.53, 3.55), (76, 3.50),
    ])
    private static let wireSaturation = Track([(0, 0.35), (24, 0.35), (25.09, 0.6), (32.73, 0.6), (34.91, 0.45), (76, 0.35)])
    private static let waveAmount = Track([
        (0, 0), (24.55, 0), (25.64, 0.7), (32.18, 0.7), (33.82, 0), (47.97, 0), (48, 0.9), (55.97, 0.9),
        (56, 0), (63.53, 0), (64.71, 0.5), (76, 0.5),
    ])
    private static let fillAlpha = Track([
        (0, 0), (9.6, 0), (12, 0.26), (23.2, 0.26), (25.09, 0.16), (32.73, 0.16), (36, 0.32), (47.97, 0.32),
        (48, 0.10), (55.97, 0.10), (56, 0.26), (76, 0.26),
    ])
    private static let colliderAlpha = Track([(16, 0), (17, 0.2), (22, 0.2), (23.5, 0)])
    private static let floorAlpha = Track([(4, 0), (8, 0.35)])
    private static let fade = Track([(0, 1), (3, 0), (72, 0), (75.5, 1)])
    private static let gravity = Track([(24, 1), (24.5, 0), (31.5, 0), (32, 1)])
    private static let windAmount = Track([(24, 0), (25, 1.6), (31.5, 1.6), (32, 0)])
}

/// Keyframed scalar. `smooth` uses Catmull-Rom tangents (for camera moves); otherwise each
/// segment eases in and out, which never overshoots. Keys closer than 0.05 s are a hard cut.
private struct Track {
    let keys: [(t: Float, v: Float)]
    let smooth: Bool

    init(smooth: Bool = false, _ keys: [(Float, Float)]) {
        self.keys = keys.map { (t: $0.0, v: $0.1) }
        self.smooth = smooth
    }

    func value(_ t: Float) -> Float {
        guard let first = keys.first, let last = keys.last else { return 0 }
        if t <= first.t { return first.v }
        if t >= last.t { return last.v }
        var i = 0
        while i + 2 < keys.count && keys[i + 1].t <= t { i += 1 }
        let k0 = keys[i], k1 = keys[i + 1]
        let h = k1.t - k0.t
        if h < 0.05 { return k1.v }
        let s = (t - k0.t) / h
        guard smooth else { return k0.v + (k1.v - k0.v) * smooth01(s) }
        let m0 = tangent(i) * h, m1 = tangent(i + 1) * h
        let s2 = s * s, s3 = s2 * s
        return (2 * s3 - 3 * s2 + 1) * k0.v + (s3 - 2 * s2 + s) * m0
            + (-2 * s3 + 3 * s2) * k1.v + (s3 - s2) * m1
    }

    private func tangent(_ i: Int) -> Float {
        guard i > 0, i < keys.count - 1 else { return 0 }
        let prev = keys[i - 1], cur = keys[i], next = keys[i + 1]
        if cur.t - prev.t < 0.05 || next.t - cur.t < 0.05 { return 0 }
        return (next.v - prev.v) / (next.t - prev.t)
    }
}

private func smooth01(_ x: Float) -> Float {
    let c = min(max(x, 0), 1)
    return c * c * (3 - 2 * c)
}

private func bezier(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ s: Float) -> SIMD3<Float> {
    let u = 1 - s
    return u * u * a + 2 * u * s * b + s * s * c
}

private func hsv(_ h: Float, _ s: Float, _ v: Float) -> SIMD3<Float> {
    let k = SIMD3<Float>(1, 2.0 / 3.0, 1.0 / 3.0) + h
    let f = k - floor(k)
    let rgb = simd_clamp(abs(f * 6 - 3) - 1, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
    return v * mix(SIMD3<Float>(repeating: 1), rgb, t: s)
}

private func rgba(_ c: SIMD3<Float>, _ a: Float) -> SIMD4<Float> {
    SIMD4<Float>(c, a)
}
