import AVFoundation
import QuartzCore

/// Plays `Soundtrack` live and reports the playback position, which the demo uses as its clock.
final class SoundtrackPlayer {
    private let engine = AVAudioEngine()
    private let sampleRate: Double
    /// `CACurrentMediaTime()` + offset = seconds of soundtrack currently coming out of the speakers.
    /// Written by the audio thread once per buffer; a single aligned 64-bit value, so reads never tear.
    private let clockOffset = UnsafeMutablePointer<Double>.allocate(capacity: 1)

    init?() {
        let output = engine.outputNode
        let deviceRate = output.outputFormat(forBus: 0).sampleRate
        sampleRate = deviceRate > 0 ? deviceRate : 48_000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return nil }

        clockOffset.initialize(to: .nan)
        let synth = Soundtrack(sampleRate: sampleRate)
        let offset = clockOffset
        let rate = sampleRate
        let latency = output.presentationLatency

        let source = AVAudioSourceNode(format: format) { _, timestamp, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2,
                  let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let firstSample = synth.sampleIndex
            synth.render(left: l, right: r, frames: Int(frameCount))
            // The buffer's host time is when its first sample reaches the output.
            if timestamp.pointee.mFlags.contains(.hostTimeValid) {
                let hostSeconds = AVAudioTime.seconds(forHostTime: timestamp.pointee.mHostTime)
                offset.pointee = Double(firstSample) / rate - hostSeconds - latency
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
    }

    deinit {
        engine.stop()
        clockOffset.deallocate()
    }

    func start() -> Bool {
        do {
            try engine.start()
            return true
        } catch {
            return false
        }
    }

    func stop() {
        engine.stop()
    }

    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    /// Soundtrack seconds audible right now; nil until the first buffer has been rendered.
    var time: Double? {
        let offset = clockOffset.pointee
        return offset.isNaN ? nil : max(0, CACurrentMediaTime() + offset)
    }
}
