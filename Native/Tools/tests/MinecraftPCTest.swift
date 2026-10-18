import Foundation

// 0.56: Bedrock's PC version in Windows through VMware Fusion (MinecraftPC) — the settings file read and written as Fusion
// keeps it, what a Mac sets for Minecraft, finding the Windows machines and whether one is put away, what the setup in
// Windows reports back, and the setup itself checked as text (no PowerShell on a Mac): plain ASCII for Windows PowerShell 5,
// everything Minecraft needs kept, Windows' security never touched. Args: the setup script, the shared-folder files' folder.
// Run with CFFIXED_USER_HOME set to a scratch folder.
@main struct MinecraftPCHarness {
    static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        var failures = 0
        func check(_ c: Bool, _ m: String) { if !c { failures += 1; print("FAIL: \(m)") } }
        guard ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil, RuntimeManager.support.path.contains("/home/") else {
            print("FAIL: run with CFFIXED_USER_HOME, not on the real library"); exit(1)
        }
        let args = CommandLine.arguments
        guard args.count >= 3 else { print("FAIL: usage: MinecraftPCTest <anvil-minecraft-setup.ps1> <MinecraftPC resources folder>"); exit(2) }

        // 1. A settings file as Fusion writes it: kept line for line, keys in any case, values set and added.
        let original = """
        .encoding = "UTF-8"
        config.version = "8"
        virtualHW.version = "21"
        displayName = "Windows 11"
        guestOS = "arm-windows11-64"
        NumVCPUs = "2"
        memsize = "4096"
        # a comment = "not a key"
        nvme0:0.fileName = "Virtual Disk.vmdk"
        """
        var file = VMXFile(text: original)
        check(file["guestOS"] == "arm-windows11-64" && file["GUESTOS"] == "arm-windows11-64", "read, any case")
        check(file["numvcpus"] == "2", "a key written in its own case")
        check(file["# a comment"] == nil && file["a comment"] == nil, "a comment isn't a key")
        file["numvcpus"] = "6"
        file["mks.enable3d"] = "TRUE"
        check(file.text.contains("NumVCPUs = \"6\"") && !file.text.contains("numvcpus = "), "set in place, its own case kept")
        check(file.text.hasSuffix("mks.enable3d = \"TRUE\"\n"), "a new one added at the end")
        check(file.text.contains("# a comment = \"not a key\"") && file.text.contains("nvme0:0.fileName = \"Virtual Disk.vmdk\""), "the rest as it was")
        check(VMXFile(text: file.text).text == file.text, "read back the same")
        file["memsize"] = nil
        check(file["memsize"] == nil && !file.text.contains("memsize"), "a key taken out")

        // 2. What a Mac sets: this M4 (10 cores, 24 GB), a smaller one, and a pad to plug in to Windows.
        let shared = URL(fileURLWithPath: "/tmp/anvil-shared")
        let m4 = MinecraftPC.tuning(cores: 10, memoryGB: 24, shared: shared, controller: (0x20d6, 0xa713, "PowerA pad"))
        func value(_ s: [MinecraftPC.Setting], _ k: String) -> String? { s.first { $0.key == k }?.value }
        check(value(m4, "numvcpus") == "6" && value(m4, "cpuid.coresPerSocket") == "6", "M4: 6 cores (\(value(m4, "numvcpus") ?? "-"))")
        check(value(m4, "memsize") == "8192", "M4: 8 GB of memory (\(value(m4, "memsize") ?? "-"))")
        check(value(m4, "svga.graphicsMemoryKB") == "4194304" && value(m4, "mks.enable3d") == "TRUE", "M4: 3D, 4 GB of graphics memory")
        check(value(m4, "gui.viewModeAtPowerOn") == "fullscreen" && value(m4, "gui.lastPoweredViewMode") == "fullscreen", "full screen")
        check(value(m4, "sharedFolder0.hostPath") == shared.path && value(m4, "sharedFolder0.guestName") == "Anvil"
              && value(m4, "sharedFolder0.writeAccess") == "TRUE" && value(m4, "isolation.tools.hgfs.disable") == "FALSE", "the shared folder")
        check(value(m4, "usb.autoConnect.device0") == "0x20d6:0xa713", "the pad, in Broadcom's form (\(value(m4, "usb.autoConnect.device0") ?? "-"))")
        check(value(m4, MinecraftPC.tunedKey) == "\(MinecraftPC.tuningVersion)", "marked as Anvil's")
        let small = MinecraftPC.tuning(cores: 8, memoryGB: 8, shared: shared, controller: nil)
        check(value(small, "numvcpus") == "5" && value(small, "memsize") == "4096" && value(small, "svga.graphicsMemoryKB") == "1048576",
              "8 GB Mac: 5 cores, 4 GB (Windows 11's least), 1 GB graphics")
        check(value(small, "usb.autoConnect.device0") == nil, "no pad: none plugged in")
        let big = MinecraftPC.tuning(cores: 16, memoryGB: 64, shared: shared, controller: nil)
        check(value(big, "numvcpus") == "8" && value(big, "memsize") == "8192", "a big Mac: at most 8 cores and 8 GB")

