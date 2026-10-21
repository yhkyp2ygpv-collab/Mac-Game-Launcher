import AppKit
import SwiftUI

/// Which saves a game plays on, after it came back — every export of it, every Windows setup with its saves and Save
/// Guard's backups of it, newest first, and what it has now. Each says what it holds where Anvil can read the game's
/// saves; the furthest through is picked. See SaveVault.
struct SaveChoiceSheet: View {
    @ObservedObject var choice: SaveChoice
    let request: SaveChoice.Request
    @State private var picked: String?
    @State private var showBackups = false
    @State private var showSafety = false

    private var offer: SaveVault.Offer { request.offer }
    private var all: [SaveVault.Candidate] { offer.candidates + [offer.current].compactMap { $0 } }
    private var main: [SaveVault.Candidate] { offer.candidates.filter { !$0.isBackup && !$0.isSafetyCopy } }
    private var backups: [SaveVault.Candidate] { offer.candidates.filter(\.isBackup) }
    private var safety: [SaveVault.Candidate] { offer.candidates.filter(\.isSafetyCopy) }
    /// Marked Most Progress: what's picked, when it was picked for being furthest through.
    private var furthest: String? {
        guard let pick = offer.recommended, pick.percent != nil, all.filter({ $0.percent != nil }).count > 1 else { return nil }
        return pick.id
    }
    /// Marked Newest: the newest export or other setup's saves, when that isn't what's picked anyway.
    private var newest: String? { main.first.map(\.id).flatMap { $0 == furthest ? nil : $0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Saves from before").font(.title3.bold())
                    Text(offer.game.title).font(.callout).foregroundStyle(.secondary)
                }
            }

            if let done = request.done {
                let failed = done.hasPrefix("Those saves couldn't") || done.hasPrefix("That couldn't")
                Label(done, systemImage: failed ? "exclamationmark.triangle" : "checkmark.circle.fill")
                    .foregroundStyle(failed ? .orange : .green)
                    .fixedSize(horizontal: false, vertical: true)
                if request.undoable {
                    Text("Changed your mind? Undo puts back the saves it had a moment ago.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if request.undoable { Button("Undo") { choice.undoFromSheet() } }
                    Spacer()
                    Button("Done") { choice.finish() }.keyboardShortcut(.defaultAction)
                }
            } else if let working = request.working {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(working) }
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                Text("Choose the saves to play on. What it has now is exported first, so you can always go back to it.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(main) { row($0) }
                        if let current = offer.current { row(current) }
                        if !backups.isEmpty {
                            DisclosureGroup(isExpanded: $showBackups) {
                                VStack(spacing: 8) { ForEach(backups) { row($0) } }.padding(.top, 6)
                            } label: {
                                Text("Backups Anvil made before each play (\(backups.count))").font(.callout.weight(.medium))
                            }
                            .padding(.top, 4)
                        }
                        if !safety.isEmpty {
                            DisclosureGroup(isExpanded: $showSafety) {
                                VStack(spacing: 8) { ForEach(safety) { row($0) } }.padding(.top, 6)
                            } label: {
                                Text("Kept by Anvil before earlier restores (\(safety.count))").font(.callout.weight(.medium))
                            }
                        }
                    }
                    .padding(.trailing, 6)
                }
                .frame(maxHeight: 380)
                if let note = comparison {
                    Label(note, systemImage: "chart.bar.xaxis").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Ask Me Later") { choice.finish() }
                    Spacer()
                    if let current = offer.current, picked == nil || picked == current.id {
                        Button("Keep What It Has Now") { choice.choose(current) }
                            .keyboardShortcut(picked == current.id ? .defaultAction : nil)
                    }
                    if picked != offer.current?.id {
                        Button("Use These Saves") { choice.choose(all.first { $0.id == picked }) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(picked == nil || all.first { $0.id == picked }?.sameAsNow == true)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 600)
        .onAppear {
            picked = (offer.recommended ?? main.first ?? offer.candidates.first)?.id
            // A pick from the folded lists is shown.
            if let p = picked { showBackups = backups.contains { $0.id == p }; showSafety = safety.contains { $0.id == p } }
        }
    }

    /// The picked saves against what the game has now, where both were read.
    private var comparison: String? {
        guard let pick = all.first(where: { $0.id == picked }), let now = offer.current, pick.id != now.id,
              let a = pick.percent, let b = now.percent else { return offer.because }
        let diff = a - b
        if abs(diff) < 0.05 { return String(format: "These are as far through as what it has now (%.1f%%).", a) }
        return String(format: "These are %.1f%% complete — %.1f points %@ than what it has now (%.1f%%).", a, abs(diff), diff > 0 ? "further" : "less far", b)
    }

    private func row(_ c: SaveVault.Candidate) -> some View {
        Button { picked = c.id } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: picked == c.id ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(picked == c.id ? Color.accentColor : .secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title(c)).bold()
                        ForEach(badges(c), id: \.self) { badge($0) }
                    }
                    if let s = c.summary {
                        HStack(spacing: 8) {
                            Text(s.place).font(.callout)
                            if let pct = s.percent {
                                ProgressView(value: min(pct, 100), total: 100).frame(width: 70).controlSize(.small)
                                Text(String(format: "%.1f%%", pct)).font(.callout.monospacedDigit())
                            }
                        }
                    }
                    Text(detail(c)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(picked == c.id ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06)))
            .opacity(c.sameAsNow ? 0.6 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let url = location(c) { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
        }
    }

