// The Game Doctor's diagnosis of every session in the real logs, read-only.
//
// Pairs each game.log session with its launch in anvil.log and prints what Health would
// say about it, so a rule can be checked against sessions that really happened.
//
//   swiftc -Onone -parse-as-library -module-name Anvil $(find Sources/Anvil/Core -name '*.swift') \
//     Native/Tools/tests/DoctorTest.swift -o $TMPDIR/DoctorTest && $TMPDIR/DoctorTest
import Foundation
@main struct DoctorHarness {
 static func main() {
setvbuf(stdout, nil, _IONBF, 0)
let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Anvil")
let gameText = try! String(contentsOf: support.appendingPathComponent("game.log"), encoding: .utf8)
let anvilText = try! String(contentsOf: support.appendingPathComponent("anvil.log"), encoding: .utf8)
let anvilLines = anvilText.split(separator: "\n")
let iso = ISO8601DateFormatter()

// Sessions in game.log, each paired with its anvil.log launch by time.
let headers = gameText.components(separatedBy: "\n=== ").dropFirst()
for chunk in headers {
    let lines = chunk.split(separator: "\n")
    guard let head = lines.first, let dash = head.range(of: " — ") else { continue }
    let title = String(head[..<dash.lowerBound])
    let rest = head[dash.upperBound...]
    guard let date = iso.date(from: String(rest.prefix(20))) else { continue }
    // launch lines: the prepareAndLaunch for this title closest before the header
    var start: Int?
    for (i, l) in anvilLines.enumerated() where l.contains("prepareAndLaunch: \(title) ") {
        if let d = iso.date(from: String(l.prefix(20))), d <= date.addingTimeInterval(5), d > date.addingTimeInterval(-120) { start = i }
    }
    var launch: [Substring] = []
    if let s = start {
        launch.append(anvilLines[s])
        for l in anvilLines[(s+1)...] { if l.contains("prepareAndLaunch: ") { break }; launch.append(l) }
    }
    let gl = Array(lines.dropFirst())
    let windows = gl.compactMap { FrameLog.parse($0) }
    var e = SessionEvidence(startedAt: date, gameLines: gl, launchLines: launch, windows: windows, outcome: nil)
    e.outcome = e.outcomeFromLog(title: title)
    // As SessionEvidence.read does, from the sessions up to this one.
    let before = String(gameText[..<(gameText.range(of: "=== " + head)?.upperBound ?? gameText.endIndex)])
    e.loadsIntoHeavy = Gameplay.loadsIntoHeavy(title: title, text: before)
    e.loadEstimate = LoadTime.estimate(of: title, text: before)
    let lego = title.contains("LEGO")
    let ctx = DoctorContext(title: title, executableName: lego ? "LEGOSTARWARSSKYWALKERSAGA_DX11.exe" : title == "Steam" ? "steam.exe" : "Cat Quest II.exe",
        enhancementsOff: false, autopilot: true, graphicsLevels: lego, graphicsLevel: lego ? .medium : nil,
        autoTuneMeasuring: false, autoTuneChoice: nil, directX: true,
        engine: .init(id: "mythic-engine-2.6.1", name: "Mythic Engine 2.6.1", d3dMetal: "2.1"),
        newerEngineInstalled: nil, newerEngineAvailable: "Engine 3.0.0 · D3DMetal 3.0.0 (a preview release)",
        engineTrial: nil, previousEngineName: nil, leftovers: nil, actions: [])
    let r = GameDoctor.diagnose(e, ctx)
    let o = e.outcome.map { "code \($0.status) after \(Int($0.seconds)) s\($0.userClosed ? " (closed from Anvil)" : "")" } ?? "no exit line"
    print("\n### \(title.prefix(24)) \(rest.prefix(20)) — \(windows.count) windows, \(o) → \(r.headline)")
    for f in r.findings { print("  [\(f.kind.rawValue)] \(f.title): \(f.detail.prefix(260))\(f.fix.map { "  {\($0.label)}" } ?? "")") }
}

 }
}
