import CoreGraphics
import simd

/// Orbit camera around `target` (the origin until the user pans).
struct OrbitCamera {
    var target = SIMD3<Float>(0, 0, 0)
    var distance: Float = 3.2
    var pitch: Float = Math.radians(28)
    var yaw: Float = Math.radians(25)
    var fovY: Float = Math.radians(45)
    var near: Float = 0.05
    var far: Float = 50

    static let minDistance: Float = 1.6
    static let maxDistance: Float = 8.0
    private static let maxPitch: Float = Math.radians(88)

    var eye: SIMD3<Float> {
        let dir = SIMD3<Float>(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
        return target + dir * distance
    }

    var forward: SIMD3<Float> { normalize(target - eye) }
    var right: SIMD3<Float> { normalize(cross(forward, SIMD3<Float>(0, 1, 0))) }
    var up: SIMD3<Float> { cross(right, forward) }

    var viewMatrix: float4x4 { .lookAt(eye: eye, target: target, up: SIMD3<Float>(0, 1, 0)) }

    func projectionMatrix(aspect: Float) -> float4x4 {
        .perspective(fovyRadians: fovY, aspect: aspect, near: near, far: far)
    }

    func viewProjection(viewSize: CGSize) -> float4x4 {
        let aspect = Float(max(viewSize.width, 1) / max(viewSize.height, 1))
        return projectionMatrix(aspect: aspect) * viewMatrix
    }

    /// Deltas in points.
    mutating func orbit(dx: Float, dy: Float) {
        yaw -= dx * 0.008
        pitch = min(max(pitch + dy * 0.008, -Self.maxPitch), Self.maxPitch)
    }

    /// factor > 1 moves away, < 1 moves closer.
    mutating func dolly(by factor: Float) {
        distance = min(max(distance * factor, Self.minDistance), Self.maxDistance)
    }

    /// Deltas in points; dy positive = pointer moved up.
    mutating func pan(dx: Float, dy: Float, viewHeight: Float) {
        let worldPerPoint = 2 * distance * tan(fovY * 0.5) / max(viewHeight, 1)
        target += (-right * dx - up * dy) * worldPerPoint
    }
}
