import simd

enum ConstraintKind: Int {
    case structural = 0, shear, bend
}

struct DistanceConstraint {
    var a: Int32
    var b: Int32
    var rest: Float
}

/// Static topology of the cloth grid: flat rest layout, triangles, wire edges and springs.
struct ClothMesh {
    static let size: Float = 1.6

    let nx: Int
    let ny: Int
    let restPositions: [SIMD3<Float>]
    let uvs: [SIMD2<Float>]
    /// Triangle list, CCW when viewed from +Y in the rest layout.
    let triangles: [UInt32]
    /// Unique edges of `triangles`, as line pairs.
    let lines: [UInt32]
    /// Springs, grouped by kind (index = ConstraintKind.rawValue).
    let constraints: [[DistanceConstraint]]

    var vertexCount: Int { nx * ny }

    func index(_ x: Int, _ z: Int) -> Int { z * nx + x }

    init(nx: Int, ny: Int, height: Float) {
        self.nx = nx
        self.ny = ny
        let half = Self.size * 0.5

        var positions: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        positions.reserveCapacity(nx * ny)
        for z in 0..<ny {
            for x in 0..<nx {
                let u = Float(x) / Float(nx - 1)
                let v = Float(z) / Float(ny - 1)
                positions.append(SIMD3<Float>(-half + u * Self.size, height, -half + v * Self.size))
                uvs.append(SIMD2<Float>(u, v))
            }
        }
        restPositions = positions
        self.uvs = uvs

        func idx(_ x: Int, _ z: Int) -> Int { z * nx + x }

        // Alternate the quad diagonal in a checkerboard so the sheet has no handedness bias.
        var tris: [UInt32] = []
        var lines: [UInt32] = []
        tris.reserveCapacity((nx - 1) * (ny - 1) * 6)
        for z in 0..<(ny - 1) {
            for x in 0..<(nx - 1) {
                let a = UInt32(idx(x, z)), b = UInt32(idx(x + 1, z))
                let c = UInt32(idx(x, z + 1)), d = UInt32(idx(x + 1, z + 1))
                if (x + z) % 2 == 0 {
                    tris += [a, c, d, a, d, b]
                    lines += [a, d]
                } else {
                    tris += [a, c, b, b, c, d]
                    lines += [b, c]
                }
            }
        }
        for z in 0..<ny {
            for x in 0..<nx {
                if x + 1 < nx { lines += [UInt32(idx(x, z)), UInt32(idx(x + 1, z))] }
                if z + 1 < ny { lines += [UInt32(idx(x, z)), UInt32(idx(x, z + 1))] }
            }
        }
        triangles = tris
        self.lines = lines

        func spring(_ i: Int, _ j: Int) -> DistanceConstraint {
            DistanceConstraint(a: Int32(i), b: Int32(j), rest: simd_distance(positions[i], positions[j]))
        }
        var structural: [DistanceConstraint] = []
        var shear: [DistanceConstraint] = []
        var bend: [DistanceConstraint] = []
        for z in 0..<ny {
            for x in 0..<nx {
                if x + 1 < nx { structural.append(spring(idx(x, z), idx(x + 1, z))) }
                if z + 1 < ny { structural.append(spring(idx(x, z), idx(x, z + 1))) }
                if x + 1 < nx && z + 1 < ny {
                    shear.append(spring(idx(x, z), idx(x + 1, z + 1)))
                    shear.append(spring(idx(x + 1, z), idx(x, z + 1)))
                }
                if x + 2 < nx { bend.append(spring(idx(x, z), idx(x + 2, z))) }
                if z + 2 < ny { bend.append(spring(idx(x, z), idx(x, z + 2))) }
            }
        }
        constraints = [structural, shear, bend]
    }

    /// Area-weighted vertex normals (sum of unnormalized face normals).
    func computeNormals(positions: UnsafePointer<SIMD3<Float>>, into normals: UnsafeMutablePointer<SIMD3<Float>>) {
        let n = vertexCount
        normals.update(repeating: .zero, count: n)
        triangles.withUnsafeBufferPointer { t in
            var i = 0
            while i < t.count {
                let a = Int(t[i]), b = Int(t[i + 1]), c = Int(t[i + 2])
                let fn = cross(positions[b] - positions[a], positions[c] - positions[a])
                normals[a] += fn
                normals[b] += fn
                normals[c] += fn
                i += 3
            }
        }
        for i in 0..<n {
            let len = length(normals[i])
            normals[i] = len > 1e-12 ? normals[i] / len : SIMD3<Float>(0, 1, 0)
        }
    }
}

extension ClothSim {
    static let drapeSteps = 180

    /// Builds a flat sheet just above the sphere's pole and lets it settle so the first
    /// presented frame already shows a draped net.
    static func draped(resolution: Int, params: Params) -> ClothSim {
        let height = sphereCenter.y + sphereRadius + 0.02
        let mesh = ClothMesh(nx: resolution, ny: resolution, height: height)
        let sim = ClothSim(mesh: mesh, params: params)
        sim.drape()
        return sim
    }

    func drape() {
        for _ in 0..<Self.drapeSteps {
            step(dt: Self.fixedDt)
        }
    }
}
