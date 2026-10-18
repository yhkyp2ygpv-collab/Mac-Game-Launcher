// 0.44.0: the 3D Surround Sound panel's verdict on each kind of output — held to the same table
// (sound_output_cases.txt) as libanvil's own choice in audio_fold_test.mm — what it says and
// suggests there, and the Mac's real outputs read the way the panel reads them.
//
//   swiftc -Onone -parse-as-library -module-name Anvil $(find Sources/Anvil -name '*.swift' ! -name AnvilApp.swift) \
//     Native/Tools/tests/SoundOutputTest.swift -o $T/SoundOutputTest
//   $T/SoundOutputTest            (from the Anvil folder; the Mac's own outputs only outside the sandbox)
import CoreAudio
import Foundation

@main struct SoundOutputHarness {
    @MainActor static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        var failures = 0
        func check(_ c: Bool, _ m: String) { if !c { failures += 1; print("FAIL: \(m)") } }

        // 1. The table both sides agree on.
        let connections: [String: UInt32] = [
            "builtin": kAudioDeviceTransportTypeBuiltIn, "bluetooth": kAudioDeviceTransportTypeBluetooth,
            "bluetoothLE": kAudioDeviceTransportTypeBluetoothLE, "usb": kAudioDeviceTransportTypeUSB,
            "hdmi": kAudioDeviceTransportTypeHDMI, "displayport": kAudioDeviceTransportTypeDisplayPort,
            "airplay": kAudioDeviceTransportTypeAirPlay, "thunderbolt": kAudioDeviceTransportTypeThunderbolt,
            "virtual": kAudioDeviceTransportTypeVirtual, "aggregate": kAudioDeviceTransportTypeAggregate,
        ]
        let choices: [String: SpatialSound.Output] = ["auto": .automatic, "headphones": .headphones, "speakers": .speakers]
        guard let table = try? String(contentsOfFile: "Native/Tools/tests/sound_output_cases.txt", encoding: .utf8) else {
            print("FAIL: sound_output_cases.txt not found (run from the Anvil folder)"); exit(1)
        }
        var rows: [(SoundOutput, SpatialSound.Output)] = []
        for line in table.split(separator: "\n") where !line.hasPrefix("#") && !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count == 7, let transport = connections[f[0]], let channels = Int(f[1]), let choice = choices[f[3]],
                  let listener = SoundOutput.Listener(rawValue: f[5]), let fit = SoundOutput.Fit(rawValue: f[6]) else {
                check(false, "table row not understood: \(line)"); continue
            }
            let output = SoundOutput(id: AudioDeviceID(rows.count + 1), name: f[4], transport: transport, channels: channels,
                                     dataSource: f[2] == "-" ? 0 : fourCC(f[2]), isDefault: true)
            check(output.listener(choice) == listener, "\(f[4]) (\(f[0]), \(channels) ch, \(f[3])): the panel hears \(output.listener(choice)), the table says \(listener)")
            check(output.fit(choice) == fit, "\(f[4]) (\(f[0]), \(channels) ch, \(f[3])): the panel says \(output.fit(choice)), the table says \(fit)")
            rows.append((output, choice))
        }
        check(rows.count >= 25, "only \(rows.count) rows read from the table")
        print("table: \(rows.count) rows agree with the panel")

        // 2. What the panel says for each: a headline and a reason, a symbol, the verdict in the launch log.
        for (output, choice) in rows {
            let fit = output.fit(choice)
            check(!output.headline(choice).isEmpty && output.detail(choice).count > 40, "\(output.name): says too little")
            check(!output.symbol.isEmpty, "\(output.name): no symbol")
            check(output.launchLine(choice).contains(fit.compatible ? "— compatible" : "— not compatible"),
                  "\(output.name): launch line \(output.launchLine(choice))")
        }
        func row(_ name: String, _ channels: Int) -> (SoundOutput, SpatialSound.Output)? {
            rows.first { $0.0.name == name && $0.0.channels == channels }
        }
        if let (tv, c) = row("LG TV", 2) {
            check(tv.hint(c)?.opensAudioMIDISetup == true, "a TV on HDMI in stereo: Audio MIDI Setup suggested for its surround speakers")
            check(tv.headline(c) == "Virtual surround on two speakers", "TV headline: \(tv.headline(c))")
        } else { check(false, "no LG TV row") }
        if let (receiver, c) = row("Denon AVR", 6) {
            check(receiver.hint(c) == nil, "a 5.1 receiver needs no suggestion")
            check(receiver.headline(c) == "Real 5.1 surround", "receiver headline: \(receiver.headline(c))")
        } else { check(false, "no Denon row") }
        if let (pods, c) = row("Jay’s AirPods Pro", 2), let (call, cc) = row("Jay’s AirPods Pro", 1) {
            check(pods.hint(c)?.text.contains("Follow head movement") == true, "AirPods: head tracking suggested")
            check(pods.symbol == "airpodspro", "AirPods Pro symbol: \(pods.symbol)")
            check(call.headline(cc).contains("headset mode") && call.detail(cc).contains("microphone"),
                  "AirPods in call mode: told why it's one channel (\(call.headline(cc)))")
            check(!call.fit(cc).compatible, "AirPods in call mode: not compatible")
        } else { check(false, "no AirPods rows") }
        if let (air, c) = row("Living Room", 2) {
            check(air.hint(c)?.text.contains("late") == true, "AirPlay: its delay mentioned")
        } else { check(false, "no AirPlay row") }
        if let (speakers, c) = row("MacBook Pro Speakers", 2), c == .automatic {
            check(speakers.headline(c) == "Virtual surround on the Mac's speakers", "MacBook speakers headline: \(speakers.headline(c))")
            check(speakers.connection == "Built in" && speakers.subtitle == "Built in · stereo", "MacBook speakers subtitle: \(speakers.subtitle)")
            check(speakers.hint(c) == nil, "MacBook speakers: nothing to suggest")
        } else { check(false, "no MacBook speakers row") }
        if let (jack, _) = row("External Headphones", 2) {
            check(jack.connection == "Headphone jack", "External Headphones: \(jack.connection)")
        }
        if let (mono, c) = row("Mac mini Speakers", 1) {
            check(mono.headline(c) == "One speaker — no surround", "mono headline: \(mono.headline(c))")
        } else { check(false, "no mono row") }
        if let (wide, c) = row("Scarlett 18i20", 18) {
            check(wide.headline(c).hasPrefix("18 channels"), "18-channel interface: \(wide.headline(c))")
        } else { check(false, "no interface row") }
        if let (chosen, c) = rows.first(where: { $0.0.name == "Audioengine 2+" && $0.1 == .headphones }) {
            check(chosen.detail(c).contains("as you chose"), "a listener chosen by the player is said so")
        }

        // 3. Words in the panel's sentences.
        check("Real 5.1 surround".lowercasedFirst == "real 5.1 surround", "lowercasedFirst")
        check("AirPods".lowercasedFirst == "AirPods" && "3D sound".lowercasedFirst == "3D sound", "lowercasedFirst leaves names")

        // 4. The surround check's report (SoundCheck), from what anvil-soundcheck says.
        func scan(_ text: String) -> SoundScan { SoundScan(lines: text.split(separator: "\n").map(String.init)) }
        let base = """
        device.id=76
        device.alive=1
        device.hogPid=-1
        game71.spatial=1
        game71.rendered=1
        game71.cpuMsPerSecond=2.6
        gameStereo.spatial=1
        gameStereo.upmix=stereo
        gameStereo.bed=8
        done=1
        """
        let speakers = scan(base + "\ndevice.name=MacBook Pro Speakers\ndevice.channels=2\ndevice.mostChannels=2\nengine.toldChannels=8\ngame71.listener=builtInSpeakers\ndevice.latencyMs=27.3")
        check(speakers.verdict.yes && speakers.verdict.text.contains("virtual surround"), "MacBook speakers: \(speakers.verdict.text)")
        check(speakers.findings.contains { $0.id == "engine" && $0.level == .good }, "MacBook speakers: the engine ran")
        check(speakers.findings.contains { $0.id == "stereo" && $0.title.contains("7.1") }, "MacBook speakers: stereo games made 7.1")
        check(speakers.findings.contains { $0.id == "latency" && $0.level == .good }, "MacBook speakers: quick")
        let tv = scan(base + "\ndevice.name=LG TV\ndevice.channels=2\ndevice.mostChannels=8\ndevice.widths=2,8\nengine.toldChannels=8\ngame71.listener=externalSpeakers\ndevice.latencyMs=40")
        check(tv.verdict.yes && tv.verdict.text.contains("real 7.1"), "a TV set to stereo that takes 8: \(tv.verdict.text)")
        check(tv.findings.contains { $0.id == "channels" && $0.level == .warning && $0.opensAudioMIDISetup }, "…pointed to Audio MIDI Setup")
        let receiver = scan(base + "\ndevice.name=Denon\ndevice.channels=6\ndevice.mostChannels=8\ndevice.layout=L R C LFE Ls Rs\ngame71.listener=surround\ngameStereo.bed=6")
        check(receiver.verdict.text.contains("real 5.1"), "a 5.1 receiver: \(receiver.verdict.text)")
        check(receiver.findings.contains { $0.id == "stereo" && $0.title.contains("5.1") }, "a 5.1 receiver: stereo games made 5.1")
        let call = scan(base.replacingOccurrences(of: "game71.spatial=1", with: "game71.spatial=0")
                        + "\ndevice.name=AirPods Pro\ndevice.channels=1\ngame71.failed=left as the game plays it")
        check(!call.verdict.yes && call.findings.contains { $0.id == "channels" && $0.level == .bad }, "AirPods in call mode: no (\(call.verdict.text))")
        let late = scan(base + "\ndevice.name=AirPods Pro\ndevice.channels=2\ngame71.listener=headphones\ngame71.personalized=1\ndevice.latencyMs=182")
        check(late.verdict.text.contains("3D surround on headphones"), "AirPods: \(late.verdict.text)")
        check(late.findings.contains { $0.id == "latency" && $0.level == .warning }, "AirPods: 182 ms is said to be late")
        check(late.findings.contains { $0.id == "personal" }, "AirPods: personalized spatial audio said")
        let failed = scan("failed=no sound output\ndone=1")
        check(!failed.verdict.yes && failed.findings.first?.level == .bad, "no output: \(failed.verdict.text)")
        // anvil-soundcheck's own output on this Mac, when given (kept from a run in a terminal).
        for path in CommandLine.arguments.dropFirst() {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { check(false, "can't read \(path)"); continue }
            let real = scan(text)
            check(real.complete && real.surroundWorks, "\((path as NSString).lastPathComponent): \(real.name) — \(real.verdict.text)")
            print("scan \((path as NSString).lastPathComponent): \(real.name) — \(real.verdict.text); " + real.findings.map(\.title).joined(separator: "; "))
        }

        // 5. This Mac's outputs, read as the panel reads them (CoreAudio isn't reachable in the sandbox).
        let outputs = SoundOutput.all()
        if outputs.isEmpty {
            print("this Mac: no outputs readable here (sandboxed)")
        } else {
            check(outputs.filter(\.isDefault).count == 1 && outputs[0].isDefault, "the output playing now comes first, once")
            check(SoundOutput.current()?.id == outputs[0].id, "current() is the first of all()")
            for o in outputs {
                print("this Mac: \(o.isDefault ? "▶" : " ") \(o.launchLine(SpatialSound.output))")
            }
            let watched = SoundOutputs.shared
            check(watched.current?.id == outputs[0].id, "the watcher sees the same output")
        }

        if failures > 0 { print("\(failures) failures"); exit(1) }
        print("sound outputs: all checks passed")
    }
}
