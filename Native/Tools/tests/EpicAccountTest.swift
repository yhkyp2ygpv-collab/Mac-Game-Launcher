// Anvil's own Epic support: reading the code Epic's sign-in page shows, and installing
// legendary only when it matches the SHA-256 GitHub publishes for it.
//
// Fetch the release description and the build once (any HTTP client):
//   curl -L -H 'Accept: application/vnd.github+json' https://api.github.com/repos/legendary-gl/legendary/releases/latest -o <dir>/release.json
//   curl -L -o <dir>/legendary_macOS_arm64 <browser_download_url of legendary_macOS_arm64>
//   swiftc -Onone -parse-as-library -module-name Anvil $(find Sources/Anvil/Core -name '*.swift') \
//     Native/Tools/tests/EpicAccountTest.swift -o $TMPDIR/EpicAccountTest
//   CFFIXED_USER_HOME=<dir>/home HOME=<dir>/home $TMPDIR/EpicAccountTest <dir>
// The last check runs the installed legendary; inside a sandbox that denies System V
// semaphores PyInstaller's single-file builds can't start, which is the sandbox's doing.
import Foundation
@main struct EpicHarness {
    static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        guard RuntimeManager.support.path.contains("/home/Library/Application Support/Anvil") else { print("refusing: not in the throwaway home"); exit(2) }
        var failures = 0
        func check(_ c: Bool, _ m: String) { if !c { failures += 1; print("FAIL: \(m)") } else { print("ok: \(m)") } }
        let dir = URL(fileURLWithPath: CommandLine.arguments[1])
        check(EpicAccount.authorizationCode(from: "  0123456789abcdef0123456789abcdef \n") == "0123456789abcdef0123456789abcdef", "a bare code")
        check(EpicAccount.authorizationCode(from: #"{"redirectUrl":"https://x","authorizationCode":"abcdef0123456789abcdef0123456789","exchangeCode":null,"sid":null}"#) == "abcdef0123456789abcdef0123456789", "the page's whole JSON")
        check(EpicAccount.authorizationCode(from: #""authorizationCode": "feedfacefeedfacefeedfacefeedface","#) == "feedfacefeedfacefeedfacefeedface", "a line of it")
        // 0.31: Epic's sign-in inside Anvil picks the code up from the page Epic ends on.
        check(EpicAccount.isRedirectPage(URL(string: "https://www.epicgames.com/id/api/redirect?clientId=34a02cf8f4414e29b15921876da36f9a&responseType=code")!), "Epic's redirect page is known")
        check(!EpicAccount.isRedirectPage(URL(string: "https://www.epicgames.com/id/login")!) && !EpicAccount.isRedirectPage(URL(string: "https://evil.example/id/api/redirect")!),
              "its login page, and another site's page of the same name, aren't")
        check(EpicAccount.code(fromRedirect: #"{"warning":"Do not share this code with any 3rd party service.","redirectUrl":"https://localhost/launcher/authorized?code=abcdef0123456789abcdef0123456789","authorizationCode":"abcdef0123456789abcdef0123456789","exchangeCode":null,"sid":null}"#) == "abcdef0123456789abcdef0123456789", "the code from the redirect page's text")
        check(EpicAccount.code(fromRedirect: #"{"redirectUrl":"https://localhost/launcher/authorized?code=0123abcd0123abcd0123abcd0123abcd","authorizationCode":null}"#) == "0123abcd0123abcd0123abcd0123abcd", "or from its launcher URL when the field is empty")
        check(EpicAccount.code(fromRedirect: #"{"redirectUrl":"https://www.epicgames.com/id/login","authorizationCode":null,"sid":null}"#) == nil, "not signed in yet: no code")
        check(EpicAccount.code(fromRedirect: "<html>Sign in</html>") == nil, "a page that isn't the JSON: no code")
        check(EpicAccount.launcherCode(in: URL(string: "https://localhost/launcher/authorized?code=feedface")!) == "feedface", "the launcher URL's code")
        do {
            let release = try EpicAccount.parseRelease(Data(contentsOf: dir.appendingPathComponent("release.json")))
            print("latest:", release.tag, release.asset.absoluteString, release.size, "bytes, sha256", release.sha256.prefix(16), "…")
            check(release.asset.lastPathComponent == "legendary_macOS_arm64", "the Apple silicon build")
            // A tampered download is refused.
            let bad = dir.appendingPathComponent("tampered")
            try? FileManager.default.removeItem(at: bad)
            var data = try Data(contentsOf: dir.appendingPathComponent("legendary_macOS_arm64")); data[data.count / 2] ^= 0xFF
            try data.write(to: bad)
            do { try await EpicAccount.installDownloaded(bad, release: release); check(false, "tampered build refused") }
            catch { check(error.localizedDescription.contains("checksum"), "tampered build refused (\(error.localizedDescription))") }
            check(EpicAccount.legendary == nil, "nothing installed from it")
            try await EpicAccount.installDownloaded(dir.appendingPathComponent("legendary_macOS_arm64"), release: release)
            check(EpicAccount.legendary != nil && EpicAccount.installedVersion == release.tag, "installed and recorded")
            let (status, out) = await EpicAccount.run(EpicAccount.binary, ["--version"], timeout: 60)
            print("legendary --version:", status, out.trimmingCharacters(in: .whitespacesAndNewlines))
            check(status == 0 && out.contains(release.tag), "it runs and is the version installed")
        } catch { check(false, "install: \(error.localizedDescription)") }
        print(failures == 0 ? "epic: all checks passed" : "\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
