import AppKit
import SwiftUI

/// 3D surround sound for every game, and whether what the Mac plays through can do it (see
/// Core/SpatialSound and Core/SoundOutputs). The same panel opens from the Library's toolbar and
/// the sidebar, and sits in Settings; the menu bar has the switch too.
struct SurroundSoundPanel: View {
    @AppStorage(SpatialSound.enabledKey) private var enabled = true
    @AppStorage(SpatialSound.outputKey) private var choice: SpatialSound.Output = .automatic
    @AppStorage(SpatialSound.headTrackingKey) private var headTracking = false
    @AppStorage(SpatialSound.upmixKey) private var upmix = true
    @ObservedObject private var outputs = SoundOutputs.shared
    @ObservedObject private var launcher = Launcher.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: Binding(get: { enabled }, set: { SpatialSound.setEnabled($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("3D Surround Sound").font(.headline)
                    Text("For every game — headphones, earbuds, AirPods, the Mac's speakers, external speakers and 5.1 or 7.1 systems.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            if let current = outputs.current {
                SoundOutputCard(output: current, choice: choice, enabled: enabled)
                SoundScanSection(output: current)
            } else {
                Label("The Mac has no sound output right now.", systemImage: "speaker.slash")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if enabled {
                Picker("Listening on", selection: $choice) {
                    ForEach(SpatialSound.Output.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .help("Automatic tells the headphone jack from the speakers, and takes Bluetooth and USB devices for headphones unless their name says speaker. Choose here if it guesses wrong.")
                if let current = outputs.current, current.fit(choice) == .threeD {
                    Toggle("Follow head movement with AirPods", isOn: $headTracking)
                        .help("With AirPods that track your head the sound stays anchored to the screen as you turn. Off by default: in a game your view turns with the mouse or stick, not your head.")
                }
                Toggle(isOn: $upmix) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Surround for stereo games (Anvil Surround)")
                        Text("For games that only mix in stereo: voices in the middle go to the centre, the room — rain, crowds, echoes — beside and behind you, and sounds panned to one side stay where the game put them. Games with their own surround are left as they mix.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if !launcher.sessions.isEmpty {
                Label("\(ListFormatter.localizedString(byJoining: launcher.sessions.map(\.game.title))) \(launcher.sessions.count == 1 ? "keeps" : "keep") the sound \(launcher.sessions.count == 1 ? "it" : "they") started with — changes here take effect at a game's next start.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !outputs.others.isEmpty {
                DisclosureGroup("Other outputs on this Mac (\(outputs.others.count))") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(outputs.others) { output in
                            SoundOutputRow(output: output, choice: choice)
                        }
                        Text("Switch outputs in Control Center or System Settings › Sound.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.top, 6)
                }
                .font(.callout)
            }

            HStack {
                Button("Sound Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Spacer()
                Button {
                    outputs.refresh()
                } label: {
                    Label("Check Again", systemImage: "arrow.clockwise")
                }
                .help("Read the Mac's outputs again")
            }
            .controlSize(.small)
        }
        .onAppear { outputs.refresh() }
    }
}

/// The output playing now: what it is, whether 3D sound works on it, and what it sounds like.
struct SoundOutputCard: View {
    let output: SoundOutput
    let choice: SpatialSound.Output
    let enabled: Bool

    var body: some View {
        let fit = output.fit(choice)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: output.symbol)
                    .font(.system(size: 24))
                    .foregroundStyle(fit.compatible ? Color.accentColor : .orange)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(output.name).font(.body.bold()).lineLimit(1)
                    Text("Playing now · \(output.subtitle)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                CompatibilityBadge(compatible: fit.compatible)
            }
            Text(enabled || !fit.compatible ? output.headline(choice) : "Ready for \(output.headline(choice).lowercasedFirst)")
                .font(.callout.bold())
            Text(enabled ? output.detail(choice)
                         : "3D surround sound is off: games play their own mix, folded into stereo where it's wider.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if enabled, let hint = output.hint(choice) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lightbulb").foregroundStyle(.yellow)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(hint.text).fixedSize(horizontal: false, vertical: true)
                        if hint.opensAudioMIDISetup {
                            Button("Open Audio MIDI Setup") {
                                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
                            }
                            .controlSize(.small)
                        }
                    }
                }
                .font(.caption)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Another output, in a line.
struct SoundOutputRow: View {
    let output: SoundOutput
    let choice: SpatialSound.Output

    var body: some View {
        let fit = output.fit(choice)
        HStack(spacing: 10) {
            Image(systemName: output.symbol).frame(width: 22).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(output.name).lineLimit(1)
                Text("\(output.subtitle) · \(output.headline(choice))").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 6)
            CompatibilityBadge(compatible: fit.compatible, compact: true)
        }
        .help(output.detail(choice))
    }
}

struct CompatibilityBadge: View {
    let compatible: Bool
    var compact = false

    var body: some View {
        Label(compatible ? "Compatible" : "Not compatible",
              systemImage: compatible ? "checkmark.circle.fill" : "xmark.circle.fill")
            .font(compact ? .caption2.bold() : .caption.bold())
            .foregroundStyle(compatible ? Color.green : Color.orange)
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 2 : 4)
            .background((compatible ? Color.green : Color.orange).opacity(0.14), in: Capsule())
            .fixedSize()
    }
}

/// The Library's toolbar button: on or off at a glance, the panel a click away.
struct SurroundSoundButton: View {
    @AppStorage(SpatialSound.enabledKey) private var enabled = true
    @AppStorage(SpatialSound.outputKey) private var choice: SpatialSound.Output = .automatic
    @ObservedObject private var outputs = SoundOutputs.shared
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Label("3D Surround Sound", systemImage: enabled ? "speaker.wave.3.fill" : "speaker.slash")
        }
        .help(SurroundSoundStatus.summary(enabled: enabled, output: outputs.current, choice: choice))
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            SurroundSoundPanel().padding(16).frame(width: 400)
        }
    }
}

/// The sidebar's line under the Mac's details: on or off, and the output with its verdict.
struct SurroundSoundStatus: View {
    @AppStorage(SpatialSound.enabledKey) private var enabled = true
    @AppStorage(SpatialSound.outputKey) private var choice: SpatialSound.Output = .automatic
    @ObservedObject private var outputs = SoundOutputs.shared
    @State private var showing = false

