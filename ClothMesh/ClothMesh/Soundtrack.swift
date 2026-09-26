import Foundation

/// A single note of the soundtrack. The same list drives the synth, the MIDI export and the
/// beat-reactive visuals, so all three always agree.
struct NoteEvent {
    enum Instrument: Int, CaseIterable {
        case kick, snare, closedHat, openHat, crash, bass, arp, pad, lead
    }

    var instrument: Instrument
    /// Seconds from the start of the demo.
    var start: Double
    var length: Double
    var note: Int
    var velocity: Float
}

/// Procedural 120 BPM demoscene track (A minor, i–VI–III–VII) and the synth that plays it.
///
/// Rendering is deterministic: starting from sample 0 always produces the same audio, so the
/// exported WAV matches what plays live in the demo.
final class Soundtrack {
    // MARK: - Arrangement

    static let bpm = 120.0
    static let beat = 60 / bpm
    static let step = beat / 4
    static let bar = beat * 4
    /// One phrase = 4 bars = 8 s. Demo scenes change on phrase boundaries.
    static let phrase = bar * 4
    static let duration = 76.0

    enum Part { case kick, snare, hat, openHat, bass, arp, pad, lead, leadHigh }

    /// What plays in each 8 s phrase.
    static let phrases: [Set<Part>] = [
        [.pad, .arp],                                                     //  0– 8 intro
        [.kick, .bass, .hat, .pad, .arp],                                 //  8–16 sail
        [.kick, .bass, .hat, .openHat, .snare, .pad, .arp, .lead],        // 16–24 the ball
        [.pad, .arp, .hat],                                               // 24–32 breakdown (zero-g)
        [.kick, .bass, .hat, .openHat, .snare, .pad, .arp],               // 32–40 gravity on
        [.kick, .bass, .hat, .openHat, .snare, .pad, .arp, .lead],        // 40–48 folds
        [.kick, .bass, .hat, .openHat, .snare, .pad, .arp, .leadHigh],    // 48–56 dense net (drop)
        [.kick, .bass, .hat, .openHat, .snare, .pad, .arp],               // 56–64 drop + rug shake (build)
        [.kick, .bass, .hat, .pad, .arp, .lead],                          // 64–72 release
        [.pad, .arp],                                                     // 72–76 outro
    ]
    static let crashTimes: [Double] = [8, 16, 32, 48, 56, 64]
    static let risers: [ClosedRange<Double>] = [6...8, 30...32, 46...48, 62...64]
    static let snareRolls: [ClosedRange<Double>] = [30...32, 46...48, 62...64]
    /// Kick drops out for tension before these drops.
    static let kickMutes: [Range<Double>] = [46..<48, 62..<64]

    /// Triads for i–VI–III–VII: Am, F, C (2nd inv.), G (1st inv.).
    static let chords: [[Int]] = [[57, 60, 64], [53, 57, 60], [55, 60, 64], [55, 59, 62]]
    static let bassRoots = [45, 41, 48, 43]

    /// Lead melody over one 4-bar chord cycle: (16th step in bar, MIDI note, length in 16ths).
    static let melody: [[(Int, Int, Int)]] = [
        [(0, 76, 3), (4, 81, 2), (6, 79, 2), (8, 76, 4), (12, 74, 2), (14, 72, 2)],
        [(0, 72, 3), (4, 77, 2), (6, 76, 2), (8, 72, 4), (12, 69, 4)],
        [(0, 67, 3), (4, 72, 2), (6, 74, 2), (8, 76, 4), (12, 79, 2), (14, 76, 2)],
        [(0, 74, 6), (8, 71, 2), (10, 74, 2), (12, 79, 4)],
    ]

    static func parts(at t: Double) -> Set<Part> {
        guard t >= 0, t < duration else { return [] }
        return phrases[min(Int(t / phrase), phrases.count - 1)]
    }

    static func plays(_ part: Part, at t: Double) -> Bool {
        if part == .kick && kickMutes.contains(where: { $0.contains(t) }) { return false }
        return parts(at: t).contains(part)
    }

    /// Chord index for a bar; the outro holds the tonic.
    static func chord(bar: Int) -> Int { bar >= 36 ? 0 : bar % 4 }