    private func badges(_ c: SaveVault.Candidate) -> [String] {
        var out: [String] = []
        if c.id == furthest { out.append("Most progress") }
        if c.id == newest && c.kind != .current { out.append("Newest") }
        if c.sameAsNow { out.append("Same as now") }
        return out
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(text == "Most progress" ? Color.green.opacity(0.2) : Color.secondary.opacity(0.15)))
            .foregroundStyle(text == "Most progress" ? Color.green : Color.secondary)
    }

    private func location(_ c: SaveVault.Candidate) -> URL? {
        switch c.kind {
        case .export(let zips, _): zips.first { $0.path.contains("/Documents/") } ?? zips.first
        case .backup(let folder, _, _, _, _): folder
        default: nil
        }
    }

    private func when(_ d: Date?) -> String { d.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "unknown" }

    private func title(_ c: SaveVault.Candidate) -> String {
        switch c.kind {
        case .export(_, let at): c.isSafetyCopy ? "Kept before restoring, \(when(at))" : "Exported \(when(at))"
        case .otherSetup(_, let name, _): "Left in the “\(name)” Windows setup"
        case .backup(_, _, _, _, let at): "Backup of \(when(at))"
        case .current: "What it has now"
        }
    }

    private func detail(_ c: SaveVault.Candidate) -> String {
        let size = ByteCountFormatter.string(fromByteCount: c.bytes, countStyle: .file)
        var saved = "last saved \(when(c.lastSaved)) · \(c.files) file\(c.files == 1 ? "" : "s"), \(size)"
        if c.copies > 1 { saved += " · \(c.copies) copies of these same saves" }
        if c.samePoint > 0 { saved += " · and \(c.samePoint) older backup\(c.samePoint == 1 ? "" : "s") at this same point" }
        switch c.kind {
        case .export(let zips, _):
            let places = zips.map { $0.path.contains("/Documents/") ? "Documents › Anvil Saves" : "Anvil" }
            return "The game \(saved) · kept in " + Array(Set(places)).sorted().joined(separator: " and ")
        case .otherSetup:
            return "Where it was before it was downloaded again — the game \(saved)"
        case .backup(_, _, let name, _, _):
            return "Made in “\(name)” as the game started — the game \(saved)"
        case .current:
            return "Since it was downloaded again — the game \(saved)"
        }
    }
}
