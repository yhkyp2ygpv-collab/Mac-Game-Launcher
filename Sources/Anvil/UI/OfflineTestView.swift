import AppKit
import SwiftUI

/// A game's Offline Test, on its page: run one, watch it go, and what the last one found — with
/// the test's picture beside the same moment of an online start.
struct OfflineTestRows: View {
    let game: Game
    @ObservedObject private var tester = OfflineTest.shared
    @EnvironmentObject private var launcher: Launcher

    var body: some View {
        if let run = tester.run, run.gameID == game.id {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                TimelineView(.periodic(from: run.since, by: 1)) { context in
                    Text(phase(run, now: context.date)).monospacedDigit()
                }
                Spacer()
                Button("Stop") { tester.stop() }
            }
        } else {
            if let result = game.offlineRecord?.test { resultRows(result) }
            if let why = OfflineTest.whyNot(game) {
                small(why)
            } else {
                Button(game.offlineRecord?.test == nil ? "Test Offline Start" : "Test Offline Start Again") { tester.test(game) }
                    .disabled(tester.run != nil || !launcher.sessions.isEmpty || launcher.launching != nil)
                small("Starts it as it starts with no connection — its own connections held back while this Mac stays online — watches it for about a minute, closes it, and says from its screen whether it plays offline. Nothing else should be running.")
            }
        }
    }

    @ViewBuilder
    private func resultRows(_ r: OfflineTest.Result) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Offline Test: \(r.verdict.title)").bold()
                Text(r.date.formatted(date: .abbreviated, time: .shortened) + (r.confirmedByPlayer ? " · as you saw it" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: r.verdict.symbol).foregroundStyle(color(r.verdict))
        }
        Text(r.detail).fixedSize(horizontal: false, vertical: true)
        if let test = image(r.folder, r.picture) {
            HStack(alignment: .top, spacing: 12) {
                picture(test, caption: "Offline Test" + (seconds(r.picture).map { ", \($0) s" } ?? ""))
                if let online = image(r.comparedWith, r.referencePicture) {
                    picture(online, caption: "Online start" + (seconds(r.referencePicture).map { ", \($0) s" } ?? ""))
                }
            }
        }
        if r.verdict == .unclear && !r.confirmedByPlayer {
            HStack {
                Text("What did it show?").foregroundStyle(.secondary)
                Button("It got going") { tester.confirm(gameID: game.id, plays: true) }
                Button("It was stuck") { tester.confirm(gameID: game.id, plays: false) }
            }
        }
    }

    private func picture(_ image: NSImage, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                .frame(maxWidth: 220)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func image(_ folder: String?, _ name: String?) -> NSImage? {
        guard let folder, let name else { return nil }
        let url = ScreenReader.root.appendingPathComponent(game.id.uuidString, isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true).appendingPathComponent(name)
        return NSImage(contentsOf: url)
    }

    private func seconds(_ name: String?) -> Int? { name.flatMap(ScreenReader.seconds(of:)) }

    private func color(_ v: OfflineTest.Verdict) -> Color {
        switch v {
        case .plays: .green
        case .needsInternet: .orange
        case .crashed: .red
        case .unclear: .secondary
        }
    }

    private func phase(_ run: OfflineTest.Run, now: Date) -> String {
        let more = run.queued > 0 ? " · \(run.queued) more to test" : ""
        switch run.phase {
        case .starting: return "Starting it as with no connection…" + more
        case .watching: return "Watching it: \(min(Int(now.timeIntervalSince(run.since)), OfflineTest.watchSeconds)) of \(OfflineTest.watchSeconds) s" + more
        case .closing: return "Closing it…" + more
        case .judging: return "Comparing its screen with its online starts…" + more
        }
    }

    private func small(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