    /// Arp filter cutoff (Hz): opens through the intro, muffles in the breakdown, sweeps in the build.
    static func arpCutoff(at t: Double) -> Double {
        switch t {
        case ..<8: return 300 + 3200 * pow(t / 8, 2)
        case 24..<32: return 700 + 900 * sin((t - 24) / 8 * .pi)
        case 56..<64: return 1200 + 4500 * (t - 56) / 8
        default: return 3500
        }
    }

    /// 0…1 envelope of the most recent kick, for visuals that pump with the beat.
    static func kickLevel(at t: Double) -> Float {
        guard plays(.kick, at: t) else { return 0 }
        return Float(exp(-t.truncatingRemainder(dividingBy: beat) * 8))
    }

    static let events: [NoteEvent] = makeEvents()

    private static func makeEvents() -> [NoteEvent] {
        var ev: [NoteEvent] = []
        func add(_ i: NoteEvent.Instrument, _ start: Double, _ length: Double, _ note: Int, _ vel: Float) {
            ev.append(NoteEvent(instrument: i, start: start, length: length, note: note, velocity: vel))
        }

        let steps = Int(duration / step)
        for s in 0..<steps {
            let t = Double(s) * step
            let inBeat = s % 4, inBar = s % 16, bar = s / 16
            let c = chord(bar: bar)
            let inRoll = snareRolls.contains { $0.contains(t) && t < $0.upperBound }

            if inBeat == 0 && plays(.kick, at: t) { add(.kick, t, 0.1, 36, 1) }
            if inBar % 8 == 4 && plays(.snare, at: t) && !inRoll { add(.snare, t, 0.1, 38, 0.9) }
            if plays(.hat, at: t) { add(.closedHat, t, 0.05, 42, inBeat == 2 ? 0.8 : 0.4) }
            if inBeat == 2 && plays(.openHat, at: t) { add(.openHat, t, 0.2, 46, 0.6) }
            if inBeat != 0 && plays(.bass, at: t) {
                add(.bass, t, step * 0.8, bassRoots[c], inBeat == 2 ? 1 : 0.8)
            }
            if plays(.arp, at: t) {
                let tones = chords[c].map { $0 + 12 } + [chords[c][0] + 24]
                let pattern = [0, 1, 2, 3, 2, 1, 2, 3]
                let fade: Float = t >= 72 ? Float(max(0, (76 - t) / 4)) : 1
                add(.arp, t, step * 0.9, tones[pattern[s % 8]], (inBeat == 0 ? 0.9 : 0.65) * fade)
            }
            // The outro chord is held from bar 36 to the end.
            if inBar == 0 && bar <= 36 && plays(.pad, at: t) {
                let intro: Float = t < 8 ? Float(0.35 + 0.65 * t / 8) : 1
                let length = bar == 36 ? duration - t : Self.bar
                for n in chords[c] { add(.pad, t, length, n, 0.8 * intro) }
            }
            let part = parts(at: t)
            if inBar == 0 && (part.contains(.lead) || part.contains(.leadHigh)) {
                let octave = part.contains(.leadHigh) ? 12 : 0
                for (st, note, len) in melody[bar % 4] {
                    add(.lead, t + Double(st) * step, Double(len) * step * 0.95, note + octave, 0.85)
                }
            }
        }

        // Snare rolls: 16ths, then 32nds in the last bar, getting louder.
        for roll in snareRolls {
            var t = roll.lowerBound
            while t < roll.upperBound - 1e-6 {
                let u = (t - roll.lowerBound) / (roll.upperBound - roll.lowerBound)
                add(.snare, t, 0.05, 38, Float(0.35 + 0.6 * u))
                t += u < 0.5 ? step : step / 2
            }
        }
        for t in crashTimes { add(.crash, t, 2, 49, 1) }
        return ev.sorted { $0.start < $1.start }
    }

    // MARK: - Synth

    let sampleRate: Double
    /// Next sample to be rendered.
    private(set) var sampleIndex = 0

    private struct Voice {
        var event: NoteEvent
        var startSample: Int
        var frequency: Double
    }

