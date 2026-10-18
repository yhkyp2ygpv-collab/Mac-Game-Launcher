import SwiftUI

/// Bindings are expressed once, in canonical terms, and rendered with whatever
/// glyphs the connected pad actually has printed on it.
struct ControllerEditor: View {
    /// Mirrors the decision ControllerManager.environment makes at launch.
    private func handling(for pad: ConnectedController) -> String {
        if ControllerManager.firstPartyVendors.contains(pad.vendorID) {
            return "SDL's dedicated driver — analog triggers, rumble, full layout"
        }
        let bus = pad.transport == .bluetooth ? 0x05 : 0x03
        if let lib = RuntimeManager.shared.defaultRuntime.map({ $0.root.appendingPathComponent("lib/libSDL2-2.0.0.dylib") }),
           SDLControllerDB.mapping(vendor: pad.vendorID, product: pad.productID,
                                   version: 0, bus: bus, in: lib) != nil {
            return "SDL's built-in mapping for this model"
        }
        return "Mapped from the pad's own layout — remap below if a button is off"
    }

    @Binding var profile: ControllerProfile
    @EnvironmentObject private var controllers: ControllerManager
    @StateObject private var tester = ControllerTester.shared

    @State private var previewFamily: ControllerFamily = .xbox
    var configuredContainer: Container?
    var runtimeForContainer: Runtime?

    private var activeFamily: ControllerFamily {
        controllers.controllers.first?.family ?? previewFamily
    }

    var body: some View {
        connectedSection
        behaviourSection
        bindingSection
        deadzoneSection
    }

    // MARK: Connected

