import SwiftUI

/// UI state shared by the HUD and the renderer. Read by the renderer every frame on the main thread.
final class AppModel: ObservableObject {
    @Published var paused = false
    @Published var showCollider = false
    @Published var showFill = true
    @Published var selfCollision = true
    /// Applied when the slider is released (rebuilds and re-drapes the sheet).
    @Published var gridRes: Double = 48
    @Published var gravityScale: Double = 1
    /// 0…1, mapped logarithmically to structural compliance 1e-4…1e-9 (default 1e-8).
    @Published var stiffness: Double = 0.8
    @Published var damping: Double = 0.04
    @Published var iterations: Double = 8

    @Published var demoRunning = false
    @Published var caption: String?

    @Published var fps = 0
    @Published var vertexCount = 0

    weak var renderer: Renderer?

    var resolution: Int { Int(gridRes.rounded()) }

    var structuralCompliance: Float { pow(10, -4 - 5 * Float(stiffness)) }

    var simParams: ClothSim.Params {
        var p = ClothSim.Params()
        p.gravityScale = Float(gravityScale)
        p.damping = Float(damping)
        p.iterations = Int(iterations.rounded())
        p.structuralCompliance = structuralCompliance
        p.selfCollision = selfCollision
        return p
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        ZStack {
            MetalView(model: model)

            if model.demoRunning {
                CaptionView(text: model.caption)
            } else {
                VStack {
                    HStack {
                        Text("Drag cloth to grab · Right-drag / two-finger scroll: orbit · ⌥-drag: pan · Pinch / wheel: zoom · R reset · Space pause · C collider · W fill · D demo")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.4))
                        Spacer()
                    }
                    Spacer()
                    HUDView(model: model)
                }
                .padding(12)
            }
        }
        .background(Color(red: 0x0B / 255, green: 0x0D / 255, blue: 0x10 / 255))
        .frame(minWidth: 900, minHeight: 500)
        .preferredColorScheme(.dark)
    }
}

struct HUDView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("Reset") { model.renderer?.reset() }
                Button(model.paused ? "Play" : "Pause") { model.paused.toggle() }
                    .frame(minWidth: 52)
                Button("Demo") { model.renderer?.startDemo() }
                Toggle("Collider", isOn: $model.showCollider)
                Toggle("Fill", isOn: $model.showFill)
                Toggle("Self-collide", isOn: $model.selfCollision)
                Spacer(minLength: 16)
                Text("\(model.fps) FPS · \(model.vertexCount) verts")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.button)

            HStack(spacing: 16) {
                HUDSlider(title: "Grid", value: $model.gridRes, range: 16...80, step: 1,
                          label: "\(model.resolution)²") { editing in
                    if !editing { model.renderer?.reset() }
                }
                HUDSlider(title: "Gravity", value: $model.gravityScale, range: 0...2,
                          label: String(format: "%.2f×", model.gravityScale))
                HUDSlider(title: "Stiffness", value: $model.stiffness, range: 0...1,
                          label: String(format: "%.0e", model.structuralCompliance))
                HUDSlider(title: "Damping", value: $model.damping, range: 0...0.2,
                          label: String(format: "%.3f", model.damping))
                HUDSlider(title: "Iterations", value: $model.iterations, range: 1...20, step: 1,
                          label: "\(Int(model.iterations.rounded()))")
            }
        }
        .controlSize(.small)
        .font(.system(size: 11))
        .padding(10)
        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08)))
        .frame(maxWidth: 1100)
    }
}

private struct HUDSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    let label: String
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text(label).monospacedDigit()
            }
            if let step {
                Slider(value: $value, in: range, step: step, onEditingChanged: onEditingChanged)
            } else {
                Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
            }
        }
        .frame(minWidth: 120)
    }
}

/// Demo caption: a small technical label in the bottom-left corner.
private struct CaptionView: View {
    let text: String?

    var body: some View {
        VStack {
            Spacer()
            HStack {
                ZStack(alignment: .leading) {
                    if let text {
                        Text(text)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .tracking(2)
                            .foregroundStyle(.white.opacity(0.75))
                            .transition(.opacity)
                            .id(text)
                    }
                }
                .animation(.easeInOut(duration: 0.5), value: text)
                Spacer()
            }
        }
        .padding(24)
        .allowsHitTesting(false)
    }
}
