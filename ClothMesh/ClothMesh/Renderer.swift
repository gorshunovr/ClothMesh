import MetalKit
import QuartzCore
import simd

/// Must match `Uniforms` in Shaders.metal.
struct Uniforms {
    var vp: float4x4
    var model: float4x4
    var cameraPos: SIMD4<Float>
    var wireColor: SIMD4<Float>
    var wireColor2: SIMD4<Float>
    var fillColor: SIMD4<Float>
    var lightDir: SIMD4<Float>
    var wave: SIMD4<Float>
    var time: Float
    var depthOffset: Float
    var pointScale: Float
    var _pad: Float = 0
}

/// Must match `ScreenUniforms` in Shaders.metal.
struct ScreenUniforms {
    var backgroundTop: SIMD4<Float>
    var backgroundBottom: SIMD4<Float>
    var glowColor: SIMD4<Float>
    var fade: Float
    var flash: Float
    var vignette: Float
    var scanlines: Float
    var pixelScale: Float
    var time: Float
    var _pad0: Float = 0
    var _pad1: Float = 0
}

struct Vertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var uv: SIMD2<Float>
}

/// Must match `PointVertex` in Shaders.metal.
struct PointVertex {
    var positionSize: SIMD4<Float>
    var color: SIMD4<Float>
}

/// Everything about how a frame looks. The interactive app uses `standard`; the demo animates it.
struct Look {
    var wireColor = SIMD4<Float>(0.82, 0.95, 0.88, 0.92)
    var wireColor2 = SIMD4<Float>(0.82, 0.95, 0.88, 0.92)
    /// x amount, y spatial frequency, z speed.
    var wave = SIMD4<Float>(0, 0, 0, 0)
    /// Alpha 0 hides the fill.
    var fillColor = SIMD4<Float>(0.15, 0.45, 0.42, 0.28)
    /// Alpha 0 hides the collider.
    var colliderColor = SIMD4<Float>(0.55, 0.62, 0.70, 0)
    var additiveWires = false
    /// Alpha 0 hides the floor grid.
    var floorColor = SIMD4<Float>(0, 0, 0, 0)
    var floorY: Float = 0
    var showGrabDots = true
    var showHeldVertices = true
    var grabColor = SIMD4<Float>(1.0, 0.72, 0.30, 1.0)
    /// Nil keeps the plain clear color.
    var background: (top: SIMD4<Float>, bottom: SIMD4<Float>, glow: SIMD4<Float>)?
    var fade: Float = 0
    var flash: Float = 0
    var vignette: Float = 0
    var scanlines: Float = 0

    static func standard(showFill: Bool, showCollider: Bool) -> Look {
        var look = Look()
        if !showFill { look.fillColor.w = 0 }
        if showCollider { look.colliderColor.w = 0.15 }
        return look
    }
}

final class Renderer: NSObject, MTKViewDelegate {
    private static let maxFramesInFlight = 3
    private static let maxSubsteps = 4
    private static let lightDir = SIMD4<Float>(0.4, 1.0, 0.6, 0)

    let model: AppModel
    var camera = OrbitCamera()
    private let grab = GrabController()
    private(set) var sim: ClothSim
    private(set) var demo: DemoDirector?

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let fillPipeline: MTLRenderPipelineState
    private let wirePipeline: MTLRenderPipelineState
    private let wireAdditivePipeline: MTLRenderPipelineState
    private let floorPipeline: MTLRenderPipelineState
    private let pointPipeline: MTLRenderPipelineState
    private let backgroundPipeline: MTLRenderPipelineState
    private let postPipeline: MTLRenderPipelineState
    private let depthWrite: MTLDepthStencilState
    private let depthTestOnly: MTLDepthStencilState
    private let depthOff: MTLDepthStencilState

