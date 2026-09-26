import simd

/// CPU XPBD cloth: particles, distance constraints, analytic sphere collider, grab constraint.
///
/// Particle state lives in manually allocated buffers so the inner loops run without
/// array uniqueness / bounds checks. The sim size is fixed; changing resolution means
/// building a new `ClothSim`.
final class ClothSim {
    struct Params {
        var gravityScale: Float = 1
        /// Velocity damping per 1/60 s.
        var damping: Float = 0.04
        var iterations: Int = 8
        var structuralCompliance: Float = 1.0e-8
        var shearCompliance: Float = 2.0e-7
        var bendCompliance: Float = 5.0e-6
        var bendEnabled = true
        var selfCollision = true
        /// Extra acceleration (m/s²), e.g. wind.
        var wind: SIMD3<Float> = .zero
        /// Optional ground plane at this height.
        var floorY: Float? = nil
    }

    struct Grab {
        var indices: [Int]
        /// Vertex offset from the grab point at the moment of grabbing (keeps the grabbed patch's shape).
        var offsets: [SIMD3<Float>]
        var weights: [Float]
        var target: SIMD3<Float>
        var lambdas: [Float]
    }

    static let fixedDt: Float = 1.0 / 120.0
    static let gravity = SIMD3<Float>(0, -9.8, 0)
    static let sphereCenter = SIMD3<Float>(0, 0.15, 0)
    static let sphereRadius: Float = 0.55
    static let thickness: Float = 0.012
    /// Fraction of tangential velocity removed per substep for vertices touching the sphere.
    static let velocityFriction: Float = 0.25
    /// Coulomb position friction. Well above the spec's 0.25: a 1.6 m sheet only covers the cap
    /// of a 0.55 m ball, so with low static friction any off-center landing creeps off the ball.
    static let staticFriction: Float = 1.5
    static let kineticFriction: Float = 1.0
    static let maxDisplacement: Float = 0.05
    static let grabCompliance: Float = 1.0e-9
    static let grabMassScale: Float = 0.15
    /// Self-collision distance as a fraction of the rest grid spacing. Must stay above
    /// 1/√2 so a particle can't slip through the middle of a quad.
    static let selfThicknessScale: Float = 0.9
    static let selfFriction: Float = 0.2
    static let selfCollisionPasses = 2

    var params: Params
    let mesh: ClothMesh
    let count: Int

    let positions: UnsafeMutablePointer<SIMD3<Float>>
    private let previous: UnsafeMutablePointer<SIMD3<Float>>
    private let velocities: UnsafeMutablePointer<SIMD3<Float>>
    private let invMass: UnsafeMutablePointer<Float>
    /// Contact normal from the last step, zero when the vertex touched nothing.
    private let contactNormal: UnsafeMutablePointer<SIMD3<Float>>
    private let constraints: [UnsafeMutableBufferPointer<DistanceConstraint>]
    private let lambdas: [UnsafeMutableBufferPointer<Float>]

    /// Minimum distance between non-adjacent particles.
    let selfThickness: Float
    private let hashSize: Int
    /// Spatial hash (counting sort): cell `c` holds `hashEntries[hashStart[c]..<hashStart[c + 1]]`.
    private let hashStart: UnsafeMutablePointer<Int32>
    private let hashEntries: UnsafeMutablePointer<Int32>

    /// Active grabs by handle. Several can be active at once (pointer + scripted demo hands).
    private(set) var grabs: [Int: Grab] = [:]
    private var nextGrabID = 0
    private let grabbed: UnsafeMutablePointer<Bool>

