import CoreGraphics
import simd

struct Ray {
    var origin: SIMD3<Float>
    var direction: SIMD3<Float>
}

extension float4x4 {
    /// Right-handed perspective projection with Metal's [0, 1] clip-space depth.
    static func perspective(fovyRadians fovy: Float, aspect: Float, near: Float, far: Float) -> float4x4 {
        let ys = 1 / tan(fovy * 0.5)
        let xs = ys / aspect
        let zs = far / (near - far)
        return float4x4(columns: (
            SIMD4<Float>(xs, 0, 0, 0),
            SIMD4<Float>(0, ys, 0, 0),
            SIMD4<Float>(0, 0, zs, -1),
            SIMD4<Float>(0, 0, zs * near, 0)
        ))
    }

    /// Right-handed view matrix (camera looks down -Z).
    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> float4x4 {
        let f = normalize(target - eye)
        let s = normalize(cross(f, up))
        let u = cross(s, f)
        return float4x4(columns: (
            SIMD4<Float>(s.x, u.x, -f.x, 0),
            SIMD4<Float>(s.y, u.y, -f.y, 0),
            SIMD4<Float>(s.z, u.z, -f.z, 0),
            SIMD4<Float>(-dot(s, eye), -dot(u, eye), dot(f, eye), 1)
        ))
    }
}

enum Math {
    /// Converts a point in view coordinates (points, origin bottom-left, y up) to NDC.
    static func ndc(_ point: CGPoint, viewSize: CGSize) -> SIMD2<Float> {
        SIMD2<Float>(Float(2 * point.x / viewSize.width - 1),
                     Float(2 * point.y / viewSize.height - 1))
    }

    /// Window coords → NDC → world-space ray, by unprojecting the near and far planes.
    static func screenRay(_ point: CGPoint, viewSize: CGSize, inverseViewProjection inv: float4x4) -> Ray {
        let p = ndc(point, viewSize: viewSize)
        let near = inv * SIMD4<Float>(p.x, p.y, 0, 1)
        let far = inv * SIMD4<Float>(p.x, p.y, 1, 1)
        let a = SIMD3<Float>(near.x, near.y, near.z) / near.w
        let b = SIMD3<Float>(far.x, far.y, far.z) / far.w
        return Ray(origin: a, direction: normalize(b - a))
    }

    /// Projects a world point to view coordinates (points, origin bottom-left). Nil if behind the camera.
    static func project(_ p: SIMD3<Float>, viewProjection: float4x4, viewSize: CGSize) -> CGPoint? {
        let c = viewProjection * SIMD4<Float>(p, 1)
        guard c.w > 1e-6 else { return nil }
        let x = c.x / c.w, y = c.y / c.w
        return CGPoint(x: CGFloat(x + 1) * 0.5 * viewSize.width,
                       y: CGFloat(y + 1) * 0.5 * viewSize.height)
    }

    static func intersectPlane(_ ray: Ray, point: SIMD3<Float>, normal: SIMD3<Float>) -> SIMD3<Float>? {
        let denom = dot(ray.direction, normal)
        guard abs(denom) > 1e-6 else { return nil }
        let t = dot(point - ray.origin, normal) / denom
        guard t > 0 else { return nil }
        return ray.origin + ray.direction * t
    }

    static func radians(_ degrees: Float) -> Float { degrees * .pi / 180 }
}
