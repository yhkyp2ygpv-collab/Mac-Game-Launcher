// Removing an unused upscaler injection, on copies of real game folders.
//
// An injection repeated over an earlier one backs up the earlier one's files; only the
// file itself says whether a backup is the game's. Copy each game's DLLs and its
// .anvil-backup (cp -p keeps the dates the check relies on) into <dir>/LEGO and <dir>/Cat,
// with an empty file named after each executable, then:
//
//   swiftc -Onone -parse-as-library -module-name Anvil $(find Sources/Anvil/Core -name '*.swift') \
//     Native/Tools/tests/InjectionRemovalTest.swift -o $TMPDIR/InjectionRemovalTest
//   CFFIXED_USER_HOME=<dir>/home HOME=<dir>/home $TMPDIR/InjectionRemovalTest <dir>
import Foundation
@main struct InjectionHarness {
    @MainActor static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        var failures = 0
        func check(_ c: Bool, _ m: String) { if !c { failures += 1; print("FAIL: \(m)") } else { print("ok: \(m)") } }
        let fm = FileManager.default
        for (dir, exe) in [("LEGO", "LEGOSTARWARSSKYWALKERSAGA_DX11.exe"), ("Cat", "Cat Quest II.exe")] {
            let folder = root.appendingPathComponent(dir)
            let game = Game(title: dir, executablePath: folder.appendingPathComponent(exe).path, containerID: UUID())
            var config = UpscalerConfig(); config.mode = .fsr1; config.forceInjection = true
            let before = try! fm.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".dll") }.sorted()
            guard let left = UpscalerManager.unusedInjection(for: game, config: config) else { check(false, "\(dir): leftovers found"); continue }
            print("\(dir): \(left.files) injected files present; own replaced: \(left.replacedOwn)")
            // An upscaler that uses the payload is not "unused".
            var fsr3 = config; fsr3.mode = .fsr3Native
            check(UpscalerManager.unusedInjection(for: game, config: fsr3) == nil, "\(dir): an FSR 3 setup keeps its payload")
            try! UpscalerManager.shared.removeInjection(fromGameAt: game.executablePath)
            let after = try! fm.contentsOfDirectory(atPath: folder.path).sorted()
            print("\(dir): before \(before)\n\(dir): after  \(after)")
            check(!fm.fileExists(atPath: folder.appendingPathComponent(".anvil-backup").path), "\(dir): backup folder gone")
            check(UpscalerManager.unusedInjection(for: game, config: config) == nil, "\(dir): nothing left afterwards")
            if dir == "LEGO" {
                check(left.replacedOwn == ["amd_ags_x64.dll"], "LEGO: its own amd_ags_x64.dll recognised")
                let ags = try? fm.attributesOfItem(atPath: folder.appendingPathComponent("amd_ags_x64.dll").path)
                check((ags?[.size] as? Int) == 42496, "LEGO: the game's own amd_ags_x64.dll (42,496 bytes) is back")
                for keep in ["bink2w64.dll", "d3dcompiler_47.dll", "eossdk-win64-shipping.dll", "oo2core_8_win64.dll"] {
                    check(fm.fileExists(atPath: folder.appendingPathComponent(keep).path), "LEGO: its own \(keep) untouched")
                }
                check(after.filter { $0.hasSuffix(".dll") }.count == 5, "LEGO: exactly the game's five DLLs remain")
            } else {
                check(left.replacedOwn.isEmpty, "Cat: none of the backups is the game's (all the SDK's)")
                check(after.filter { $0.hasSuffix(".dll") } == ["Galaxy64.dll", "GalaxyCSharpGlue.dll", "UnityPlayer.dll"], "Cat: only its own three DLLs remain")
            }
        }
        print(failures == 0 ? "injection removal: all checks passed" : "\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