    init(mesh: ClothMesh, params: Params) {
        self.mesh = mesh
        self.params = params
        count = mesh.vertexCount

        positions = .allocate(capacity: count)
        positions.initialize(repeating: .zero, count: count)
        previous = .allocate(capacity: count)
        previous.initialize(repeating: .zero, count: count)
        velocities = .allocate(capacity: count)
        invMass = .allocate(capacity: count)
        contactNormal = .allocate(capacity: count)
        grabbed = .allocate(capacity: count)
        velocities.initialize(repeating: .zero, count: count)
        invMass.initialize(repeating: 1, count: count)
        contactNormal.initialize(repeating: .zero, count: count)
        grabbed.initialize(repeating: false, count: count)

        selfThickness = Self.selfThicknessScale * ClothMesh.size / Float(mesh.nx - 1)
        hashSize = 2 * count
        hashStart = .allocate(capacity: hashSize + 1)
        hashStart.initialize(repeating: 0, count: hashSize + 1)
        hashEntries = .allocate(capacity: count)
        hashEntries.initialize(repeating: 0, count: count)

        constraints = mesh.constraints.map { group in
            let buf = UnsafeMutableBufferPointer<DistanceConstraint>.allocate(capacity: group.count)
            _ = buf.initialize(from: group)
            return buf
        }
        lambdas = mesh.constraints.map { group in
            let buf = UnsafeMutableBufferPointer<Float>.allocate(capacity: group.count)
            buf.initialize(repeating: 0)
            return buf
        }
        for (i, p) in mesh.restPositions.enumerated() {
            positions[i] = p
            previous[i] = p
        }
    }

    deinit {
        positions.deallocate()
        previous.deallocate()
        velocities.deallocate()
        invMass.deallocate()
        contactNormal.deallocate()
        grabbed.deallocate()
        hashStart.deallocate()
        hashEntries.deallocate()
        constraints.forEach { $0.deallocate() }
        lambdas.forEach { $0.deallocate() }
    }

    // MARK: - Grab

    /// Starts a grab and returns its handle. Vertices already held by another grab are skipped.
    @discardableResult
    func beginGrab(indices: [Int], weights: [Float], at point: SIMD3<Float>) -> Int {
        var idx: [Int] = [], w: [Float] = []
        for (i, weight) in zip(indices, weights) where !grabbed[i] {
            idx.append(i)
            w.append(weight)
        }
        let id = nextGrabID
        nextGrabID += 1
        grabs[id] = Grab(indices: idx, offsets: idx.map { positions[$0] - point }, weights: w,
                         target: point, lambdas: Array(repeating: 0, count: idx.count))
        // Heavier grabbed vertices: the sheet lifts around them instead of the springs tearing them back.
        for i in idx {
            invMass[i] = Self.grabMassScale
            grabbed[i] = true
        }
        return id
    }

    /// Grabs a (2r+1)² patch around grid vertex (x, z), weighted toward the center.
    @discardableResult
    func beginGrab(gridX x: Int, z: Int, radius r: Int = 1) -> Int {
        var idx: [Int] = [], w: [Float] = []
        for dz in -r...r {
            for dx in -r...r {
                let gx = x + dx, gz = z + dz
                guard gx >= 0, gx < mesh.nx, gz >= 0, gz < mesh.ny else { continue }
                idx.append(mesh.index(gx, gz))
                w.append(1 / Float(1 + abs(dx) + abs(dz)))
            }
        }
        return beginGrab(indices: idx, weights: w, at: positions[mesh.index(x, z)])
    }

    func moveGrab(_ id: Int, to target: SIMD3<Float>) {
        grabs[id]?.target = target
    }

    /// Releases a grab; velocities are kept so the cloth can be flung.
    func endGrab(_ id: Int) {
        guard let g = grabs.removeValue(forKey: id) else { return }
        for i in g.indices {
            invMass[i] = 1
            grabbed[i] = false
        }
    }

    func endAllGrabs() {
        for id in Array(grabs.keys) { endGrab(id) }
    }

    /// Adds a velocity kick to every free vertex.
    func addVelocity(_ f: (SIMD3<Float>) -> SIMD3<Float>) {
        for i in 0..<count where !grabbed[i] {
            velocities[i] += f(positions[i])
        }
    }

    // MARK: - Step