        // 3. Finding the Windows machines, and whether one is put away.
        let scratch = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!)
        let folder = scratch.appendingPathComponent("Virtual Machines.localized", isDirectory: true)
        let fm = FileManager.default
        func machine(_ name: String, guest: String) -> URL {
            let bundle = folder.appendingPathComponent("\(name).vmwarevm", isDirectory: true)
            try? fm.createDirectory(at: bundle, withIntermediateDirectories: true)
            let vmx = bundle.appendingPathComponent("\(name).vmx")
            try? Data("displayName = \"\(name)\"\nguestOS = \"\(guest)\"\n".utf8).write(to: vmx)
            return vmx
        }
        let windows = machine("Windows 11", guest: "arm-windows11-64")
        _ = machine("Ubuntu", guest: "arm-ubuntu-64")
        let found = MinecraftPC.findMachines(in: MinecraftPC.machineFolders(home: scratch))
        check(found.count == 1 && found.first?.name == "Windows 11" && found.first?.vmx.resolvingSymlinksInPath().path == windows.resolvingSymlinksInPath().path,
              "the Windows machine found, the Linux one not: \(found.map(\.name))")
        if let w = found.first {
            check(!MinecraftPC.isSuspended(w), "not put away")
            try? Data().write(to: w.bundle.appendingPathComponent("Windows 11-a1b2c3.vmss"))
            check(MinecraftPC.isSuspended(w), "put away: its .vmss beside it")
        }
        let list = "Total running VMs: 1\n\(windows.path)\n"
        check(MinecraftPC.running(fromList: list).contains(windows.standardizedFileURL.path), "running, from vmrun list")
        check(MinecraftPC.running(fromList: "Total running VMs: 0\n").isEmpty, "none running")

        // 4. What the setup in Windows reports back, as Windows PowerShell 5 writes it: UTF-8 with a byte-order mark.
        try? fm.createDirectory(at: MinecraftPC.sharedFolder, withIntermediateDirectories: true)
        let json = """
        {
            "version":  1,
            "finished":  "2026-10-17T12:00:00",
            "undone":  false,
            "windows":  "Microsoft Windows 11 Pro 10.0.26100",
            "arch":  "ARM64",
            "removed":  ["Microsoft.BingNews", "Clipchamp.Clipchamp"],
            "launcher":  "installed",
            "minecraft":  "Microsoft.4297127D64EC6 1.2.3.0, Microsoft.MinecraftUWP 1.26.52.0",
            "startsMinecraft":  true,
            "graphics":  ["VMware SVGA 3D"],
            "controllers":  ["HID-compliant game controller (OK)"],
            "problems":  []
        }
        """
        try? (Data([0xEF, 0xBB, 0xBF]) + Data(json.utf8)).write(to: MinecraftPC.reportURL)
        let report = MinecraftPC.readReport()
        check(report?.finished == "2026-10-17T12:00:00" && report?.removed?.count == 2 && report?.startsMinecraft == true
              && report?.controllers == ["HID-compliant game controller (OK)"] && report?.minecraft?.contains("MinecraftUWP") == true,
              "the report read, byte-order mark and all: \(String(describing: report))")

        // 5. The setup itself, as text.
        let ps1 = (try? String(contentsOf: URL(fileURLWithPath: args[1]), encoding: .utf8)) ?? ""
        check(!ps1.isEmpty, "the setup script read")
        check(ps1.unicodeScalars.allSatisfy { $0.value == 9 || $0.value == 10 || $0.value == 13 || (32...126).contains($0.value) },
              "plain ASCII: Windows PowerShell 5 reads a file without a byte-order mark as the system's code page")
        // The code alone: its comments (the block at the top, and whole-line ones) say "it's" and "Windows'".
        var code = ps1
        if let a = code.range(of: "<#"), let b = code.range(of: "#>") { code.removeSubrange(a.lowerBound..<b.upperBound) }
        code = code.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: "\n")
        func count(_ c: Character) -> Int { code.filter { $0 == c }.count }
        check(count("{") == count("}") && count("(") == count(")") && count("[") == count("]"), "brackets balanced")
        check(count("'") % 2 == 0 && count("\"") % 2 == 0, "quotes paired")
        for kept in ["WindowsStore", "GamingApp", "GamingServices", "XboxIdentityProvider", "DesktopAppInstaller", "Minecraft", "SecHealthUI"] {
            check(ps1.contains(kept), "kept: \(kept)")
        }
        let keepLine = ps1.components(separatedBy: "\n").first { $0.hasPrefix("$keep") } ?? ""
        check(!keepLine.isEmpty, "the keep list")
        for never in ["Set-MpPreference", "DisableAntiSpyware", "DisableRealtimeMonitoring", "wuauserv", "advfirewall", "EnableLUA",
                      "Remove-AppxPackage -Package *", "Get-AppxPackage -AllUsers | Remove", "bcdedit", "Invoke-WebRequest", "iwr ", "curl "] {
            check(!ps1.contains(never), "never: \(never)")
        }
        check(ps1.contains("Read-Host 'Go ahead?") && ps1.range(of: "Read-Host 'Go ahead?")!.lowerBound < ps1.range(of: "Remove-AppxPackage")!.lowerBound,
              "asks before it takes anything out")
        check(ps1.contains("-Verb RunAs") && ps1.contains("IsInRole"), "as administrator, and checks it is")
        check(ps1.contains("9PGW18NPBZV5") && ps1.contains("--source msstore"), "the Minecraft Launcher from the Microsoft Store")
        check(ps1.contains("status.json") && ps1.contains("-Encoding UTF8"), "reports back")
        // Every extra it may take out is outside what it keeps.
        let extrasBlock = ps1.components(separatedBy: "$extras = @(").dropFirst().first?.components(separatedBy: ")").first ?? ""
        let extras = extrasBlock.components(separatedBy: "'").enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        check(extras.count >= 30, "the extras listed (\(extras.count))")
        for e in extras {
            let bare = e.replacingOccurrences(of: "*", with: "")
            for k in ["WindowsStore", "StorePurchaseApp", "GamingApp", "GamingServices", "XboxIdentityProvider", "DesktopAppInstaller", "Minecraft", "SecHealthUI", "VCLibs"] {
                check(!bare.contains(k), "\(e) isn't something kept (\(k))")
            }
        }
        let resources = URL(fileURLWithPath: args[2])
        let cmd = (try? Data(contentsOf: resources.appendingPathComponent("Set up Minecraft.cmd"))) ?? Data()
        check(!cmd.isEmpty && cmd.contains(Data("\r\n".utf8)), "the .cmd with Windows line ends")
        check(String(decoding: cmd, as: UTF8.self).contains("anvil-minecraft-setup.ps1\" -Undo"), "the .cmd's undo")
        check(fm.fileExists(atPath: resources.appendingPathComponent("Read me.txt").path), "the read me")

        if failures > 0 { print("\(failures) failures"); exit(1) }
        print("minecraft pc: all checks passed")
    }
}