    @ViewBuilder
    private var pollSection: some View {
        if let container = configuredContainer {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Controller poll interval")
                    Spacer()
                    Text("\(container.controllerPollMs) ms")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                Text("Wine reads controllers from a loop that waits up to 10 ms between polls — that wait is the floor on controller latency, and it is why keyboard and mouse feel instant by comparison: those arrive as events and never go through it. Anvil shortens the wait. A pad reporting at 250 Hz sends something every 4 ms, so there is nothing to gain below 1 ms.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var connectedSection: some View {
        Button {
            controllers.refresh()
        } label: {
            Label("Scan for Controllers", systemImage: "arrow.clockwise")
        }

        if let container = configuredContainer, let runtime = runtimeForContainer {
            Button {
                Task { await Library.shared.configureControllers(in: container, runtime: runtime) }
            } label: {
                Label("Repair Controller Support in This Container", systemImage: "wrench.and.screwdriver")
            }
            Text("A fresh Wine prefix has no DirectInput settings, so a pad is enumerated as a plain joystick and never mapped to XInput — which is what Unity and most modern games read. New containers get this automatically; this fixes one made before that.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        pollSection

        if controllers.controllers.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "gamecontroller").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("No controller connected").font(.callout)
                    Text("Plug one in over USB, or pair it in System Settings → Bluetooth. Anvil detects Xbox, DualSense, DualShock 4, Switch Pro, Joy-Cons, Steam, and generic HID pads from PowerA, Hori, 8BitDo, PDP, Nacon and Razer. Bindings below still apply when one appears.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Picker("Show glyphs for", selection: $previewFamily) {
                ForEach(ControllerFamily.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
        } else {
            ForEach(controllers.controllers) { pad in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: pad.transport.symbol)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pad.displayName).font(.callout).bold()
                        Text(pad.subtitle)
                            .font(.caption).foregroundStyle(.secondary)
                        if pad.vendorID != 0 {
                            Text(String(format: "vid 0x%04X · pid 0x%04X", pad.vendorID, pad.productID))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            // Which path the game will actually use for this pad, so a
                            // controller that misbehaves can be diagnosed at a glance.
                            Label(handling(for: pad), systemImage: "arrow.triangle.branch")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
            }

            // Ask the game's own SDL, with this launch's exact settings, what it sees.
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button {
                        tester.run(profile: profile, runtime: runtimeForContainer)
                    } label: {
                        Label(tester.isRunning ? "Press buttons and move the sticks…" : "Test controllers with the game engine",
                              systemImage: "gamecontroller")
                    }
                    .disabled(tester.isRunning)
                    if tester.isRunning { ProgressView().controlSize(.small) }
                }
                if let verdict = tester.verdict {
                    Text(verdict).font(.callout).bold()
                        .foregroundStyle(verdict.hasPrefix("Working") ? .green : .orange)
                }
                if !tester.lines.isEmpty {
                    ScrollView {
                        Text(tester.lines.suffix(60).joined(separator: "\n"))
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 160)
                }
                Text("Runs the engine's own controller library with exactly the settings a launch uses, for eight seconds, and shows every input it reads. Anvil listing a pad and the game reading it are different things — after the macOS 27 update Anvil saw the PowerA pad and the game's SDL saw nothing.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)

            if controllers.controllers.contains(where: { !$0.hasNativeProfile }) {
                Text("A pad marked “HID only” is one macOS has no built-in profile for. Anvil still detects it and still maps it — games read it through SDL and Wine directly — but macOS exposes no battery level, haptics or motion for it.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Behaviour

    private var behaviourSection: some View {
        Group {
            Toggle("Swap confirm and cancel", isOn: $profile.swapFaceButtons)
            Text("For Xbox and PlayStation pads. A Switch pad follows the game's own Face buttons setting instead — or, in a game that is shown it as a Pro Controller, the game's own Nintendo layout — so the two can never cancel each other out.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Anvil maps by physical position, so the bottom button is always “confirm” whether the pad prints A or B on it. Turn this on only if you want the Nintendo convention instead.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Toggle("Swap triggers and shoulders", isOn: $profile.swapTriggersAndShoulders)
            Toggle("Invert look (Y axis)", isOn: $profile.invertLookY)
            Toggle("Rumble", isOn: $profile.rumbleEnabled)
            if profile.rumbleEnabled {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Rumble intensity")
                        Spacer()
                        Text("\(Int(profile.rumbleIntensity * 100))%")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: $profile.rumbleIntensity, in: 0...1)
                }
            }
            Text("Deadzones and gyro mapping are not currently connected to anything: the SDL hints Anvil was setting for them turned out not to exist in this SDL build, so the sliders moved and nothing changed. Deadzone is best set in the game's own options for now.")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Bindings

    private var bindingSection: some View {
        Group {
            ForEach(CanonicalInput.allCases.prefix(14), id: \.self) { input in
                HStack {
                    Text(activeFamily.glyph(for: input))
                        .font(.system(.callout, design: .rounded)).bold()
                        .frame(width: 62, alignment: .leading)
                        .foregroundStyle(Color.accentColor)

                    Picker("", selection: Binding(
                        get: { profile.remap[input] ?? input },
                        set: { newValue in
                            if newValue == input { profile.remap.removeValue(forKey: input) }
                            else { profile.remap[input] = newValue }
                        }
                    )) {
                        ForEach(CanonicalInput.allCases) { target in
                            Text(activeFamily.glyph(for: target)).tag(target)
                        }
                    }
                    .labelsHidden()

                    if profile.remap[input] != nil {
                        Button {
                            profile.remap.removeValue(forKey: input)
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(.borderless)
                        .help("Reset to default")
                    }
                }
            }

            Button("Reset All Bindings") { profile.remap.removeAll() }
                .disabled(profile.remap.isEmpty)

            Text("Remaps apply to third-party pads — the ones Anvil maps from their own layout, and the ones SDL has a built-in mapping for. PlayStation, Xbox, Switch and Steam controllers run on SDL's dedicated drivers instead, which give them analog triggers, rumble and their full layout; those always use the standard layout, so remap them in the game's own control settings. Games that talk raw DirectInput rather than XInput use Wine's own joystick handling and ignore remaps either way.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Deadzones

    private var deadzoneSection: some View { EmptyView() }

    private func slider(_ label: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: "%.0f%%", value.wrappedValue * 100))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: 0...0.4)
        }
    }
}