    private var vertexBuffers: [MTLBuffer] = []
    private var triangleBuffer: MTLBuffer!
    private var lineBuffer: MTLBuffer!
    private var normals: [SIMD3<Float>] = []
    private let sphereVertices: MTLBuffer
    private let sphereIndices: MTLBuffer
    private let sphereIndexCount: Int
    private let floorVertices: MTLBuffer
    private let floorVertexCount: Int

    private let inFlight = DispatchSemaphore(value: Renderer.maxFramesInFlight)
    private var frameIndex = 0
    private let startTime = CACurrentMediaTime()
    private var lastTime = CACurrentMediaTime()
    private var accumulator: Double = 0
    private var fpsFrames = 0
    private var fpsWindowStart = CACurrentMediaTime()

    /// `library` defaults to the app's compiled Shaders.metal.
    init?(view: MTKView, model: AppModel, library: MTLLibrary? = nil) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = library ?? device.makeDefaultLibrary() else { return nil }
        self.device = device
        self.queue = queue
        self.model = model

        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = device.supportsTextureSampleCount(4) ? 4 : 1
        view.clearColor = MTLClearColor(red: 0x0B / 255.0, green: 0x0D / 255.0, blue: 0x10 / 255.0, alpha: 1)
        view.preferredFramesPerSecond = 120

        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3
        vd.attributes[0].offset = MemoryLayout<Vertex>.offset(of: \.position)!
        vd.attributes[1].format = .float3
        vd.attributes[1].offset = MemoryLayout<Vertex>.offset(of: \.normal)!
        vd.attributes[2].format = .float2
        vd.attributes[2].offset = MemoryLayout<Vertex>.offset(of: \.uv)!
        vd.layouts[0].stride = MemoryLayout<Vertex>.stride

