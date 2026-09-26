# Cloth Mesh Playground — macOS spec

## 1. Product

Native macOS app (not iOS, not Catalyst-only). One window. Real-time 3D cloth mesh you can grab with mouse/trackpad and fling. Cloth starts draped over an **invisible collision sphere**. No menus required for v1 beyond standard macOS window chrome.

Reference feel (2003 memory, rebuilt):

- Wireframe “mesh net”
- Soft cloth / trampoline physics, not rigid 3D modeling
- Pointer grab + drag deforms the mesh
- Rest pose ≈ sheet hanging on a hidden ball

| Field | Value |
|---|---|
| App name | `ClothNet` |
| Bundle ID | `local.clothnet.app` |
| Minimum OS | macOS 14 Sonoma |
| Architecture | Apple Silicon first; universal if cheap |

## 2. Tech stack (do not change without reason)

- Language: Swift 5.10+
- UI: SwiftUI app lifecycle + `NSViewRepresentable` wrapping a custom `MTKView`
- Render: Metal (not SceneKit, not RealityKit, not OpenGL)
- Math: simd (`SIMD3<Float>`, `float4x4`)
- Physics: custom CPU XPBD cloth (not PhysX, not Bullet)
- Input: AppKit mouse + `NSEvent` trackpad, plus SwiftUI gestures forwarded into the Metal view
- No third-party deps for v1

Why custom physics: we need vertex-level grab springs and a single analytic sphere collider. SceneKit cloth is a black box and looks wrong.

## 3. Scene

World units: meters. Y-up. Right-handed.

### 3.1 Invisible sphere

- Center `C = (0, 0.15, 0)`
- Radius `R = 0.55`
- Collision only. Do not draw by default.
- Debug toggle `showCollider` draws a faint low-poly sphere, 15% opacity.

### 3.2 Cloth

- Grid `Nx * Ny` vertices. Default `Nx = Ny = 48` (2304 verts). Slider 16…80.
- Rest size: `1.6 x 1.6` meters, centered on XZ, initial Y = `C.y + R + 0.02` (just above the pole).
- Topology: regular quad grid → two triangles per quad.
- Structural springs: horizontal + vertical neighbors
- Shear springs: diagonals
- Optional bend springs: every second neighbor (toggle, default ON at low stiffness)

Initialization:

1. Place cloth as a flat sheet above the sphere.
2. Run 180 quiet sim steps with gravity + sphere collision, no user input.
3. Then present first frame. User should see a draped net, not a floating plane.

### 3.3 Camera

- Orbit camera around origin.
- Distance 3.2, pitch 28°, yaw 25°.
- Controls:
  - Trackpad two-finger scroll or right-drag: orbit
  - Pinch or mouse wheel: dolly 1.6…8.0
  - Option+drag or middle-drag: pan
- Never steal left-button from cloth grab.

## 4. Physics (XPBD)

Timestep: fixed `dt = 1/120`. If display is 60 Hz, do 2 substeps. Cap 4 substeps/frame.

Per vertex:

```
position: SIMD3<Float>
prevPosition / velocity
invMass: Float   // 0 = pinned (none pinned in v1 except during grab)
```

Forces / integration:

- Gravity `(0, -9.8, 0)`
- Light damping on velocity, default `0.04` per 1/60s (scale with dt)
- XPBD constraint iterations: 8 (exposed)

### 4.1 Distance constraints

For each spring:

- rest length `L0` from initial flat layout (not from draped pose)
- compliance:
  - structural `1.0e-8`
  - shear `2.0e-7`
  - bend `5.0e-6`
- XPBD distance projection, both particles, mass-weighted

### 4.2 Sphere collision

After constraint iterations, for each vertex `p`:

```
d = p - C
len = length(d)
if len < R + thickness:
    n = d / max(len, 1e-8)
    p = C + n * (R + thickness)
    // kill inward normal velocity
```

`thickness = 0.012`

Friction: project out tangential velocity `mu = 0.25` when in contact.

### 4.3 Self-collision

Skip in v1. Optional later.

### 4.4 Grab (the important part)

On left mouse down over the mesh:

1. Raycast against cloth triangles (CPU, first hit).
2. Remember triangle + barycentric coords `(u,v,w)` and the 3 vertex indices.
3. Create a **kinematic grab point** `G` that follows the pointer on a plane:
   - plane through hit point, facing camera (or parallel to view)
4. Each sim substep attach the 3 vertices to `G` with XPBD or stiff springs:
   - target `p_i -> G` weighted by barycentric
   - invMass temporarily * 0.15 while grabbed so the sheet lifts instead of tearing
5. On mouse move, update `G` by intersecting the new camera ray with the grab plane.
6. On mouse up: release masses, keep current velocity so the cloth can be flung.

Trackpad: same as mouse. Support click-and-drag. Do not require Force Touch.

Visual grab cue: small filled dot at `G`, plus highlight the grabbed vertices.

Reset key `R`: rebuild rest sheet and re-drape.

## 5. Rendering (Metal)

Single pass forward.

Buffers:

- Vertex: position (sim), normal (recomputed each frame), uv
- Index: UInt32 triangle list
- Uniforms: MVP, model, camera pos, time, wire color, fill color, light dir

Shading:

- Fill: unlit / simple Lambert, dark teal, alpha 0.28
- Wire: draw triangle edges as lines OR geometry shader equivalent — on Metal, build a separate line-index buffer of unique edges
- Wire color: pale mint / white, alpha 0.9
- Depth on, alpha blend for fill then lines with depth bias so wires stay visible
- Clear color: near-black `#0B0D10`

Normals: average face normals each frame on CPU for v1. Fine at 48².

Do **not** use mesh shaders. Keep the renderer boring and readable.

MSAA 4x if the GPU allows.

## 6. UI

SwiftUI overlay, bottom HUD, dark, compact:

- Reset
- Pause / Play
- Toggle collider
- Toggle fill (wire-only default ON fill)
- Sliders: grid res, gravity scale, stiffness (maps to structural compliance), damping, iterations
- FPS + vertex count label

Window default 1280×800, resizable. `MTKView` fills the window under the HUD.

## 7. Project layout

```
ClothNet/
  ClothNetApp.swift
  ContentView.swift
  MetalView.swift          // NSViewRepresentable + Coordinator
  Renderer.swift           // MTKViewDelegate
  Camera.swift
  ClothSim.swift           // particles, constraints, step()
  ClothMesh.swift          // grid build, index buffers, drape init
  Raycast.swift
  GrabController.swift
  Shaders.metal
  Math.swift               // lookAt, perspective, ray from mouse
  Info.plist
```

Single target macOS app. Sandbox ON. No network.

## 8. Input mapping

| Action | Input |
|---|---|
| Grab / drag cloth | Left mouse / trackpad click-drag |
| Orbit | Right drag or two-finger scroll |
| Pan | Option+left or middle drag |
| Dolly | Wheel / pinch |
| Reset | R |
| Pause | Space |
| Toggle collider | C |
| Toggle wire-only | W |

Convert window coords → NDC → world ray in `Math.screenRay`.

## 9. Acceptance tests

1. Launch: within 1s user sees draped wire net over empty space (sphere hidden).
2. Grab near the crown: sheet lifts locally like fabric, not like a rigid lid.
3. Release after a yank: cloth oscillates and settles back onto the hidden sphere.
4. Grab an edge and pull off the sphere: cloth slides, then hangs / slides around the ball, does not explode.
5. Orbit while simulating stays smooth.
6. 48×48 at ≥50 FPS on M1.
7. Reset returns to the same draped pose.

Failure modes to prevent:

- Exploding mesh → lower compliance, more iterations, clamp max vertex displacement per substep to `0.05`
- Tunneling through sphere → 2–4 substeps + thickness
- Can’t grab → raycast against triangles, not just vertices; pick radius 8 px fallback to nearest vertex if miss

## 10. Implementation order for Claude Code

1. Empty macOS app + Metal triangle
2. Camera orbit + grid mesh rendered as wires
3. CPU Verlet/XPBD cloth hanging in empty space (no sphere)
4. Add sphere collision + drape warmup
5. Raycast + grab springs
6. HUD sliders
7. Polish: damping, friction, MSAA, grab gizmo

Do not start with RealityKit. Do not add file loaders. Do not add audio.

## 11. Shader sketch

```metal
struct VertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
};
struct VSOut {
    float4 position [[position]];
    float3 worldPos;
    float3 normal;
};
vertex VSOut vertex_main(VertexIn in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    VSOut o;
    float4 wp = u.model * float4(in.position, 1);
    o.worldPos = wp.xyz;
    o.normal = (u.model * float4(in.normal, 0)).xyz;
    o.position = u.vp * wp;
    return o;
}
fragment float4 fragment_fill(VSOut in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    float3 n = normalize(in.normal);
    float diff = saturate(dot(n, normalize(u.lightDir))) * 0.6 + 0.25;
    return float4(float3(0.15, 0.45, 0.42) * diff, 0.28);
}
fragment float4 fragment_wire() {
    return float4(0.82, 0.95, 0.88, 0.92);
}
```

## 12. XPBD distance constraint (reference)

```
func projectDistance(_ a: Int, _ b: Int, rest: Float, compliance: Float, dt: Float) {
    let inv = particles[a].invMass + particles[b].invMass
    if inv <= 0 { return }
    let delta = particles[b].position - particles[a].position
    let len = length(delta)
    if len < 1e-8 { return }
    let C = len - rest
    let alpha = compliance / (dt * dt)
    let s = C / (inv + alpha)
    let n = delta / len
    particles[a].position += n * s * particles[a].invMass
    particles[b].position -= n * s * particles[b].invMass
}
```

Grab constraint: same formula from vertex to `G`, rest length 0, compliance `1e-9`.

## 13. Out of scope v1

Undo, save/load OBJ, GPU compute sim, self-collision, tearing, wind field editor, VR, iPhone.

Wind as a later 3-line force is OK if HUD already works: `force += (0.4, 0, 0.15) * sin(time)`.

## 14. Prompt for Claude Code

Use this as the first message:

> Implement ClothNet from ClothNet-macOS-spec.md as a native macOS Swift + Metal app. Follow the stack and file layout exactly. Do not use SceneKit or RealityKit. Start with a running MTKView, then cloth sim, then sphere drape, then grab. Stop after acceptance tests 1–5 work.
