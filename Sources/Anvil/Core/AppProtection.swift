import AppKit
import CryptoKit
import Security

/// Who made Anvil, and the checks that it is still the copy that was shipped.
///
/// Every edition carries Contents/Resources/Ownership.txt, naming Jay Chirag Patel of
/// Santa Clara as Anvil's maker. Its SHA-256 is compiled into Anvil itself, so the file
/// can't be changed, moved or deleted without Anvil refusing to start — and changing the
/// expected value means changing the program.
///
/// The public edition checks its own code signature every time it starts. The signature
/// covers every file in Anvil.app — the program, its libraries, its shaders, its icons —
/// so a file that was changed, removed or added makes the check fail, and Anvil then
/// refuses to start, saying why. Nothing is deleted or broken by it: a fresh copy from the
/// .dmg starts again. The private edition skips the check, so it can be rebuilt freely.
///
/// The public edition is also signed with the hardened runtime and Anvil's entitlements
/// (Resources/Anvil.entitlements), which the kernel enforces for the life of the process:
/// no debugger can attach to it, no library it wasn't built with can be loaded into it, and
/// no DYLD_* variable can pull foreign code in. So the shared copy is closed while it runs,
/// not only on disk. That is as far as macOS allows — a program's own instructions can't be
/// encrypted at rest and still execute, so what protects the compiled code is that it is
/// stripped, signed, tamper-evident and closed to inspection, which it now is.
enum AppProtection {
    static let author = "Jay Chirag Patel"
    static let place = "Santa Clara, California"
    static let credit = "Made by \(author) · \(place)"
    static let copyright = "© 2026 \(author) · Anvil Source License"
    /// Anvil's source and licence (0.58.1: published): free to use, change and share with credit; selling needs permission.
    static let sourceURL = URL(string: "https://github.com/yhkyp2ygpv-collab/Mac-Game-Launcher")!
    static let licenceSummary = "Free to use, change and share — credit \(author) as a collaborator. Selling it or publishing it for money needs written permission first."
    /// The quiet line in the sidebar.
    static let shortCredit = "Made by \(author) · Santa Clara"

    static let ownershipFileName = "Ownership.txt"
    /// SHA-256 of Resources/Ownership.txt exactly as shipped. OwnershipTest checks the two
    /// agree, so a deliberate edit to the file must come with this one.
    static let ownershipDigest = "c987add1080e862aaa057e0f0e3a7b3e166d8c97915b158cb6202869e10a144a"

    /// Nil when the ownership file is there and unchanged; otherwise what is wrong.
    static func verifyOwnership(bundle: URL = Bundle.main.bundleURL) -> String? {
        let file = bundle.appendingPathComponent("Contents/Resources/\(ownershipFileName)")
        guard let data = try? Data(contentsOf: file) else { return "Anvil's ownership file is missing." }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == ownershipDigest else { return "Anvil's ownership file has been changed." }
        guard let text = String(data: data, encoding: .utf8), text.contains(author), text.contains("Santa Clara") else {
            return "Anvil's ownership file has been changed."
        }
        return nil
    }

    static var isPublicEdition: Bool { BuildInfo.edition == "public" }
    static var editionName: String { isPublicEdition ? "Public edition" : "Private edition" }

    enum Failure: Error {
        case unreadable(OSStatus)
        case modified(OSStatus)
    }

    /// The signing requirement: Jay's Developer ID team when the edition was signed with
    /// one — no one else can sign as that — else Anvil's own identifier.
    static var requirementText: String {
        if let team = BuildInfo.signingTeam {
            return "identifier \"dev.anvil.launcher\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        }
        return "identifier \"dev.anvil.launcher\""
    }

    /// Nil when the bundle on disk is exactly what was signed.
    static func verify(bundle: URL = Bundle.main.bundleURL) -> Failure? {
        var staticCode: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(bundle as CFURL, [], &staticCode)
        guard created == errSecSuccess, let code = staticCode else { return .unreadable(created) }
        var requirement: SecRequirement?
        SecRequirementCreateWithString(requirementText as CFString, [], &requirement)
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, nil)
        return status == errSecSuccess ? nil : .modified(status)
    }

    /// At start, before anything else. Every edition stops here if its ownership file was
    /// changed or removed; the public edition also if anything else inside it was.
    static func checkAtLaunch() {
        if let problem = verifyOwnership() {
            AnvilLog.write("protection: \(problem) — not starting")
            refuse(problem, detail: "Anvil names its maker in a file it checks at every start, and that file doesn't match.")
        }
        guard isPublicEdition, let failure = verify() else { return }
        let code: OSStatus
        switch failure { case .unreadable(let s), .modified(let s): code = s }
        AnvilLog.write("protection: this copy of Anvil doesn't match its signature (\(code)) — not starting")
        refuse("This copy of Anvil has been changed",
               detail: "Files inside Anvil were changed, removed or added after it was made. (error \(code))")
    }

    /// Say why, and quit. Nothing on the Mac is touched: a fresh copy starts normally.
    private static func refuse(_ title: String, detail: String) -> Never {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = """
            \(detail) Anvil won't start until it is installed again from the original .dmg. \
            Your games, saves and settings are untouched.

            \(credit)
            """
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        exit(1)
    }
}