    var body: some View {
        let compatible = outputs.current?.fit(choice).compatible ?? true
        Button { showing.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: enabled ? "speaker.wave.3.fill" : "speaker.slash")
                Text(enabled ? "3D sound on" : "3D sound off").bold()
                if let current = outputs.current {
                    Image(systemName: compatible ? "checkmark.circle.fill" : "xmark.circle.fill")
                    Text(current.name).lineLimit(1)
                }
            }
            .font(.caption2)
            .foregroundStyle(!enabled ? Color.secondary : compatible ? Color.green : Color.orange)
        }
        .buttonStyle(.plain)
        .help(Self.summary(enabled: enabled, output: outputs.current, choice: choice) + " Click for 3D Surround Sound.")
        .popover(isPresented: $showing, arrowEdge: .trailing) {
            SurroundSoundPanel().padding(16).frame(width: 400)
        }
    }

    static func summary(enabled: Bool, output: SoundOutput?, choice: SpatialSound.Output) -> String {
        let state = "3D surround sound \(enabled ? "on" : "off") for every game."
        guard let output else { return state + " No sound output found." }
        let fit = output.fit(choice)
        return state + " \(output.name): \(fit.compatible ? "compatible" : "not compatible") — \(output.headline(choice).lowercasedFirst)."
    }
}

/// The menu bar menu's switch, with the output's verdict under it.
struct SurroundSoundMenuItems: View {
    @AppStorage(SpatialSound.enabledKey) private var enabled = true
    @AppStorage(SpatialSound.outputKey) private var choice: SpatialSound.Output = .automatic
    @ObservedObject private var outputs = SoundOutputs.shared

    var body: some View {
        Toggle("3D Surround Sound", isOn: Binding(get: { enabled }, set: { SpatialSound.setEnabled($0) }))
        if let current = outputs.current {
            let fit = current.fit(choice)
            Text("\(fit.compatible ? "✓ Compatible" : "✗ Not compatible"): \(current.name) — \(current.headline(choice).lowercasedFirst)")
        }
    }
}