    func step(dt: Float) {
        let n = count
        let g = Self.gravity * params.gravityScale + params.wind
        let damp = pow(max(0, 1 - params.damping), dt * 60)

        // Predict. With self-collision on, travel per substep is capped at the collision
        // thickness so layers can't jump through each other between two checks.
        let maxTravel = params.selfCollision ? selfThickness : .infinity
        for i in 0..<n {
            previous[i] = positions[i]
            if invMass[i] > 0 {
                var v = (velocities[i] + g * dt) * damp
                let travel = length(v) * dt
                if travel > maxTravel { v *= maxTravel / travel }
                velocities[i] = v
                positions[i] += v * dt
            }
        }

        // Constraints.
        let compliances: [Float] = [params.structuralCompliance, params.shearCompliance, params.bendCompliance]
        let groupCount = params.bendEnabled ? 3 : 2
        for k in 0..<groupCount { lambdas[k].update(repeating: 0) }
        for id in grabs.keys {
            for k in grabs[id]!.lambdas.indices { grabs[id]!.lambdas[k] = 0 }
        }

        let invDt2 = 1 / (dt * dt)
        for _ in 0..<max(1, params.iterations) {
            for k in 0..<groupCount {
                solveDistance(constraints[k], lambdas: lambdas[k], alpha: compliances[k] * invDt2)
            }
            solveGrab(invDt2: invDt2)
        }
        if params.selfCollision {
            for _ in 0..<Self.selfCollisionPasses { solveSelfCollisions() }
        }

        // Sphere (and optional floor) collision with Coulomb position friction (static / kinetic).
        let c = Self.sphereCenter
        let minDist = Self.sphereRadius + Self.thickness
        let floorY = params.floorY.map { $0 + Self.thickness }
        for i in 0..<n {
            contactNormal[i] = .zero
            guard invMass[i] > 0 else { continue }
            let d = positions[i] - c
            let len = length(d)
            if len < minDist {
                let normal = len > 1e-8 ? d / len : SIMD3<Float>(0, 1, 0)
                resolveContact(i, surface: c + normal * minDist, normal: normal, depth: minDist - len)
            }
            if let fy = floorY, positions[i].y < fy {
                var surface = positions[i]
                surface.y = fy
                resolveContact(i, surface: surface, normal: SIMD3<Float>(0, 1, 0), depth: fy - positions[i].y)
            }
        }

        // Clamp runaway displacement (explosion guard), except for vertices held by the pointer.
        let maxD = Self.maxDisplacement
        for i in 0..<n where !grabbed[i] {
            let disp = positions[i] - previous[i]
            let len = length(disp)
            if len > maxD {
                positions[i] = previous[i] + disp * (maxD / len)
            }
        }

        // Velocity update; for contacts kill inward normal velocity and damp tangential velocity.
        let invDt = 1 / dt
        for i in 0..<n {
            var v = (positions[i] - previous[i]) * invDt
            let normal = contactNormal[i]
            if normal != .zero {
                let vn = dot(v, normal)
                if vn < 0 { v -= vn * normal }
                let vt = v - dot(v, normal) * normal
                v -= vt * Self.velocityFriction
            }
            velocities[i] = v
        }
    }

    @inline(__always)
    private func resolveContact(_ i: Int, surface: SIMD3<Float>, normal: SIMD3<Float>, depth: Float) {
        var p = surface
        let dx = p - previous[i]
        let dxT = dx - dot(dx, normal) * normal
        let slip = length(dxT)
        if slip < Self.staticFriction * depth {
            p -= dxT
        } else if slip > 0 {
            p -= dxT * min(Self.kineticFriction * depth / slip, 1)
        }
        positions[i] = p
        contactNormal[i] = normal
    }

    @inline(__always)
    private func solveDistance(_ cs: UnsafeMutableBufferPointer<DistanceConstraint>,
                               lambdas: UnsafeMutableBufferPointer<Float>, alpha: Float) {
        let p = positions, w = invMass
        for j in 0..<cs.count {
            let con = cs[j]
            let a = Int(con.a), b = Int(con.b)
            let wSum = w[a] + w[b]
            if wSum <= 0 { continue }
            let delta = p[a] - p[b]
            let len = length(delta)
            if len < 1e-8 { continue }
            let cValue = len - con.rest
            let dLambda = (-cValue - alpha * lambdas[j]) / (wSum + alpha)
            lambdas[j] += dLambda
            let corr = delta * (dLambda / len)
            p[a] += corr * w[a]
            p[b] -= corr * w[b]
        }
    }

