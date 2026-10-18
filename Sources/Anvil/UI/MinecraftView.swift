import AppKit
import SwiftUI

/// Minecraft: Java Edition through Mojang's own Mac launcher, and Bedrock's PC version in Windows 11 for Arm
/// through VMware Fusion (see Core/Minecraft, Core/MinecraftPC).
struct MinecraftView: View {
    @ObservedObject private var minecraft = Minecraft.shared
    @ObservedObject private var pc = MinecraftPC.shared
    @ObservedObject private var pads = HIDControllerScanner.shared

    private let tint = Color(red: 0.25, green: 0.55, blue: 0.2)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StoreHeader(title: "Minecraft",
                            subtitle: "Java Edition on this Mac through Mojang's own launcher, and Bedrock's PC version in Windows through VMware Fusion — both with your own account.",
                            symbol: "cube.fill", tint: tint) {
                    Button { minecraft.refresh(); pc.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                }
                if let error = minecraft.openError { Notice(text: error) }
                javaCard
                bedrockCard
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .onAppear { minecraft.refresh() }
    }

    private var javaCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Java Edition").font(.title2).bold()
                    Text(minecraft.javaApp != nil ? "Minecraft Launcher\(minecraft.javaVersion.map { " " + $0 } ?? "") installed" : "Not installed")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if minecraft.javaApp != nil {
                    Button { minecraft.openJava() } label: { Label("Play", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent).tint(tint)
                } else {
                    Button { minecraft.openJava() } label: { Label("Get Minecraft", systemImage: "arrow.up.right.square") }
                }
            }
            fact("macbook", "Runs natively",
                 "Java Edition is a Mac game: it runs natively on Apple silicon through Mojang's Minecraft Launcher, signed in with your Microsoft account. Multiplayer, Realms and mods work as on any computer.")
        }
        .padding(18)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Bedrock's PC version, in Windows through VMware Fusion (Core/MinecraftPC)

    private var bedrockCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Bedrock Edition for PC").font(.title2).bold()
                    Text(pcStateText).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if let busy = pc.busy {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.callout).foregroundStyle(.secondary)
                } else if pc.machine != nil && pc.fusionApp != nil {
                    if pc.state == .running {
                        Button { pc.putAway() } label: { Label("Put Away", systemImage: "pause.fill") }
                    }
                    Button { pc.play() } label: {
                        Label(pc.state == .suspended ? "Resume" : (pc.state == .running ? "Show" : "Play"), systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent).tint(tint)
                }
            }
            if let problem = pc.problem { Notice(text: problem) }
            if let message = pc.message { Notice(text: message, symbol: "checkmark.circle.fill", tint: .green) }

            fact("checkmark.shield", "The real PC version, nothing to get banned for",
                 "Minecraft from the Microsoft Store, in Windows 11, signed in with your own Microsoft account: Xbox sign-in, Realms, the Marketplace and cross-play as on any PC. Anvil runs Windows in VMware Fusion (free), sets it up for Minecraft and starts it straight into the game.")

            VStack(alignment: .leading, spacing: 10) {
                step(1, done: pc.fusionApp != nil, "VMware Fusion",
                     pc.fusionApp != nil ? "Installed\(pc.fusionVersion.map { " (\($0))" } ?? "")."
                                         : "Free for personal use from Broadcom (their download asks for a free Broadcom account). It gives Windows 11 for Arm DirectX 11 through Metal.") {
                    if pc.fusionApp == nil {
                        Button("Get VMware Fusion") { NSWorkspace.shared.open(MinecraftPC.fusionPage) }
                    }
                }
                step(2, done: pc.machine != nil, "Windows 11 for Arm",
                     pc.machine.map { "\($0.name) (\($0.guestOS))." }
                        ?? "Download Windows 11 for Arm from Microsoft, then in Fusion choose File › New and drag it in. Keep the encryption Fusion offers on — Windows 11 needs the TPM it adds — then finish Windows' own setup.") {
                    if pc.machine == nil {
                        Button("Microsoft's Download") { NSWorkspace.shared.open(MinecraftPC.windowsArmPage) }
                        if pc.fusionApp != nil { Button("Open Fusion") { pc.openFusion() } }
                    }
                    if pc.machines.count > 1 {
                        Picker("Machine", selection: Binding(get: { pc.machine?.id ?? "" },
                                                            set: { id in if let m = pc.machines.first(where: { $0.id == id }) { pc.choose(m) } })) {
                            ForEach(pc.machines) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden().frame(maxWidth: 220)
                    }
                }
                step(3, done: pc.tuned, "Set for Minecraft",
                     pc.tuned ? "Cores, memory, 3D graphics, full screen, the folder shared with Windows\(controllerName.map { " and \($0) plugged in to Windows" } ?? "")."
                              : "With Windows shut down and Fusion closed: \(tuningSummary).") {
                    if pc.machine != nil && !pc.tuned {
                        Button("Set for Minecraft") { pc.tune() }.disabled(pc.state != .off)
                        if fusionOpen { Button("Quit Fusion") { pc.quitFusion() } }
                    }
                }
                step(4, done: setupDone, "Set up Windows",
                     setupText) {
                    Button("Show the Setup") { pc.revealSharedFolder() }
                }
                step(5, done: bedrockInstalled, "Minecraft",
                     bedrockInstalled ? "Installed in Windows: it opens as Windows signs in, and Play resumes inside it."
                                      : "In Windows, sign in to the Minecraft Launcher with your Microsoft account and install Minecraft for Windows — your own copy (Java owners usually have it in the Java & Bedrock bundle).") { EmptyView() }
            }

            fact("gamecontroller", "Your controller",
                 controllerText)
            fact("speedometer", "How it runs",
                 "Windows runs Minecraft under its own x64 emulation, and its DirectX 11 through Fusion's Metal graphics — smooth enough for Bedrock's normal look, slower than on a PC. Vibrant Visuals needs DirectX 12 and isn't available in Fusion. Put Away suspends Windows with Minecraft in it and gives its memory back to your Mac.")
        }
        .padding(18)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear { pc.refresh() }
    }

    private var pcStateText: String {
        switch pc.state {
        case .noFusion: "Needs VMware Fusion (free)"
        case .noMachine: "Needs Windows 11 for Arm in Fusion"
        case .off: pc.tuned ? "Ready — Windows is shut down" : "Windows found — set it for Minecraft below"
        case .suspended: "Put away — resumes inside Minecraft"
        case .running: "Running in Fusion"
        }
    }

    private var fusionOpen: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: MinecraftPC.fusionBundleID).contains { !$0.isTerminated }
    }

    private var setupDone: Bool { pc.report?.finished != nil && pc.report?.undone != true }

    private var bedrockInstalled: Bool { pc.report?.minecraft?.contains("MinecraftUWP") == true }

    private var controllerName: String? {
        let pads = HIDControllerScanner.shared.devices
        return (pads.first { $0.transport == .usb } ?? pads.first)?.name
    }

    private var tuningSummary: String {
        let device = DeviceProfile.current
        let cores = device.map { $0.performanceCores + $0.efficiencyCores } ?? ProcessInfo.processInfo.activeProcessorCount
        let memory = device?.memoryGB ?? Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        return MinecraftPC.tuning(cores: cores, memoryGB: memory, shared: MinecraftPC.sharedFolder, controller: nil)
            .map(\.label).filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private var setupText: String {
        guard let r = pc.report, r.finished != nil else {
            return "In Windows: install VMware Tools (Fusion's menu, Virtual Machine › Install VMware Tools), then open the shared folder \\\\vmware-host\\Shared Folders\\Anvil and double-click Set up Minecraft. It shows what it will do and asks first: Windows' consumer extras out, the Store, Xbox and Gaming Services kept, Windows set for games, the Minecraft Launcher installed."
        }
        if r.undone == true { return "Put back in Windows on \(r.finished ?? "")." }
        var parts = ["Done in \(r.windows ?? "Windows")"]
        if let n = r.removed?.count { parts.append("\(n) extras taken out") }
        if let l = r.launcher, !l.isEmpty { parts.append("Minecraft Launcher \(l)") }
        if r.startsMinecraft == true { parts.append("Minecraft opens at sign-in") }
        if let g = r.graphics, !g.isEmpty { parts.append("graphics: " + g.joined(separator: ", ")) }
        if let p = r.problems, !p.isEmpty { parts.append("\(p.count) problem\(p.count == 1 ? "" : "s") — see setup-log.txt") }
        return parts.joined(separator: "; ") + "."
    }

    private var controllerText: String {
        let name = controllerName
        var text = name.map { "\($0) is plugged in to Windows as the machine starts, while it runs (back to your Mac when it's put away)." }
            ?? "Plug your controller in before setting the machine for Minecraft, and it's handed to Windows as the machine starts."
        if let seen = pc.report?.controllers {
            text += seen.isEmpty ? " Windows saw no controller when the setup ran." : " Windows sees: " + seen.joined(separator: ", ") + "."
        }
        text += " Whether Minecraft takes a Nintendo-style pad in Windows depends on Windows' own drivers for it — the setup shows what Windows sees."
        return text
    }

    private func step<Actions: View>(_ n: Int, done: Bool, _ title: String, _ text: String,
                                     @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle")
                .foregroundStyle(done ? .green : tint).font(.title3).frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout).bold()
                Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: 8) { actions() }.controlSize(.small)
            }
        }
    }

    private func fact(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout).bold()
                Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