/// The scan of the output playing now (Core/SoundCheck), run by itself when the panel opens and
/// whenever the output changes, and the tests that play through it.
struct SoundScanSection: View {
    let output: SoundOutput
    @ObservedObject private var check = SoundCheck.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Surround check").font(.callout.bold())
                if check.scanning { ProgressView().controlSize(.small) }
                Spacer()
                Button {
                    check.scan(output)
                } label: {
                    Label("Scan", systemImage: "waveform.badge.magnifyingglass")
                }
                .disabled(check.scanning)
                .help("Run Anvil's own game sound against this output — silently — and see what it can do")
            }
            if let scan = check.scan, scan.deviceID == output.id {
                let verdict = scan.verdict
                Label(verdict.text, systemImage: verdict.yes ? "checkmark.seal.fill" : "xmark.seal.fill")
                    .font(.callout.bold())
                    .foregroundStyle(verdict.yes ? Color.green : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(scan.findings) { finding in
                    FindingRow(finding: finding)
                }
            } else if !check.scanning {
                Text("Scan to see what this output can do for surround, using the same sound engine games use here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let problem = check.problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            Divider()
            HStack(spacing: 8) {
                Text("Listen").font(.callout.bold())
                Spacer()
                if check.testing != nil {
                    Button("Stop") { check.stop() }
                } else {
                    Button { check.play(.surround, through: output) } label: { Label("Surround Test", systemImage: "dot.radiowaves.left.and.right") }
                        .help("A burst of sound from each speaker of a 7.1 mix in turn, around you — through 3D sound, as a game plays")
                    Button { check.play(.stereo, through: output) } label: { Label("Stereo Game Test", systemImage: "music.note") }
                        .help("A stereo game's sound through Anvil Surround: a voice in the middle, a room, then left and right")
                }
            }
            .controlSize(.small)
            if let test = check.testing {
                SpeakerMap(test: test, part: check.part)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: "\(output.id)-\(output.channels)-\(output.dataSource)") {
            check.forget(unless: output)
            check.scan(output)
        }
    }
}

struct FindingRow: View {
    let finding: SoundScan.Finding

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.title).font(.caption.bold())
                Text(finding.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if finding.opensAudioMIDISetup {
                    Button("Open Audio MIDI Setup") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var symbol: String {
        switch finding.level {
        case .good: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .bad: "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch finding.level {
        case .good: .green
        case .info: .secondary
        case .warning: .orange
        case .bad: .red
        }
    }
}

/// Where the test sound should be coming from now: seven speakers around the listener, the
/// playing one lit — and what to listen for.
struct SpeakerMap: View {
    let test: SoundCheck.Test
    let part: String?

    private static let spots: [(name: String, degrees: Double)] = [
        ("front left", -30), ("centre", 0), ("front right", 30), ("side right", 90),
        ("back right", 150), ("back left", -150), ("side left", -90),
    ]

    private var lit: Set<String> {
        guard let part else { return [] }
        if test == .surround { return [part] }
        switch part {
        case "voice in the middle": return ["centre"]
        case "room": return ["side left", "side right", "back left", "back right"]
        case "left": return ["front left"]
        case "right": return ["front right"]
        default: return []
        }
    }

    private var listenFor: String {
        guard let part else { return "Starting…" }
        if test == .surround { return "Now: the \(part) speaker — the sound should come from there." }
        switch part {
        case "voice in the middle": return "Now: a voice in the middle of a stereo mix — from straight ahead (the centre)."
        case "room": return "Now: a stereo room — all around you, beside and behind."
        case "left": return "Now: a sound panned left — from ahead on the left."
        case "right": return "Now: a sound panned right — from ahead on the right."
        default: return "Now: \(part)"
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().strokeBorder(.quaternary, lineWidth: 1).frame(width: 150, height: 150)
                Image(systemName: "person.fill").font(.system(size: 22)).foregroundStyle(.secondary)
                Image(systemName: "arrowtriangle.up.fill").font(.system(size: 7)).foregroundStyle(.tertiary).offset(y: -20)
                ForEach(Self.spots, id: \.name) { spot in
                    let on = lit.contains(spot.name)
                    let r = 75.0, a = spot.degrees * .pi / 180
                    Image(systemName: on ? "speaker.wave.2.circle.fill" : "speaker.circle")
                        .font(.system(size: on ? 22 : 16))
                        .foregroundStyle(on ? Color.accentColor : Color.secondary)
                        .offset(x: r * sin(a), y: -r * cos(a))
                        .animation(.easeOut(duration: 0.15), value: on)
                }
            }
            .frame(width: 180, height: 180)
            Text(listenFor).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.vertical, 4)
    }
}