    // MARK: - Self-collision

    @inline(__always)
    private func hashCell(_ x: Int32, _ y: Int32, _ z: Int32) -> Int {
        let h = (x &* 92_837_111) ^ (y &* 689_287_499) ^ (z &* 283_923_481)
        return Int(h.magnitude) % hashSize
    }

    @inline(__always)
    private func cellCoords(_ p: SIMD3<Float>, _ invCell: Float) -> SIMD3<Int32> {
        SIMD3<Int32>((p * invCell).rounded(.down))
    }

    /// Particle-particle separation for particles that aren't direct grid neighbors.
    /// Pairs are pushed apart along their direction at the start of the substep, so a
    /// particle that has just crossed the other layer is pushed back to the side it came from.
    private func solveSelfCollisions() {
        let n = count, nx = mesh.nx
        let h = selfThickness, h2 = h * h, invCell = 1 / h

        hashStart.update(repeating: 0, count: hashSize + 1)
        for i in 0..<n {
            let c = cellCoords(positions[i], invCell)
            hashStart[hashCell(c.x, c.y, c.z)] += 1
        }
        for k in 0..<hashSize { hashStart[k + 1] += hashStart[k] }
        for i in 0..<n {
            let c = cellCoords(positions[i], invCell)
            let cell = hashCell(c.x, c.y, c.z)
            hashStart[cell] -= 1
            hashEntries[Int(hashStart[cell])] = Int32(i)
        }

        for i in 0..<n {
            let wi = invMass[i]
            let xi = i % nx, zi = i / nx
            let c = cellCoords(positions[i], invCell)
            for dz in Int32(-1)...1 {
                for dy in Int32(-1)...1 {
                    for dx in Int32(-1)...1 {
                        let cell = hashCell(c.x + dx, c.y + dy, c.z + dz)
                        for k in Int(hashStart[cell])..<Int(hashStart[cell + 1]) {
                            let j = Int(hashEntries[k])
                            if j <= i { continue }
                            if abs(j % nx - xi) <= 1 && abs(j / nx - zi) <= 1 { continue }
                            let delta = positions[i] - positions[j]
                            if length_squared(delta) >= h2 { continue }
                            let wj = invMass[j]
                            let wSum = wi + wj
                            if wSum <= 0 { continue }

                            var normal = previous[i] - previous[j]
                            let prevLen = length(normal)
                            if prevLen > 1e-6 {
                                normal /= prevLen
                            } else {
                                let len = length(delta)
                                if len < 1e-8 { continue }
                                normal = delta / len
                            }
                            let separation = dot(delta, normal)
                            if separation >= h { continue }
                            let push = normal * ((h - separation) / wSum)
                            positions[i] += push * wi
                            positions[j] -= push * wj

                            // Friction: damp relative sliding between touching layers.
                            let rel = (positions[i] - previous[i]) - (positions[j] - previous[j])
                            let relT = (rel - dot(rel, normal) * normal) * (Self.selfFriction / wSum)
                            positions[i] -= relT * wi
                            positions[j] += relT * wj
                        }
                    }
                }
            }
        }
    }

    private func solveGrab(invDt2: Float) {
        for id in grabs.keys {
            var g = grabs[id]!
            for k in g.indices.indices {
                let i = g.indices[k]
                let w = invMass[i]
                let delta = positions[i] - (g.target + g.offsets[k])
                let len = length(delta)
                if len < 1e-8 { continue }
                // Weighted compliance: the vertex closest to the hit follows most tightly.
                let alpha = Self.grabCompliance / max(g.weights[k], 0.05) * invDt2
                let dLambda = (-len - alpha * g.lambdas[k]) / (w + alpha)
                g.lambdas[k] += dLambda
                positions[i] += delta * (w * dLambda / len)
            }
            grabs[id] = g
        }
    }

    // MARK: - Diagnostics

    var hasInvalidState: Bool {
        for i in 0..<count where !all(positions[i] .== positions[i]) { return true }
        return false
    }
}
