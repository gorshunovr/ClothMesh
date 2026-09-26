// Renders the ClothMesh demo offline to a 16:9 MP4 (4K 60 fps) with the soundtrack, plus stills.
// Every frame is simulated at exactly t = frame / fps, so picture and music are sample-accurate.
//
// Build the app first (for its compiled shaders), export the soundtrack, then:
//
//   swiftc -O -o /tmp/render-demo-video $(ls ClothMesh/*.swift | grep -v ClothMeshApp.swift) Tools/RenderDemoVideo/main.swift
//   /tmp/render-demo-video --metallib build/DerivedData/Build/Products/Release/ClothMesh.app/Contents/Resources/default.metallib \
//       --audio Soundtrack/ClothMesh-soundtrack.wav --out ClothMesh-demo.mp4
//
// Options: --size 3840x2160 (pixels; the scene is laid out at half that in points, like a Retina
// window), --fps 60, --stills DIR (writes README screenshots and a YouTube thumbnail), --no-video.
// Requires ffmpeg on PATH for the video.
import AppKit
import ImageIO
import MetalKit
import UniformTypeIdentifiers

// MARK: - Arguments

var args = [String: String]()
var flags = Set<String>()
do {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        if a == "--no-video" { flags.insert(a) } else if a.hasPrefix("--") { args[a] = it.next() }
    }
}
guard let metallibPath = args["--metallib"] else {
    print("usage: render-demo-video --metallib PATH [--audio WAV] [--out MP4] [--size WxH] [--fps N] [--stills DIR] [--no-video]")
    exit(2)
}
let sizeParts = (args["--size"] ?? "3840x2160").split(separator: "x").compactMap { Int($0) }
let (width, height) = (sizeParts[0], sizeParts[1])
let fps = Int(args["--fps"] ?? "60")!
let pixelScale = 2
let viewSize = CGSize(width: width / pixelScale, height: height / pixelScale)
let drawableSize = CGSize(width: width, height: height)

// MARK: - Metal setup

let device = MTLCreateSystemDefaultDevice()!
let library = try device.makeLibrary(URL: URL(fileURLWithPath: metallibPath))
let view = MTKView(frame: CGRect(origin: .zero, size: viewSize), device: device)
let model = AppModel()
let renderer = Renderer(view: view, model: model, library: library)!
let queue = device.makeCommandQueue()!

func texture(_ format: MTLPixelFormat, multisample: Bool) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]
    if multisample {
        d.textureType = .type2DMultisample
        d.sampleCount = view.sampleCount
        d.storageMode = .private
    } else {
        d.storageMode = .shared
    }
    return device.makeTexture(descriptor: d)!
}
let msaaColor = texture(.bgra8Unorm, multisample: true)
let resolved = texture(.bgra8Unorm, multisample: false)
let depth = texture(.depth32Float, multisample: true)
var pixels = [UInt8](repeating: 0, count: width * height * 4)

/// Renders the current state into `pixels` (BGRA, top row first) and overlays the demo caption.
func renderFrame(time: Float) {
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = msaaColor
    pass.colorAttachments[0].resolveTexture = resolved
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .multisampleResolve
    pass.colorAttachments[0].clearColor = view.clearColor
    pass.depthAttachment.texture = depth
    pass.depthAttachment.loadAction = .clear
    pass.depthAttachment.clearDepth = 1
    let cb = queue.makeCommandBuffer()!
    renderer.encodeFrame(pass: pass, commandBuffer: cb, viewSize: viewSize, drawableSize: drawableSize, time: time)
    cb.commit()
    cb.waitUntilCompleted()
    resolved.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)

    guard renderer.isDemoRunning, let caption = DemoDirector.caption(at: time), caption.opacity > 0 else { return }
    // Same look as the app's CaptionView: small monospaced label, bottom-left.
    pixels.withUnsafeMutableBytes { raw in
        let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.scaleBy(x: CGFloat(pixelScale), y: CGFloat(pixelScale))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
            .kern: 2,
            .foregroundColor: NSColor.white.withAlphaComponent(0.75 * CGFloat(caption.opacity)),
        ]
        NSAttributedString(string: caption.text, attributes: attrs).draw(at: CGPoint(x: 24, y: 24))
        NSGraphicsContext.restoreGraphicsState()
    }
}