    private var voices: [Voice] = []
    private var nextEvent = 0
    private var rng: UInt32 = 0x1234_5678

    private var lastKickSample = -1_000_000
    private var lastBassSample = -1_000_000
    private var lastBassVelocity: Float = 1

    private var bassFilter = SVF()
    private var arpFilter = SVF()
    private var leadFilter = SVF()
    private var padFilterL = SVF()
    private var padFilterR = SVF()
    private var riserFilter = SVF()
    private var noiseLow: Float = 0
    private var snareNoiseLow: Float = 0

    private var delayL: [Float]
    private var delayR: [Float]
    private var delayPos = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        // Dotted-eighth ping-pong echo: 3/16 of a bar at 120 BPM = 0.375 s.
        let delayLength = Int(0.375 * sampleRate)
        delayL = Array(repeating: 0, count: delayLength)
        delayR = Array(repeating: 0, count: delayLength)
    }

    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        for f in 0..<frames {
            let (l, r) = renderSample()
            left[f] = l
            right[f] = r
        }
    }

    private func noise() -> Float {
        rng ^= rng << 13
        rng ^= rng >> 17
        rng ^= rng << 5
        return Float(rng) / Float(UInt32.max) * 2 - 1
    }

    private static func frequency(_ note: Int) -> Double {
        440 * pow(2, Double(note - 69) / 12)
    }

    private func coefficient(_ hz: Double) -> Float {
        Float(min(2 * sin(Double.pi * min(hz, sampleRate / 6) / sampleRate), 1))
    }

    private func renderSample() -> (Float, Float) {
        let n = sampleIndex
        let sr = sampleRate
        let t = Double(n) / sr
        sampleIndex += 1

        // Start notes that begin at this sample.
        let events = Self.events
        while nextEvent < events.count && Int(events[nextEvent].start * sr) <= n {
            let e = events[nextEvent]
            voices.append(Voice(event: e, startSample: n, frequency: Self.frequency(e.note)))
            if e.instrument == .kick { lastKickSample = n }
            if e.instrument == .bass {
                lastBassSample = n
                lastBassVelocity = e.velocity
            }
            nextEvent += 1
        }

        let white = noise()
        noiseLow += 0.35 * (white - noiseLow)
        let hiss = white - noiseLow                     // bright noise for hats / crash
        snareNoiseLow += 0.5 * (white - snareNoiseLow)  // darker noise for the snare

        var drums: Float = 0, bass: Float = 0, arp: Float = 0, lead: Float = 0
        var padL: Float = 0, padR: Float = 0

        var i = 0
        while i < voices.count {
            let v = voices[i]
            let e = v.event
            let x = Double(n - v.startSample) / sr   // seconds since note on
            let gate = x < e.length
            let vel = e.velocity
            var alive = true

            switch e.instrument {
            case .kick:
                let phase = 45 * x + 90 * (1 - exp(-x * 30)) / 30
                drums += Float(sin(2 * .pi * phase) * exp(-x * 7)) * vel * 0.95
                drums += white * Float(exp(-x * 300)) * 0.25 * vel
                alive = x < 0.5
            case .snare:
                let body = Float(sin(2 * .pi * 185 * x) * exp(-x * 25)) * 0.5
                drums += (body + snareNoiseLow * Float(exp(-x * 14))) * vel * 0.4
                alive = x < 0.35
            case .closedHat:
                drums += hiss * Float(exp(-x * 70)) * vel * 0.22
                alive = x < 0.1
            case .openHat:
                drums += hiss * Float(exp(-x * 9)) * vel * 0.13
                alive = x < 0.4
            case .crash:
                drums += hiss * Float(exp(-x * 1.3)) * vel * 0.22
                alive = x < 4
            case .bass:
                let p = v.frequency * x
                let saw = Float(2 * (p - floor(p)) - 1)
                let p2 = v.frequency * 1.007 * x
                let saw2 = Float(2 * (p2 - floor(p2)) - 1)
                let env = gate ? Float(min(x / 0.003, 1)) : Float(exp(-(x - e.length) * 60))
                bass += (saw + 0.6 * saw2) * env * vel
                alive = x < e.length + 0.1
            case .arp:
                let p = v.frequency * x
                let pulse: Float = (p - floor(p)) < 0.25 ? 1 : -1
                arp += pulse * Float(exp(-x * 16)) * vel
                alive = x < 0.35
            case .pad:
                let attack = min(x / 0.25, 1)
                let env = Float(gate ? attack : attack * exp(-(x - e.length) * 6))
                // Three detuned saws per note, spread across the stereo field.
                for (k, detune) in [0.996, 1.0, 1.004].enumerated() {
                    let p = v.frequency * detune * t + Double(k) * 0.31
                    let s = Float(2 * (p - floor(p)) - 1) * env * vel
                    padL += s * (k == 2 ? 0.4 : 1)
                    padR += s * (k == 0 ? 0.4 : 1)
                }
                alive = x < e.length + 0.8
            case .lead:
                let vibrato = 1 + 0.004 * sin(2 * .pi * 5.5 * x) * min(max((x - 0.12) / 0.2, 0), 1)
                let p = v.frequency * vibrato * x
                let frac = p - floor(p)
                let s = Float(2 * frac - 1) * 0.6 + (frac < 0.5 ? 0.4 : -0.4)
                let env = gate ? Float(min(x / 0.01, 1)) : Float(exp(-(x - e.length) * 25))
                lead += s * env * vel
                alive = x < e.length + 0.25
            }

            if alive {
                i += 1
            } else {
                voices.swapAt(i, voices.count - 1)
                voices.removeLast()
            }
        }

        // Filters.
        let kickAge = Double(n - lastKickSample) / sr
        let duck = Float(1 - 0.6 * exp(-kickAge * 9))  // sidechain pump
        let bassAge = Double(n - lastBassSample) / sr
        let bassCut = 180 + 1700 * exp(-bassAge * 22) * Double(lastBassVelocity)
        bass = bassFilter.lowpass(bass, f: coefficient(bassCut), q: 0.35)
        arp = arpFilter.lowpass(arp, f: coefficient(Self.arpCutoff(at: t)), q: 0.6)
        lead = leadFilter.lowpass(lead, f: coefficient(3200), q: 0.9)
        padL = padFilterL.lowpass(padL, f: coefficient(1400), q: 0.9)
        padR = padFilterR.lowpass(padR, f: coefficient(1400), q: 0.9)

        // Noise risers into the drops.
        var riser: Float = 0
        for r in Self.risers where r.contains(t) {
            let u = (t - r.lowerBound) / (r.upperBound - r.lowerBound)
            let band = riserFilter.bandpass(white, f: coefficient(300 * pow(30, u)), q: 0.3)
            riser += band * Float(u * u) * 0.5
        }

        // Ping-pong echo on arp + lead.
        let send = arp * 0.35 + lead * 0.25
        let echoL = delayL[delayPos], echoR = delayR[delayPos]
        delayL[delayPos] = send + echoR * 0.4
        delayR[delayPos] = echoL * 0.4
        delayPos = (delayPos + 1) % delayL.count

        let mid = drums + riser + (bass * 0.42) * duck + arp * 0.16 + lead * 0.2
        var l = mid + padL * 0.07 * duck + echoL * 0.5
        var r = mid + padR * 0.07 * duck + echoR * 0.5

        let master: Float = t < 72 ? 1 : Float(max(0, (Self.duration - t) / 4))
        l = tanh(l * 1.1) * 0.85 * master
        r = tanh(r * 1.1) * 0.85 * master
        return (l, r)
    }
}

/// Chamberlin state-variable filter. `f` = 2·sin(π·fc/fs), `q` = damping (lower = more resonance).
private struct SVF {
    var low: Float = 0
    var band: Float = 0

    mutating func lowpass(_ x: Float, f: Float, q: Float) -> Float {
        step(x, f: f, q: q)
        return low
    }

    mutating func bandpass(_ x: Float, f: Float, q: Float) -> Float {
        step(x, f: f, q: q)
        return band
    }

    private mutating func step(_ x: Float, f: Float, q: Float) {
        low += f * band
        let high = x - low - q * band
        band += f * high
    }
}
