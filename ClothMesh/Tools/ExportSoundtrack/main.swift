// Renders the demo soundtrack to WAV and MIDI.
//
//   swiftc -O -o /tmp/export-soundtrack ClothMesh/Soundtrack.swift Tools/ExportSoundtrack/main.swift
//   /tmp/export-soundtrack Soundtrack/
import Foundation

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".", isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// MARK: WAV (48 kHz, 16-bit stereo)

let sampleRate = 48_000.0
let frames = Int(Soundtrack.duration * sampleRate)
let synth = Soundtrack(sampleRate: sampleRate)
var left = [Float](repeating: 0, count: frames), right = left
left.withUnsafeMutableBufferPointer { l in
    right.withUnsafeMutableBufferPointer { r in
        synth.render(left: l.baseAddress!, right: r.baseAddress!, frames: frames)
    }
}

var peak: Float = 0, sumSq: Double = 0, nans = 0
for i in 0..<frames {
    for x in [left[i], right[i]] {
        if !x.isFinite { nans += 1; continue }
        peak = max(peak, abs(x))
        sumSq += Double(x * x)
    }
}
let rms = sqrt(sumSq / Double(frames * 2))
print(String(format: "peak %.3f (%.1f dBFS), RMS %.1f dBFS, non-finite %d", peak, 20 * log10(peak), 20 * log10(rms), nans))
// Loudness per 8 s phrase, to check the arrangement's dynamics.
var phraseLine = "RMS per phrase (dBFS):"
for p in 0..<Int(ceil(Soundtrack.duration / 8)) {
    let a = Int(Double(p) * 8 * sampleRate), b = min(frames, Int(Double(p + 1) * 8 * sampleRate))
    var s = 0.0
    for i in a..<b { s += Double(left[i] * left[i] + right[i] * right[i]) }
    phraseLine += String(format: " %d:%.1f", p * 8, 10 * log10(s / Double(2 * (b - a))))
}
print(phraseLine)

var wav = Data()
func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
let dataBytes = UInt32(frames * 4)
wav.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
wav.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(2)
u32(UInt32(sampleRate)); u32(UInt32(sampleRate) * 4); u16(4); u16(16)
wav.append(contentsOf: Array("data".utf8)); u32(dataBytes)
wav.reserveCapacity(wav.count + Int(dataBytes))
for i in 0..<frames {
    for x in [left[i], right[i]] {
        u16(UInt16(bitPattern: Int16(max(-1, min(1, x)) * 32767)))
    }
}
try wav.write(to: outDir.appendingPathComponent("ClothMesh-soundtrack.wav"))

// MARK: MIDI (type 1, one track per instrument group, 480 ticks per quarter)

let ppq = 480.0
func ticks(_ seconds: Double) -> Int { Int((seconds / Soundtrack.beat * ppq).rounded()) }
func varLen(_ value: Int) -> [UInt8] {
    var v = value, bytes = [UInt8(v & 0x7F)]
    v >>= 7
    while v > 0 { bytes.insert(UInt8(v & 0x7F) | 0x80, at: 0); v >>= 7 }
    return bytes
}
func track(name: String, program: Int?, channel: Int, events: [NoteEvent]) -> [UInt8] {
    var raw: [(tick: Int, order: Int, bytes: [UInt8])] = []
    raw.append((0, 0, [0xFF, 0x03, UInt8(name.utf8.count)] + Array(name.utf8)))
    if let program { raw.append((0, 1, [0xC0 | UInt8(channel), UInt8(program)])) }
    for e in events {
        let vel = UInt8(max(1, min(127, Int(e.velocity * 127))))
        raw.append((ticks(e.start), 3, [0x90 | UInt8(channel), UInt8(e.note), vel]))
        raw.append((ticks(e.start + e.length), 2, [0x80 | UInt8(channel), UInt8(e.note), 0]))
    }
    raw.sort { ($0.tick, $0.order) < ($1.tick, $1.order) }
    var body: [UInt8] = [], last = 0
    for r in raw { body += varLen(r.tick - last) + r.bytes; last = r.tick }
    body += [0x00, 0xFF, 0x2F, 0x00]
    return Array("MTrk".utf8) + withUnsafeBytes(of: UInt32(body.count).bigEndian, Array.init) + body
}
let ev = Soundtrack.events
func only(_ kinds: Set<NoteEvent.Instrument>) -> [NoteEvent] { ev.filter { kinds.contains($0.instrument) } }
let tempo = UInt32(Soundtrack.beat * 1_000_000)
var conductor: [UInt8] = [0x00, 0xFF, 0x51, 0x03, UInt8(tempo >> 16 & 0xFF), UInt8(tempo >> 8 & 0xFF), UInt8(tempo & 0xFF),
                          0x00, 0xFF, 0x58, 0x04, 4, 2, 24, 8, 0x00, 0xFF, 0x2F, 0x00]
conductor = Array("MTrk".utf8) + withUnsafeBytes(of: UInt32(conductor.count).bigEndian, Array.init) + conductor
let tracks = [
    conductor,
    track(name: "Drums", program: nil, channel: 9, events: only([.kick, .snare, .closedHat, .openHat, .crash])),
    track(name: "Bass", program: 38, channel: 0, events: only([.bass])),      // Synth Bass 1
    track(name: "Arp", program: 80, channel: 1, events: only([.arp])),        // Square Lead
    track(name: "Pad", program: 90, channel: 2, events: only([.pad])),        // Polysynth Pad
    track(name: "Lead", program: 81, channel: 3, events: only([.lead])),      // Saw Lead
]
var midi: [UInt8] = Array("MThd".utf8) + [0, 0, 0, 6, 0, 1, 0, UInt8(tracks.count), UInt8(Int(ppq) >> 8), UInt8(Int(ppq) & 0xFF)]
for t in tracks { midi += t }
try Data(midi).write(to: outDir.appendingPathComponent("ClothMesh-soundtrack.mid"))
print("wrote \(outDir.path)/ClothMesh-soundtrack.wav and .mid (\(ev.count) notes)")
