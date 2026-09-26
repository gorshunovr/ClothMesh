import CoreGraphics
import simd

struct RayHit {
    var t: Float
    var point: SIMD3<Float>
    var indices: (Int, Int, Int)
    /// Barycentric weights for `indices`.
    var weights: SIMD3<Float>
}

enum Raycast {
    /// First hit of `ray` against the triangle list (Möller–Trumbore, two-sided).
    static func intersect(_ ray: Ray, positions: UnsafePointer<SIMD3<Float>>, triangles: [UInt32]) -> RayHit? {
        var best: RayHit?
        triangles.withUnsafeBufferPointer { tris in
            var i = 0
            while i < tris.count {
                let ia = Int(tris[i]), ib = Int(tris[i + 1]), ic = Int(tris[i + 2])
                i += 3
                let a = positions[ia], b = positions[ib], c = positions[ic]
                let e1 = b - a, e2 = c - a
                let pv = cross(ray.direction, e2)
                let det = dot(e1, pv)
                if abs(det) < 1e-10 { continue }
                let invDet = 1 / det
                let tv = ray.origin - a
                let u = dot(tv, pv) * invDet
                if u < 0 || u > 1 { continue }
                let qv = cross(tv, e1)
                let v = dot(ray.direction, qv) * invDet
                if v < 0 || u + v > 1 { continue }
                let t = dot(e2, qv) * invDet
                if t <= 0 || t >= (best?.t ?? .infinity) { continue }
                best = RayHit(t: t, point: ray.origin + ray.direction * t,
                              indices: (ia, ib, ic), weights: SIMD3<Float>(1 - u - v, u, v))
            }
        }
        return best
    }

    /// Fallback pick: the vertex nearest to the pointer in screen space, within `radius` points.
    /// Ties are broken toward the camera.
    static func nearestVertex(to point: CGPoint, positions: UnsafePointer<SIMD3<Float>>, count: Int,
                              viewProjection: float4x4, viewSize: CGSize, radius: CGFloat = 8) -> Int? {
        var best: Int?
        var bestScore = CGFloat.infinity
        let r2 = radius * radius
        for i in 0..<count {
            guard let s = Math.project(positions[i], viewProjection: viewProjection, viewSize: viewSize) else { continue }
            let dx = s.x - point.x, dy = s.y - point.y
            let d2 = dx * dx + dy * dy
            if d2 > r2 { continue }
            let clip = viewProjection * SIMD4<Float>(positions[i], 1)
            let score = d2 + CGFloat(clip.w) * 0.01
            if score < bestScore {
                bestScore = score
                best = i
            }
        }
        return best
    }
}
