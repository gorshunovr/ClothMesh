import CoreGraphics
import simd

/// Turns pointer events into a kinematic grab point `G` that the sim pulls vertices toward.
final class GrabController {
    private(set) var grabPoint: SIMD3<Float>?
    private var grabID: Int?
    private var planePoint = SIMD3<Float>.zero
    private var planeNormal = SIMD3<Float>(0, 0, 1)

    var isGrabbing: Bool { grabPoint != nil }

    /// Returns false when nothing was hit (the caller may then use the drag for something else).
    func begin(at point: CGPoint, viewSize: CGSize, camera: OrbitCamera, sim: ClothSim) -> Bool {
        let vp = camera.viewProjection(viewSize: viewSize)
        let ray = Math.screenRay(point, viewSize: viewSize, inverseViewProjection: vp.inverse)

        let hitPoint: SIMD3<Float>
        if let hit = Raycast.intersect(ray, positions: sim.positions, triangles: sim.mesh.triangles) {
            hitPoint = hit.point
            let (a, b, c) = hit.indices
            grabID = sim.beginGrab(indices: [a, b, c], weights: [hit.weights.x, hit.weights.y, hit.weights.z], at: hitPoint)
        } else if let i = Raycast.nearestVertex(to: point, positions: sim.positions, count: sim.count,
                                                viewProjection: vp, viewSize: viewSize) {
            hitPoint = sim.positions[i]
            grabID = sim.beginGrab(indices: [i], weights: [1], at: hitPoint)
        } else {
            return false
        }

        // Drag plane through the hit point, parallel to the view.
        planePoint = hitPoint
        planeNormal = camera.forward
        grabPoint = hitPoint
        return true
    }

    func drag(to point: CGPoint, viewSize: CGSize, camera: OrbitCamera, sim: ClothSim) {
        guard isGrabbing, let id = grabID else { return }
        let vp = camera.viewProjection(viewSize: viewSize)
        let ray = Math.screenRay(point, viewSize: viewSize, inverseViewProjection: vp.inverse)
        guard let g = Math.intersectPlane(ray, point: planePoint, normal: planeNormal) else { return }
        grabPoint = g
        sim.moveGrab(id, to: g)
    }

    func end(sim: ClothSim) {
        if let id = grabID { sim.endGrab(id) }
        cancel()
    }

    /// Forgets the grab without touching the sim (used when the sim is rebuilt).
    func cancel() {
        grabPoint = nil
        grabID = nil
    }
}
