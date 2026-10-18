import SwiftUI

struct ContainerDetailView: View {
    let containerID: UUID

    @EnvironmentObject private var library: Library
    @EnvironmentObject private var runtimes: RuntimeManager
    @EnvironmentObject private var snapshots: SnapshotManager
    @EnvironmentObject private var launcher: Launcher

    @State private var showEnvironment = false
    @State private var restoreTarget: SnapshotManager.Snapshot?
    @State private var error: String?
    @State private var showSaveTransfer = false
    @State private var confirmDelete = false
    @State private var saveBackups: [SaveGuard.Backup] = []
    @State private var restoreBackup: SaveGuard.Backup?

    private var container: Binding<Container> {
        Binding(
            get: { library.container(id: containerID) ?? Container(name: "—", runtimeID: "") },
            set: { library.update($0) }
        )
    }

    var body: some View {
        Form {
            profileSection
            presetSection
            graphicsSection
            scalingSection
            overlaySection
            metalSection
            latencySection
            upscalerSection
            controllerSection
            trackpadSection
            cpuSection
            memorySection
            windowsSection
            runtimeSection
            savesSection
            saveBackupsSection
            maintenanceSection
        }
        .formStyle(.grouped)
        .navigationTitle(container.wrappedValue.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showEnvironment = true } label: {
                    Label("Inspect Environment", systemImage: "terminal")
                }
            }
        }
        .sheet(isPresented: $showEnvironment) {
            EnvironmentInspector(container: container.wrappedValue)
        }
        .sheet(isPresented: $showSaveTransfer) {
            SaveTransferView(container: container.wrappedValue)
        }
        .alert("Error", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private var profileSection: some View {
        let display = (Int(NSScreen.main?.frame.width ?? 1512) * 2,
                       Int(NSScreen.main?.frame.height ?? 982) * 2)
        return SwiftUI.Section {
            Picker("Profile", selection: container.profile) {
                ForEach(PerformanceProfile.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: container.wrappedValue.profile) { _, new in
                var c = container.wrappedValue
                new.apply(to: &c)
                container.wrappedValue = c
            }

            Text(container.wrappedValue.profile.summary)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Game renders at") {
                Text(container.wrappedValue.profile.resolutionDescription(displayPixels: display))
                    .font(.callout).bold().monospacedDigit()
            }

            Text("These options interact, and the wrong combination is worse than none: choosing native scaling and then an upscaler multiplied down to 889×577 on this display, which is under a third of native and then stretched back up. A profile sets them together so that cannot happen.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Performance Profile")
        }
    }

    private var presetSection: some View {
        SwiftUI.Section {
            PresetsView(container: container, game: nil)
        } header: {
            Text("Performance Preset")
        } footer: {
            Text("Frame-rate figures are a cost model until a game is actually played under a preset — after that Anvil shows what was measured instead.")
                .font(.caption)
        }
    }

    private var metalSection: some View {
        let cap = MetalCapability.current
        return SwiftUI.Section {
            // There used to be a Metal generation picker and four switches here. Every
            // one of them set an environment variable, and none of those variables is
            // read by anything: checked against the D3DMetal binary in both installed
            // engines, where the known-real MTL_HUD_ENABLED shows up and these do not.
            //
            // They could not have worked. Metal 4 is an API a program chooses in its
            // own code. The game's Metal is D3DMetal's, and D3DMetal decides which
            // Metal it speaks; an environment variable cannot move it onto Metal 4.
            LabeledContent("Metal 4", value: cap.hasMetal4 ? "Available on this Mac" : "Not available")
            LabeledContent("MetalFX frame interpolation",
                           value: cap.hasFrameInterpolation ? "Available" : "Not available")
            LabeledContent("MetalFX temporal upscaling",
                           value: cap.hasMetalFXTemporal ? "Available" : "Not available")

            Text("How a game uses Metal is decided by D3DMetal inside the engine, not by Anvil — that is why the engine's D3DMetal version matters and is shown in Runtimes. What Anvil controls is everything after the game's frame is finished: frame pacing, how many frames are in flight, resolution, sharpening, and frame generation, which uses MetalFX interpolation when the game cannot fill the display itself. macOS 27 added no new presentation or latency API; its MetalFX additions all need depth and motion vectors from the game engine, which a Windows game through D3DMetal does not provide.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Metal")
        } footer: {
            Text("Detected on this Mac: \(cap.summary) · \(cap.deviceName)")
                .font(.caption)
        }
    }

    private var latencySection: some View {
        SwiftUI.Section {
            Picker("Queued frames (when lowest latency is off)", selection: container.maxQueuedFrames) {
                Text("3 — smoother (recommended)").tag(3)
                Text("2 — lower latency, less slack").tag(2)
            }
            Text("How many finished frames may wait to be shown. Two is the lowest latency, but leaves no slack: one frame that runs long has nothing queued behind it, the display repeats, and that reads as a stutter. Three costs a frame of latency and a little memory, and absorbs those spikes — which is the better trade unless you are chasing input lag specifically.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Lock to the display's refresh", isOn: container.lockToRefresh)
            Text("The difference between a high frame rate and a stable one. A game presents whenever it finishes, which lands between refreshes — at 67 fps on a 120 Hz panel a frame arrives every 1.79 refreshes, so the gaps alternate between one refresh and two. The average still reads 120 and it looks like stutter. This puts every frame on the panel's own grid instead. Measured here: 900 of 900 gaps exactly one refresh apart, worst gap 8.3 ms.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Frame rate", selection: container.targetFPS) {
                Text("Up to 120 — each frame as soon as it's ready").tag(0)
                Text("Steady — 120, or an even 80 when it can't").tag(80)
                Text("120 fps").tag(120)
                Text("60 fps").tag(60)
                Text("30 fps").tag(30)
            }
            .disabled(!container.wrappedValue.lockToRefresh)
            Text("Steady holds a game that can't reach 120 to an even 80 — every frame 12.5 ms apart — and lets it back to 120 as soon as it can; the hold is before each frame starts, so it adds almost no delay. Up to 120 shows every frame the moment it's ready, which is the lowest delay but moves with the scene. A lower cap is for holding a heavy game to a rate it can actually keep to.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Pace generated frames", isOn: container.pacing)
            Text("Puts each synthesised frame in a refresh the game left empty, rather than presenting it the instant it is ready. Generation is skipped entirely when the game is already filling every refresh itself — a real frame beats a guessed one and costs less latency, so nothing is generated unless there is a gap to fill.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("One frame in flight", isOn: container.lowLatencyQueue)
                .disabled(!container.wrappedValue.lockToRefresh)
            Text("Holds the game to one finished frame ahead of the display instead of two. In theory that gets input on screen a refresh sooner. Measured on Cat Quest II it did not: latency was 16.8–20 ms against 16.4 ms with two, and the game missed up to 79 refreshes in the first five seconds before Anvil backed off. Off by default for that reason — worth trying only on a game with plenty of headroom. Anvil still goes back to two by itself if refreshes are missed.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Latency is measured on every launch — from the game asking for a frame to that frame reaching the screen — and written to the launch log with the frame rate and 1% low. The old “Measure latency” switch here was wired to a function that was never called, so it never measured anything.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Latency")
        }
    }

    private var upscalerSection: some View {
        SwiftUI.Section("Upscaling") {
            UpscalerEditor(config: container.upscaler, game: nil)
        }
    }

    /// Playing on a MacBook: what Wine's Mac driver does with the trackpad and the keys a
    /// laptop keyboard lacks. Applied at the next launch (one short Wine run, once).
    private var trackpadSection: some View {
        SwiftUI.Section("Trackpad & Keyboard") {
            Toggle("Scroll in steps, like a mouse wheel", isOn: Binding(
                get: { container.wrappedValue.scrollInSteps ?? true },
                set: { container.wrappedValue.scrollInSteps = $0 }))
            Text("Two-finger scrolling reaches the game as whole wheel steps — zoom, weapon and menu scrolling work as they do with a mouse. Off, Wine passes the trackpad's smooth scrolling as fractions of a step, which many Windows games ignore or read as dozens of steps at once.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Left Option key is Alt", isOn: Binding(
                get: { container.wrappedValue.optionIsAlt ?? true },
                set: { container.wrappedValue.optionIsAlt = $0 }))
            Toggle("Command keys are Ctrl", isOn: Binding(
                get: { container.wrappedValue.commandKeysAreCtrl },
                set: { container.wrappedValue.commandIsCtrl = $0 }))
            Text("Games use Alt and Ctrl for walking, crouching and menus. A Mac laptop has a small Control key and no Alt: the left Option key then works as Alt (the right one still types accents), and with the second switch the ⌘ keys as Ctrl — but ⌘Q then reaches the game as Ctrl+Q; quit from Anvil or the menu bar instead. Clicking: a two-finger click or tap is the right button. For moving and aiming at once, a controller or a mouse is still easier.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var controllerSection: some View {
        SwiftUI.Section("Controllers") {
            Toggle("Controller support", isOn: container.enableGamepad)
            Picker("Stick updates sent to the game", selection: container.controllerAxisHz) {
                Text("125 per second (recommended)").tag(125)
                Text("250 per second").tag(250)
                Text("60 per second").tag(60)
                Text("Unlimited").tag(1000)
            }
            Text("Your pad can send over a thousand stick events a second, and under Wine every one becomes a message the game must handle before it draws its next frame. When they come faster than it can keep up, it stops drawing — felt as lag, then a burst of old inputs playing out at once. The game reads the controller once per frame, so 125 a second (once per frame at 120 fps) loses nothing it can use. Buttons are never held back, and a released stick always returns to centre.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if container.wrappedValue.enableGamepad {
                ControllerEditor(profile: container.controllerProfile,
                                 configuredContainer: container.wrappedValue,
                                 runtimeForContainer: runtimes.runtime(id: container.wrappedValue.runtimeID)
                                     ?? runtimes.defaultRuntime)
            }
        }
    }

    // MARK: Graphics

    private var graphicsSection: some View {
        SwiftUI.Section {
            Picker("Graphics backend", selection: container.backend) {
                ForEach(GraphicsBackend.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Text(container.wrappedValue.backend.subtitle)
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 6) {
                ForEach(container.wrappedValue.backend.supportedAPIs, id: \.self) { api in
                    Text(api)
                        .font(.caption2).bold()
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.tint.opacity(0.18), in: Capsule())
                }
            }

            if container.wrappedValue.backend == .dxvk {
                Toggle("Asynchronous shader compilation", isOn: container.dxvkAsync)
                Text("Draws with a placeholder while a pipeline compiles instead of stalling the frame. Removes most traversal stutter; can briefly show untextured geometry.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if container.wrappedValue.backend == .d3dmetal {
                // Every control below maps to a D3DM_* variable that exists in the
                // D3DMetal binary. There used to be a "MetalFX spatial upscaling"
                // switch here backed by DXMT_METALFX_SPATIAL, which D3DMetal has
                // never read — MetalFX upscaling is in the Upscaling section, where
                // Anvil's own injector actually performs it.
                Toggle("Multithreaded command submission", isOn: .constant(true))
                    .disabled(true)
                Text("Always on. Lets D3DMetal record command lists from more than one thread, which is how most DirectX 12 engines submit work.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Ray tracing (DXR)", isOn: container.raytracing)
                Text("Off by default. A DirectX 12 game that finds ray tracing available will use it, and it is the most expensive thing that can run through this translation layer.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // There was a "Texture sharpness" slider here. D3DMetal has no LOD bias
                // value to set — D3DM_LOD_BIAS only switches the game's own bias on or
                // off — so the slider either did nothing or, at ±0.5, switched the
                // game's bias off. Removed rather than left pretending.
            }

            Toggle("Fullscreen", isOn: container.fullscreen)
            Text("Written into the game's own display preference as borderless fullscreen, at the display's real resolution. Anvil used to pass a fullscreen switch on the command line instead, which made the engine ask Windows to change the display mode — and that crashed the game a second after the first scene loaded. Borderless never changes the display mode, and alt-tabs cleanly.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Keep compiled shaders through system cleanups", isOn: container.protectShaderCache)
            Text("D3DMetal caches compiled shaders under /var/folders, which macOS clears on its own schedule; when it does, the game recompiles everything and the stutter returns. Anvil keeps a copy somewhere nothing sweeps it and restores it before each launch. Manage the caches in Runtimes.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if container.wrappedValue.backend == .dxvk {
                Toggle("Persistent DXVK state cache", isOn: container.persistentShaderCache)
                Text("DXVK's own pipeline cache, kept between sessions. Presentation mode and buffering are decided by the swapchain the game creates, not by Anvil — the Triple buffering and VSync switches that used to be here set variables neither backend reads. Queue depth, which does change how a frame is presented, is in Latency.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Graphics")
        }
    }

    // MARK: Scaling

    private var scalingSection: some View {
        SwiftUI.Section("Resolution & Scaling") {
            Picker("Mode", selection: container.scaling) {
                ForEach(ScalingMode.allCases) { Text($0.title).tag($0) }
            }
            if container.wrappedValue.scaling == .custom {
                HStack {
                    TextField("Width", value: container.customWidth, format: .number)
                    Text("×")
                    TextField("Height", value: container.customHeight, format: .number)
                }
                .textFieldStyle(.roundedBorder)
            }
            if container.wrappedValue.scaling != .native {
                Stepper("DPI: \(container.wrappedValue.dpi)", value: container.dpi, in: 96...384, step: 24)
                Text("A game window on a Retina display is handed a drawable measured in points, so it renders at half resolution and the compositor stretches the result — measured at 1512×982 on this 3024×1964 screen, which is why the picture looks soft. Retina mode enlarges the drawable so the game renders every pixel: four times the detail, and correspondingly more GPU work.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if container.wrappedValue.holdsStoreApp {
                Toggle("Store window at full Retina resolution", isOn: Binding(
                    get: { !container.wrappedValue.storeWindowSmooth },
                    set: { container.wrappedValue.storeWindowSharp = $0 }))
                Text("Steam draws its window on the CPU under Wine, every pixel itself. At the display's point size it ran at 46 fps here, at Retina 27 fps with frames of up to 92 ms — sharper text, but it lags. Off, Steam's window is at point size and the games it starts still get this container's resolution.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Overlay

    private var overlaySection: some View {
        SwiftUI.Section("Performance Overlay") {
            HUDEditor(config: container.hud)
        }
    }

    // MARK: CPU

    private var cpuSection: some View {
        SwiftUI.Section("CPU & Scheduling") {
            Picker("Synchronisation", selection: container.sync) {
                ForEach(SyncPrimitive.allCases) { Text($0.title).tag($0) }
            }
            Text(container.wrappedValue.sync.subtitle)
                .font(.caption).foregroundStyle(.secondary)

            Toggle("Advanced Vector Extensions (AVX2)", isOn: container.avx2)
            Toggle("Keep the game's own log (Unity)", isOn: container.keepGameLog)
            Text("Off by default. Under Wine every controller report reaches a Unity game as a raw-input message with no data, and Unity rejects each one by writing about 26 lines to its log on the main thread — measured at up to 1,100 controller events a second while the sticks move, with the game falling below 30 fps. Turning the log off with Unity's own -nolog option removes that work. Turn this on only to troubleshoot.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Game Mode", isOn: container.gameMode)
            Text("macOS gives the frontmost full-screen game first call on the CPU and GPU, holds back background work and polls Bluetooth controllers twice as often — but only for an app that says it is a game, and Wine's launcher in these engines does not. Anvil runs the game through its own copy of the engine that does; the engine itself is left untouched. A game controller icon appears in the menu bar while Game Mode is on.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Game threads at high priority", isOn: container.highPriority)
            Text("Wine starts every game thread at macOS's default priority, which lets the scheduler put a game's main and render threads on the efficiency cores. A Windows game through Rosetta is usually limited by the CPU, and it drops frames when that happens. This raises Wine's threads to the priority macOS gives interactive work, so they run on the performance cores.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Persist Rosetta translation cache", isOn: container.rosettaAOT)
            Text("Keeps x86→ARM translated code across launches, so the first minutes of play aren't spent re-translating.")
                .font(.caption).foregroundStyle(.secondary)

            // A core-limit picker used to sit here, backed by WINE_CPU_TOPOLOGY.
            // That is a Proton variable; this Wine build has no equivalent, so the
            // control changed nothing and the frame-rate estimate it fed was wrong.
        }
    }

    // MARK: Memory

    private var memorySection: some View {
        SwiftUI.Section("Memory") {
            let sys = SystemInfo.current
            let totalMB = sys.memoryGB * 1024
            let reserved = totalMB - container.wrappedValue.memoryBudgetMB

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Memory for this game")
                    Spacer()
                    Text(container.wrappedValue.memoryBudgetMB == 0
                         ? "No budget"
                         : String(format: "%.0f GB", Double(container.wrappedValue.memoryBudgetMB) / 1024))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: Binding(
                    get: { Double(container.wrappedValue.memoryBudgetMB) },
                    set: { container.wrappedValue.memoryBudgetMB = Int($0 / 1024) * 1024 }
                ), in: 0...Double(totalMB - 4096), step: 1024)

                if container.wrappedValue.memoryBudgetMB > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "memorychip")
                        Text(String(format: "%.0f GB left for macOS and everything else",
                                    Double(reserved) / 1024))
                    }
                    .font(.caption).foregroundStyle(reserved < 6144 ? Color.orange : Color.secondary)
                }
            }

            Text("macOS provides no way to hard-cap a process's memory — RLIMIT_AS, RLIMIT_DATA and RLIMIT_RSS are all rejected by the kernel, and the jetsam interfaces need private entitlements. So this budget is enforced three ways rather than by force: the figure is reported to the game so it sizes its own texture and streaming pools to fit, Anvil keeps its own frame history inside the remainder and marks it reclaimable when memory runs short, and the real footprint is measured continuously so an overrun is visible instead of silent. Most engines do respect what they are told; one that ignores it will still exceed the number, and Anvil will say so rather than pretend otherwise.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            VStack(alignment: .leading) {
                HStack {
                    Text("Video memory budget")
                    Spacer()
                    Text(container.wrappedValue.videoMemoryMB == 0
                         ? "Automatic (\(sys.recommendedVRAMMB) MB)"
                         : "\(container.wrappedValue.videoMemoryMB) MB")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: Binding(
                    get: { Double(container.wrappedValue.videoMemoryMB) },
                    set: { container.wrappedValue.videoMemoryMB = Int($0) }
                ), in: 0...Double(sys.maxAssignableMemoryMB), step: 256)
            }
            Text("This Mac has \(sys.memoryGB) GB unified memory; Metal reports \(sys.recommendedVRAMMB) MB as the safe working set. There is no separate VRAM to allocate — this is the budget the translation layer reports to the game so it picks sane texture pools. Setting it above the working set makes games *more* likely to hitch, not less.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Toggle("Large address aware", isOn: container.largeAddressAware)
            Text("Lets a 32-bit game address more than 2 GB. On by default; there is no reason to turn it off unless a title refuses to start with it.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Windows

    private var windowsSection: some View {
        SwiftUI.Section("Windows Environment") {
            Picker("Windows version", selection: container.windowsVersion) {
                ForEach(WindowsVersion.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: container.wrappedValue.windowsVersion) { _, new in
                guard let runtime = runtimes.runtime(id: container.wrappedValue.runtimeID) else { return }
                Task { await library.setWindowsVersion(new, on: container.wrappedValue, runtime: runtime) }
            }
            Toggle("Gamepad support", isOn: container.enableGamepad)

            LabeledContent("Prefix") {
                Button(container.wrappedValue.prefixURL.lastPathComponent) {
                    NSWorkspace.shared.open(container.wrappedValue.driveC)
                }
                .buttonStyle(.link)
            }
        }
    }

    // MARK: Runtime

    private var runtimeSection: some View {
        SwiftUI.Section("Runtime") {
            Picker("Toolchain", selection: container.runtimeID) {
                ForEach(runtimes.runtimes) { rt in
                    Text(rt.displayName + (rt.d3dMetalVersion.map { " · D3DMetal \($0)" }
                                           ?? (rt.hasD3DMetal ? " · D3DMetal" : ""))).tag(rt.id)
                }
            }
            .onChange(of: container.wrappedValue.runtimeID) { old, _ in
                guard old != container.wrappedValue.runtimeID else { return }
                let c = container.wrappedValue
                Task {
                    do { _ = try await snapshots.snapshot(c, label: "Before runtime change") }
                    catch { self.error = error.localizedDescription }
                }
            }

            // A container is never moved to a newer toolchain on its own — the point
            // of pinning one is that a container which works today keeps working. But
            // it should say when a better one is sitting there, because the D3DMetal
            // version is what decides how a DirectX 12 title performs.
            if let best = runtimes.bestD3DMetal,
               let current = runtimes.runtime(id: container.wrappedValue.runtimeID),
               best.id != current.id,
               let newer = best.d3dMetalVersion {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.up.circle.fill").foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(best.displayName) has D3DMetal \(newer)\(current.d3dMetalVersion.map { ", against \($0) here" } ?? "")")
                            .font(.caption)
                        Text("Anvil takes a snapshot before the change, so switching back costs one click and touches no save.")
                            .font(.caption2).foregroundStyle(.secondary)
                        Button("Switch to \(best.displayName)") {
                            container.wrappedValue.runtimeID = best.id
                        }
                        .controlSize(.small)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            Text("Anvil snapshots the container automatically before any toolchain change, so a bad Metal or D3DMetal update is one click to undo — and drive_c is never rewritten in the process.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Maintenance

    private var savesSection: some View {
        SwiftUI.Section("Saves") {
            Button {
                showSaveTransfer = true
            } label: {
                Label("Import Saves from Another Launcher…", systemImage: "arrow.down.doc")
            }
            Text("Mythic, Whisky, Heroic and CrossOver all build their prefixes the same way and name the Windows user folder identically, so a save copies across unchanged. Anvil never removes anything from the launcher you import from, and moves aside anything already in the destination rather than overwriting it.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                let panel = NSOpenPanel()
                panel.message = "Choose where to save the exported copy."
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.canCreateDirectories = true
                guard panel.runModal() == .OK, let url = panel.url else { return }
                do { try SaveTransfer.shared.exportSaves(from: container.wrappedValue, to: url) }
                catch { self.error = error.localizedDescription }
            } label: {
                Label("Export This Container's Saves…", systemImage: "arrow.up.doc")
            }
        }
    }

    // MARK: Save backups

    private var saveBackupsSection: some View {
        let inUse = launcher.sessions.contains { $0.container.id == containerID }
        return SwiftUI.Section("Save Backups") {
            Text("Before every game starts, Anvil copies this container's saves — only when they changed, and on this Mac's drive a copy takes no space until the game changes a file. After a game closes, any save file it left empty is put back from the copy. The newest ten are kept, and one a day for a month.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if saveBackups.isEmpty {
                Text("No backups yet — the first is made when a game here starts.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(saveBackups.prefix(12)) { backup in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(backup.date.formatted(date: .abbreviated, time: .shortened)).font(.callout)
                        Text("\(backup.reason) · \(backup.files) file\(backup.files == 1 ? "" : "s"), \(backup.sizeText)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Put Back…") { restoreBackup = backup }.disabled(inUse)
                    Button { NSWorkspace.shared.activateFileViewerSelecting([backup.url]) } label: { Image(systemName: "folder") }
                        .help("Show in Finder")
                }
            }
            if inUse {
                Text("A game is running in this container. Quit it to put a backup back.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: containerID) { reloadSaveBackups() }
        .confirmationDialog("Put back the saves from \(restoreBackup?.date.formatted(date: .abbreviated, time: .shortened) ?? "")?",
                            isPresented: Binding(get: { restoreBackup != nil }, set: { if !$0 { restoreBackup = nil } }),
                            presenting: restoreBackup) { backup in
            Button("Put Back") { putBack(backup) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Every save file in that backup goes back as it was then. Saves made since that it doesn't have are left alone, and the saves as they are now are backed up first, so this can be undone.")
        }
    }

    private func reloadSaveBackups() {
        let id = containerID
        Task.detached(priority: .utility) {
            let list = SaveGuard.list(for: id)
            await MainActor.run { saveBackups = list }
        }
    }

    private func putBack(_ backup: SaveGuard.Backup) {
        let c = container.wrappedValue
        restoreBackup = nil
        guard !launcher.sessions.contains(where: { $0.container.id == c.id }) else { return }
        Task {
            if let runtime = runtimes.runtime(id: c.runtimeID) {
                let server = runtime.wineserver, prefix = c.prefixURL
                await Task.detached(priority: .userInitiated) { Launcher.killPrefix(wineserver: server, prefix: prefix) }.value
            }
            let result = await Task.detached(priority: .userInitiated) { () -> Result<Int, Error> in
                Result { try SaveGuard.restore(backup.url, prefix: c.prefixURL, containerID: c.id, containerName: c.name) }
            }.value
            switch result {
            case .success(let n): AnvilLog.write("saves: \(n) file(s) of “\(c.name)” put back from \(backup.url.lastPathComponent)")
            case .failure(let e): self.error = e.localizedDescription
            }
            reloadSaveBackups()
        }
    }

    private var maintenanceSection: some View {
        SwiftUI.Section("Snapshots & Safety") {
            Button {
                Task {
                    do { _ = try await snapshots.snapshot(container.wrappedValue, label: "Manual snapshot") }
                    catch { self.error = error.localizedDescription }
                }
            } label: {
                Label("Take Snapshot Now", systemImage: "camera.aperture")
            }

            ForEach(snapshots.snapshots(for: container.wrappedValue)) { snap in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snap.label).font(.callout)
                        Text(snap.createdAt.formatted(date: .abbreviated, time: .shortened)
                             + " · " + ByteCountFormatter.string(fromByteCount: snap.sizeBytes, countStyle: .file))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restore") { restoreTarget = snap }
                    Button(role: .destructive) { snapshots.delete(snap) } label: {
                        Image(systemName: "trash")
                    }
                }
            }

            // Deleting took one click and erased the prefix outright — with every save
            // its games keep inside it. It now asks, and the prefix goes to the Trash.
            let inUse = launcher.sessions.contains { $0.container.id == containerID }
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete Container…", systemImage: "trash")
            }
            .disabled(inUse)
            if inUse {
                Text("A game is running in this container. Quit it first.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Delete “\(container.wrappedValue.name)”?", isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive) {
                library.deleteContainer(container.wrappedValue)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let count = library.games(in: container.wrappedValue).count
            Text("Its Windows environment goes to the Trash, including every save and setting its games keep inside it\(count > 0 ? ", and its \(count) game\(count == 1 ? "" : "s") leave the library" : ""). The games' own files are not touched, and until the Trash is emptied the saves can still be copied back out of it in Finder.")
        }
        .confirmationDialog("Restore this snapshot?", isPresented: .constant(restoreTarget != nil), presenting: restoreTarget) { snap in
            Button("Restore, keep my saves") {
                restore(snap, preserveSaves: true)
            }
            Button("Restore everything", role: .destructive) {
                restore(snap, preserveSaves: false)
            }
            Button("Cancel", role: .cancel) { restoreTarget = nil }
        } message: { _ in
            Text("“Keep my saves” reverts the Windows system state but leaves everything under your user profile — saves, settings, screenshots — exactly as it is now.")
        }
    }

    private func restore(_ snap: SnapshotManager.Snapshot, preserveSaves: Bool) {
        let c = container.wrappedValue
        restoreTarget = nil
        Task {
            do { try await snapshots.restore(snap, to: c, preserveSaves: preserveSaves) }
            catch { self.error = error.localizedDescription }
        }
    }
}