        enum Blend { case alpha, additive, premultiplied }
        func pipeline(_ vertexFn: String, _ fragmentFn: String, vertexDescriptor: MTLVertexDescriptor?,
                      blend: Blend = .alpha) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertexFn)
            d.fragmentFunction = library.makeFunction(name: fragmentFn)
            d.vertexDescriptor = vertexDescriptor
            d.rasterSampleCount = view.sampleCount
            d.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            let c = d.colorAttachments[0]!
            c.pixelFormat = view.colorPixelFormat
            c.isBlendingEnabled = true
            switch blend {
            case .alpha:
                c.sourceRGBBlendFactor = .sourceAlpha
                c.destinationRGBBlendFactor = .oneMinusSourceAlpha
            case .additive:
                c.sourceRGBBlendFactor = .sourceAlpha
                c.destinationRGBBlendFactor = .one
            case .premultiplied:
                c.sourceRGBBlendFactor = .one
                c.destinationRGBBlendFactor = .oneMinusSourceAlpha
            }
            c.sourceAlphaBlendFactor = .one
            c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let fill = pipeline("vertex_main", "fragment_fill", vertexDescriptor: vd),
              let wire = pipeline("vertex_wire", "fragment_wire", vertexDescriptor: vd),
              let wireAdd = pipeline("vertex_wire", "fragment_wire", vertexDescriptor: vd, blend: .additive),
              let floor = pipeline("vertex_main", "fragment_floor", vertexDescriptor: vd, blend: .additive),
              let point = pipeline("vertex_point", "fragment_point", vertexDescriptor: nil),
              let background = pipeline("vertex_screen", "fragment_background", vertexDescriptor: nil),
              let post = pipeline("vertex_screen", "fragment_post", vertexDescriptor: nil, blend: .premultiplied)
        else { return nil }
        fillPipeline = fill
        wirePipeline = wire
        wireAdditivePipeline = wireAdd
        floorPipeline = floor
        pointPipeline = point
        backgroundPipeline = background
        postPipeline = post

        func depthState(compare: MTLCompareFunction, write: Bool) -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = compare
            d.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: d)!
        }
        depthWrite = depthState(compare: .lessEqual, write: true)
        depthTestOnly = depthState(compare: .lessEqual, write: false)
        depthOff = depthState(compare: .always, write: false)

        let sphere = Self.makeSphere(center: ClothSim.sphereCenter, radius: ClothSim.sphereRadius, slices: 20, stacks: 12)
        sphereVertices = device.makeBuffer(bytes: sphere.vertices, length: sphere.vertices.count * MemoryLayout<Vertex>.stride)!
        sphereIndices = device.makeBuffer(bytes: sphere.indices, length: sphere.indices.count * MemoryLayout<UInt32>.stride)!
        sphereIndexCount = sphere.indices.count

        let floorLines = Self.makeFloorGrid(halfSize: 6, spacing: 0.25)
        floorVertices = device.makeBuffer(bytes: floorLines, length: floorLines.count * MemoryLayout<Vertex>.stride)!
        floorVertexCount = floorLines.count

        sim = ClothSim.draped(resolution: model.resolution, params: model.simParams)
        super.init()
        makeMeshBuffers()
    }

    // MARK: - Sim lifecycle

    /// Rebuilds the rest sheet at the current resolution and re-drapes it.
    func reset() {
        replaceSim(ClothSim.draped(resolution: model.resolution, params: model.simParams))
    }

    /// Swaps in a (typically pre-draped) sim.
    func replaceSim(_ newSim: ClothSim) {
        grab.cancel()
        sim = newSim
        accumulator = 0
        makeMeshBuffers()
    }

    private func makeMeshBuffers() {
        let mesh = sim.mesh
        let n = mesh.vertexCount
        var initial = [Vertex](repeating: Vertex(position: .zero, normal: SIMD3<Float>(0, 1, 0), uv: .zero), count: n)
        for i in 0..<n {
            initial[i].position = sim.positions[i]
            initial[i].uv = mesh.uvs[i]
        }
        let length = n * MemoryLayout<Vertex>.stride
        vertexBuffers = (0..<Self.maxFramesInFlight).map { _ in
            device.makeBuffer(bytes: initial, length: length, options: .storageModeShared)!
        }
        triangleBuffer = device.makeBuffer(bytes: mesh.triangles, length: mesh.triangles.count * MemoryLayout<UInt32>.stride)!
        lineBuffer = device.makeBuffer(bytes: mesh.lines, length: mesh.lines.count * MemoryLayout<UInt32>.stride)!
        normals = Array(repeating: .zero, count: n)
        // May run inside a SwiftUI view update (makeNSView), so publish on the next runloop turn.
        let model = model
        DispatchQueue.main.async { model.vertexCount = n }
    }

    private var clothIsLost: Bool {
        if sim.hasInvalidState { return true }
        for i in 0..<sim.count where sim.positions[i].y > -4 { return false }
        return true
    }

    // MARK: - Demo

    var isDemoRunning: Bool { demo != nil }

    func startDemo(music: Bool = true) {
        guard demo == nil else { return }
        if grab.isGrabbing { grab.end(sim: sim) }
        demo = DemoDirector(renderer: self, music: music)
        model.demoRunning = true
        model.paused = false
    }

    func stopDemo() {
        guard demo != nil else { return }
        demo = nil
        model.demoRunning = false
        model.caption = nil
        camera = OrbitCamera()
        reset()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        inFlight.wait()

        let now = CACurrentMediaTime()
        let frameDt = min(now - lastTime, 0.1)
        lastTime = now
        simulate(frameDt: frameDt)
        updateFPS(now: now)
        if let demo {
            if demo.isFinished { stopDemo() } else { NSCursor.setHiddenUntilMouseMoves(true) }
        }

        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = queue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        let semaphore = inFlight
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }
        encodeFrame(pass: pass, commandBuffer: commandBuffer, viewSize: view.bounds.size,
                    drawableSize: view.drawableSize, time: Float(now - startTime))
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Uploads the current sim state and encodes one frame into `pass`.
    func encodeFrame(pass: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer,
                     viewSize: CGSize, drawableSize: CGSize, time: Float) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let look: Look
        if let demo {
            demo.updateFrame()
            look = demo.look
        } else {
            look = .standard(showFill: model.showFill, showCollider: model.showCollider)
        }
        let vertexBuffer = vertexBuffers[frameIndex]
        uploadVertices(to: vertexBuffer)
        encode(encoder, look: look, viewSize: viewSize, drawableSize: drawableSize,
               vertexBuffer: vertexBuffer, time: demo?.time ?? time)
        encoder.endEncoding()
        frameIndex = (frameIndex + 1) % Self.maxFramesInFlight
    }

    private func simulate(frameDt: Double) {
        sim.params = model.simParams
        guard !model.paused || demo != nil else {
            accumulator = 0
            return
        }
        let dt = Double(ClothSim.fixedDt)
        accumulator += frameDt
        var steps = Int(accumulator / dt)
        if steps > Self.maxSubsteps {
            steps = Self.maxSubsteps
            accumulator = 0
        } else {
            accumulator -= Double(steps) * dt
        }
        if let demo, let target = demo.clockTime {
            // The music is the master clock: simulate until the demo catches up with what's audible.
            // Small epsilon so float rounding doesn't drop a step (e.g. exactly 2 per 60 Hz frame).
            let behind = Int((target - demo.time) / ClothSim.fixedDt + 1e-3)
            steps = max(0, behind)
            if steps > Self.maxSubsteps {
                // Too far behind (e.g. a stall): jump the script forward, keep the physics budget.
                demo.skip(steps: steps - Self.maxSubsteps, dt: ClothSim.fixedDt)
                steps = Self.maxSubsteps
            }
            accumulator = 0
        }
        for _ in 0..<steps {
            demo?.advance(dt: ClothSim.fixedDt)
            sim.step(dt: ClothSim.fixedDt)
        }

        // A sheet pulled off the ball falls forever; bring it back instead of showing an empty scene.
        if demo == nil && !grab.isGrabbing && clothIsLost { reset() }
    }

    /// Simulates without rendering (used by tests and offline rendering).
    func stepForTesting(frames: Int, frameDt: Double = 1.0 / 60.0) {
        for _ in 0..<frames {
            simulate(frameDt: frameDt)
            if let demo, demo.isFinished { stopDemo() }
        }
    }

    private func updateFPS(now: CFTimeInterval) {
        fpsFrames += 1
        let elapsed = now - fpsWindowStart
        if elapsed >= 0.5 {
            model.fps = Int((Double(fpsFrames) / elapsed).rounded())
            fpsFrames = 0
            fpsWindowStart = now
        }
    }

    private func uploadVertices(to buffer: MTLBuffer) {
        let n = sim.count
        normals.withUnsafeMutableBufferPointer { nb in
            sim.mesh.computeNormals(positions: sim.positions, into: nb.baseAddress!)
            let verts = buffer.contents().bindMemory(to: Vertex.self, capacity: n)
            for i in 0..<n {
                verts[i].position = sim.positions[i]
                verts[i].normal = nb[i]
            }
        }
    }

    private func encode(_ enc: MTLRenderCommandEncoder, look: Look, viewSize: CGSize, drawableSize: CGSize,
                        vertexBuffer: MTLBuffer, time: Float) {
        let pixelScale = Float(drawableSize.width / max(viewSize.width, 1))
        var u = Uniforms(vp: camera.viewProjection(viewSize: viewSize),
                         model: matrix_identity_float4x4,
                         cameraPos: SIMD4<Float>(camera.eye, 1),
                         wireColor: look.wireColor,
                         wireColor2: look.wireColor2,
                         fillColor: look.fillColor,
                         lightDir: Self.lightDir,
                         wave: look.wave,
                         time: time,
                         depthOffset: 2e-5,
                         pointScale: pixelScale)
        let uSize = MemoryLayout<Uniforms>.stride
        var screen = ScreenUniforms(backgroundTop: look.background?.top ?? .zero,
                                    backgroundBottom: look.background?.bottom ?? .zero,
                                    glowColor: look.background?.glow ?? .zero,
                                    fade: look.fade, flash: look.flash,
                                    vignette: look.vignette, scanlines: look.scanlines,
                                    pixelScale: pixelScale, time: time)
        let sSize = MemoryLayout<ScreenUniforms>.stride
        let mesh = sim.mesh

        enc.setFrontFacing(.counterClockwise)

        // 0. Background gradient.
        if look.background != nil {
            enc.setRenderPipelineState(backgroundPipeline)
            enc.setDepthStencilState(depthOff)
            enc.setFragmentBytes(&screen, length: sSize, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        // 1. Floor grid.
        if look.floorColor.w > 0.001 {
            var fu = u
            fu.model = float4x4(columns: (SIMD4<Float>(1, 0, 0, 0), SIMD4<Float>(0, 1, 0, 0),
                                          SIMD4<Float>(0, 0, 1, 0), SIMD4<Float>(0, look.floorY, 0, 1)))
            fu.wireColor = look.floorColor
            enc.setRenderPipelineState(floorPipeline)
            enc.setDepthStencilState(depthTestOnly)
            enc.setVertexBuffer(floorVertices, offset: 0, index: 0)
            enc.setVertexBytes(&fu, length: uSize, index: 1)
            enc.setFragmentBytes(&fu, length: uSize, index: 1)
            enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: floorVertexCount)
        }

        enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: uSize, index: 1)
        enc.setFragmentBytes(&u, length: uSize, index: 1)

        // 2. Translucent fill (writes depth so back wires are hidden behind the sheet).
        if look.fillColor.w > 0.001 {
            enc.setRenderPipelineState(fillPipeline)
            enc.setDepthStencilState(depthWrite)
            enc.setCullMode(.none)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.triangles.count,
                                      indexType: .uint32, indexBuffer: triangleBuffer, indexBufferOffset: 0)
        }

        // 3. Wires, nudged toward the camera.
        enc.setRenderPipelineState(look.additiveWires ? wireAdditivePipeline : wirePipeline)
        enc.setDepthStencilState(depthTestOnly)
        enc.drawIndexedPrimitives(type: .line, indexCount: mesh.lines.count,
                                  indexType: .uint32, indexBuffer: lineBuffer, indexBufferOffset: 0)

        // 4. Collider.
        if look.colliderColor.w > 0.001 {
            var cu = u
            cu.fillColor = look.colliderColor
            enc.setRenderPipelineState(fillPipeline)
            enc.setDepthStencilState(depthTestOnly)
            enc.setCullMode(.back)
            enc.setVertexBuffer(sphereVertices, offset: 0, index: 0)
            enc.setVertexBytes(&cu, length: uSize, index: 1)
            enc.setFragmentBytes(&cu, length: uSize, index: 1)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: sphereIndexCount,
                                      indexType: .uint32, indexBuffer: sphereIndices, indexBufferOffset: 0)
        }

        // 5. Grab gizmos: held vertices plus each grab point, always on top.
        if look.showGrabDots && !sim.grabs.isEmpty {
            var points: [PointVertex] = []
            for g in sim.grabs.values {
                for i in g.indices where look.showHeldVertices {
                    points.append(PointVertex(positionSize: SIMD4<Float>(sim.positions[i], 6),
                                              color: look.grabColor * SIMD4<Float>(1, 1, 1, 0.6)))
                }
                points.append(PointVertex(positionSize: SIMD4<Float>(g.target, 11), color: look.grabColor))
            }
            enc.setRenderPipelineState(pointPipeline)
            enc.setDepthStencilState(depthOff)
            enc.setVertexBytes(points, length: points.count * MemoryLayout<PointVertex>.stride, index: 0)
            enc.setVertexBytes(&u, length: uSize, index: 1)
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: points.count)
        }

        // 6. Post overlay: vignette, scanlines, fade to black, flash.
        if look.vignette > 0 || look.scanlines > 0 || look.fade > 0 || look.flash > 0 {
            enc.setRenderPipelineState(postPipeline)
            enc.setDepthStencilState(depthOff)
            enc.setFragmentBytes(&screen, length: sSize, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
    }

    // MARK: - Input (view points, origin bottom-left)

    func beginGrab(at point: CGPoint, viewSize: CGSize) -> Bool {
        guard demo == nil else { return true }  // swallow clicks during the demo
        return grab.begin(at: point, viewSize: viewSize, camera: camera, sim: sim)
    }

    func dragGrab(to point: CGPoint, viewSize: CGSize) {
        grab.drag(to: point, viewSize: viewSize, camera: camera, sim: sim)
    }

    func endGrab() {
        grab.end(sim: sim)
    }

    func orbit(dx: CGFloat, dy: CGFloat) {
        guard demo == nil else { return }
        camera.orbit(dx: Float(dx), dy: Float(dy))
    }

    func pan(dx: CGFloat, dy: CGFloat, viewHeight: CGFloat) {
        guard demo == nil else { return }
        camera.pan(dx: Float(dx), dy: Float(dy), viewHeight: Float(viewHeight))
    }

    func dolly(by factor: Float) {
        guard demo == nil else { return }
        camera.dolly(by: factor)
    }

    /// Returns true when the key was handled.
    func handleKey(_ key: String) -> Bool {
        if demo != nil {
            switch key {
            case "d", "\u{1b}": stopDemo()
            default: return false
            }
            return true
        }
        switch key {
        case "r": reset()
        case " ": model.paused.toggle()
        case "c": model.showCollider.toggle()
        case "w": model.showFill.toggle()
        case "d": startDemo()
        default: return false
        }
        return true
    }

    // MARK: - Static meshes

    private static func makeSphere(center: SIMD3<Float>, radius: Float, slices: Int, stacks: Int)
        -> (vertices: [Vertex], indices: [UInt32]) {
        var vertices: [Vertex] = []
        for i in 0...stacks {
            let theta = Float(i) / Float(stacks) * .pi
            for j in 0...slices {
                let phi = Float(j) / Float(slices) * 2 * .pi
                let n = SIMD3<Float>(sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi))
                vertices.append(Vertex(position: center + n * radius, normal: n,
                                       uv: SIMD2<Float>(Float(j) / Float(slices), Float(i) / Float(stacks))))
            }
        }
        var indices: [UInt32] = []
        let row = slices + 1
        for i in 0..<stacks {
            for j in 0..<slices {
                let a = UInt32(i * row + j), b = UInt32((i + 1) * row + j)
                let c = UInt32(i * row + j + 1), d = UInt32((i + 1) * row + j + 1)
                // CCW seen from outside.
                indices += [a, c, b, c, d, b]
            }
        }
        return (vertices, indices)
    }

    /// Line list of a square grid in the XZ plane at y = 0.
    private static func makeFloorGrid(halfSize: Float, spacing: Float) -> [Vertex] {
        var v: [Vertex] = []
        let n = Int(halfSize / spacing)
        let up = SIMD3<Float>(0, 1, 0)
        for k in -n...n {
            let c = Float(k) * spacing
            v.append(Vertex(position: SIMD3(c, 0, -halfSize), normal: up, uv: .zero))
            v.append(Vertex(position: SIMD3(c, 0, halfSize), normal: up, uv: .zero))
            v.append(Vertex(position: SIMD3(-halfSize, 0, c), normal: up, uv: .zero))
            v.append(Vertex(position: SIMD3(halfSize, 0, c), normal: up, uv: .zero))
        }
        return v
    }
}