func image(scaledTo target: CGSize? = nil) -> CGImage {
    let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    let full = ctx.makeImage()!
    guard let target else { return full }
    let small = CGContext(data: nil, width: Int(target.width), height: Int(target.height), bitsPerComponent: 8,
                          bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    small.interpolationQuality = .high
    small.draw(full, in: CGRect(origin: .zero, size: target))
    return small.makeImage()!
}

func savePNG(_ img: CGImage, _ path: String) {
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(path)")
}

// MARK: - Stills (README screenshots + thumbnail)

if let stillsDir = args["--stills"] {
    try FileManager.default.createDirectory(atPath: stillsDir, withIntermediateDirectories: true)
    let shot = CGSize(width: 1600, height: 900)

    // 1. Interactive mode: the net grabbed near the crown and lifted.
    renderer.stepForTesting(frames: 30)
    let n = renderer.sim.mesh.nx
    let crown = renderer.sim.positions[renderer.sim.mesh.index(n / 2 + 3, n / 2 - 4)]
    let vp = renderer.camera.viewProjection(viewSize: viewSize)
    if let p = Math.project(crown, viewProjection: vp, viewSize: viewSize), renderer.beginGrab(at: p, viewSize: viewSize) {
        for k in 1...24 {
            renderer.dragGrab(to: CGPoint(x: p.x + CGFloat(k) * 1.5, y: p.y + CGFloat(k) * 3), viewSize: viewSize)
            renderer.stepForTesting(frames: 1)
        }
        renderFrame(time: 0)
        savePNG(image(scaledTo: shot), "\(stillsDir)/screenshot-1-grab.png")
        renderer.endGrab()
    }

    // 2–3 and the thumbnail from the demo.
    renderer.startDemo(music: false)
    let demoStills: [(Float, String, CGSize)] = [
        (27.3, "screenshot-2-zero-g.png", shot),
        (50.6, "screenshot-3-dense-net.png", shot),
        (18.6, "youtube-thumbnail.png", CGSize(width: 1280, height: 720)),
    ]
    var frame = 0
    for (t, name, size) in demoStills.sorted(by: { $0.0 < $1.0 }) {
        while Float(frame) / Float(fps) < t {
            frame += 1
            renderer.demo?.manualClock = Float(frame) / Float(fps)
            renderer.stepForTesting(frames: 1, frameDt: 1 / Double(fps))
        }
        renderFrame(time: renderer.demo?.time ?? 0)
        savePNG(image(scaledTo: size), "\(stillsDir)/\(name)")
    }
    renderer.stopDemo()
}

// MARK: - Video

if !flags.contains("--no-video") {
    let out = args["--out"] ?? "ClothMesh-demo.mp4"
    let audio = args["--audio"] ?? "Soundtrack/ClothMesh-soundtrack.wav"
    guard FileManager.default.fileExists(atPath: audio) else {
        print("missing \(audio); run Tools/ExportSoundtrack first")
        exit(1)
    }
    let ffmpeg = Process()
    ffmpeg.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    ffmpeg.arguments = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
                        "-f", "rawvideo", "-pix_fmt", "bgra", "-s", "\(width)x\(height)", "-r", "\(fps)", "-i", "-",
                        "-i", audio,
                        "-c:v", "libx264", "-preset", "slow", "-crf", "14", "-pix_fmt", "yuv420p",
                        "-profile:v", "high", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
                        "-c:a", "aac", "-b:a", "320k",
                        "-shortest", "-movflags", "+faststart", out]
    let pipe = Pipe()
    ffmpeg.standardInput = pipe
    try ffmpeg.run()

    renderer.startDemo(music: false)
    let totalFrames = Int(Double(DemoDirector.duration) * Double(fps))
    let start = Date()
    for frame in 0..<totalFrames {
        let t = Float(frame) / Float(fps)
        renderer.demo?.manualClock = t
        renderer.stepForTesting(frames: 1, frameDt: 1 / Double(fps))
        renderFrame(time: t)
        pipe.fileHandleForWriting.write(Data(pixels))
        if frame % (fps * 5) == 0 {
            print(String(format: "  %5.1f s / %.0f s  (%.0f s elapsed)", t, DemoDirector.duration, Date().timeIntervalSince(start)))
        }
    }
    try pipe.fileHandleForWriting.close()
    ffmpeg.waitUntilExit()
    print(ffmpeg.terminationStatus == 0 ? "wrote \(out)" : "ffmpeg failed (\(ffmpeg.terminationStatus))")
}
