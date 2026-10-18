import SwiftUI

struct RuntimesView: View {
    @EnvironmentObject private var runtimes: RuntimeManager
    @EnvironmentObject private var library: Library
    @StateObject private var catalog = EngineCatalog.shared
    @ObservedObject private var connectivity = Connectivity.shared
    @State private var error: String?
    @State private var includePreview = false
    @State private var installing: String?
    @State private var repairing: String?
    @ObservedObject private var optimizer = EngineOptimizer.shared
    @StateObject private var shaders = ShaderCacheManager.shared
    @State private var leftovers: [Housekeeping.Leftover] = []
    @State private var trashTarget: Housekeeping.Leftover?

    var body: some View {
        Form {
            SwiftUI.Section {
                ForEach(runtimes.runtimes) { runtime in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(runtime.displayName).bold()
                                if runtime.isManaged {
                                    Tag("Managed", .green)
                                } else {
                                    Tag("External", .orange)
                                }
                                // The number that actually decides how a DirectX 12
                                // title performs. Two toolchains can both report
                                // wine-7.7 and ship D3DMetal builds a year apart.
                                if let v = runtime.d3dMetalVersion {
                                    Tag("D3DMetal \(v)", runtime.id == runtimes.bestD3DMetal?.id ? .blue : .secondary)
                                } else if runtime.hasD3DMetal {
                                    Tag("D3DMetal", .blue)
                                }
                                if !runtime.source.isEmpty { Tag(runtime.source, .secondary) }
                            }
                            Text(runtime.root.path)
                                .font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            Text(usageDescription(runtime))
                                .font(.caption).foregroundStyle(.secondary)
                            if runtime.isManaged {
                                let profile = EngineProfile.of(runtime)
                                Text("\(profile.title) — " + profile.adjustments.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let record = optimizer.records[runtime.id], optimizer.isPrepared(runtime) {
                                    if let failure = record.failure {
                                        Label("Didn't start on this Mac when prepared (\(failure)) — Autopilot won't move games to it",
                                              systemImage: "exclamationmark.triangle.fill")
                                            .font(.caption).foregroundStyle(.orange)
                                            .fixedSize(horizontal: false, vertical: true)
                                    } else {
                                        Label("Prepared for this Mac" + (record.warmUpSeconds.map { String(format: " — first run done ahead (%.0f s of Rosetta's translation)", $0) } ?? ""),
                                              systemImage: "bolt.badge.checkmark.fill")
                                            .font(.caption).foregroundStyle(record.starts ? .green : .secondary)
                                    }
                                } else if optimizer.working?.contains(runtime.displayName) == true {
                                    Label("Being prepared for this Mac…", systemImage: "gearshape.2").font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Label("Prepared at the next start, or when no game is running", systemImage: "clock")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let changed = runtimes.sealProblems[runtime.id] {
                                    Label("\(changed.count) file\(changed.count == 1 ? "" : "s") changed since it was sealed — games won't run on it until it's repaired",
                                          systemImage: "exclamationmark.shield.fill")
                                        .font(.caption).foregroundStyle(.red)
                                        .help(changed.prefix(20).joined(separator: "\n"))
                                } else if EngineSeal.isSealed(runtime.id) {
                                    Label("Sealed — every file checked against this Mac's 512-bit key", systemImage: "checkmark.shield.fill")
                                        .font(.caption).foregroundStyle(.green)
                                }
                            }
                        }
                        Spacer()
                        if runtimes.sealProblems[runtime.id] != nil {
                            Button(repairing == runtime.id ? "Repairing…" : "Repair") {
                                repairing = runtime.id
                                Task {
                                    do { try await runtimes.repair(runtime) } catch { self.error = error.localizedDescription }
                                    repairing = nil
                                }
                            }
                            .disabled(repairing != nil)
                        }
                        if !runtime.isManaged {
                            Button("Take Ownership") {
                                do { _ = try runtimes.adopt(runtime) }
                                catch { self.error = error.localizedDescription }
                            }
                            .help("Clones this toolchain into Anvil's own store. The app it came from is left exactly as it is.")
                        }
                    }
                    .padding(.vertical, 3)
                }
            } header: {
                Text("Installed Toolchains")
            } footer: {
                Text("“External” toolchains belong to another app — Whisky or Mythic can update them out from under you. Taking ownership clones one into Anvil's own store, so a container that works today keeps working and the other app keeps the copy it had. On APFS the clone is instant and costs no extra disk.")
                    .font(.caption)
            }

            SwiftUI.Section {
                Toggle("Include preview engines", isOn: $includePreview)
                    .help("Preview engines carry newer D3DMetal builds and are less tested.")

                ForEach(catalog.available(includePreview: includePreview)) { release in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(release.headline).bold()
                                if release.channel != "stable" { Tag(release.channel.capitalized, .orange) }
                                if isInstalled(release) { Tag("Installed", .green) }
                            }
                            Text(release.releaseDate.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isInstalled(release) {
                            Text("Installed").font(.caption).foregroundStyle(.secondary)
                        } else if installing == release.id {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Install") { install(release) }
                                .disabled(!connectivity.isOnline)
                                .help(connectivity.isOnline ? "" : "Installing needs a connection.")
                        }
                    }
                    .padding(.vertical, 3)
                }

                Button {
                    Task { await catalog.check() }
                } label: {
                    Label(catalog.releases.isEmpty ? "Check for Engines" : "Check Again",
                          systemImage: "arrow.down.circle")
                }
                .disabled(catalog.state == .checking)

                if case .failed(let message) = catalog.state {
                    Text(catalog.releases.isEmpty ? message : message + " Showing the list from the last check.")
                        .font(.caption).foregroundStyle(.red)
                }
                if catalog.state == .offline || (catalog.fromCache && !connectivity.isOnline) {
                    Label(catalog.releases.isEmpty
                          ? "You're offline and the engine list hasn't been fetched on this Mac yet. It appears once you're online."
                          : "You're offline — this is the list from \(catalog.lastChecked.map { DiskCache.age($0) } ?? "the last check"). Installed engines keep working; installing a new one waits for a connection.",
                          systemImage: "wifi.slash")
                        .font(.caption).foregroundStyle(.secondary)
                } else if catalog.fromCache, let checked = catalog.lastChecked {
                    Text("Last checked: \(DiskCache.age(checked)).").font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Available Engines")
            } footer: {
                Text("Read from Mythic's public engine catalogue. Anvil installs into its own store and never writes to a Mythic install — Mythic keeps the engine it has, and keeps updating it on its own. Each version lands in its own folder, so switching back after a bad update is one click and never touches a save or a prefix.")
                    .font(.caption)
            }

            SwiftUI.Section {
                if shaders.entries.isEmpty {
                    Text("No compiled shader caches yet. One appears the first time a DirectX game runs.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(shaders.entries) { entry in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(entry.executable).bold()
                                if entry.isProtected { Tag("Kept", .green) }
                                if entry.isRecoverable { Tag("System copy purged", .orange) }
                            }
                            Text(cacheDetail(entry)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            Button("Discard System Copy") { shaders.discard(entry, alsoStored: false) }
                            Button("Discard Both", role: .destructive) { shaders.discard(entry, alsoStored: true) }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                    .padding(.vertical, 3)
                }

                HStack {
                    Button("Keep All Now") { shaders.protectAll() }
                    Button("Restore All") { shaders.restoreAll() }
                    Spacer()
                    Button { shaders.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                }
                if !shaders.lastAction.isEmpty {
                    Text(shaders.lastAction).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Shader Caches")
            } footer: {
                Text("D3DMetal compiles every shader a game uses and caches the result under /var/folders, which macOS treats as scratch space and clears on its own schedule. When it does, the game recompiles everything — the stutter that comes back in a game that had already run smoothly. Anvil keeps a copy where nothing sweeps it, puts it back before each launch, and takes the grown copy afterwards. Discard one only if a game hangs at startup after an engine change, which is what a cache written by an older D3DMetal looks like.")
                    .font(.caption)
            }

            if !leftovers.isEmpty {
                SwiftUI.Section {
                    ForEach(leftovers) { item in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(item.url.lastPathComponent.prefix(8) + "…").bold().monospaced()
                                    if item.hasUserData { Tag("May hold saves", .orange) }
                                }
                                Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)
                                     + (item.modified.map { " · last changed " + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                            Button("Move to Trash…") { trashTarget = item }
                        }
                        .padding(.vertical, 3)
                    }
                } header: {
                    Text("Containers Not in the Library")
                } footer: {
                    Text("Windows environments on disk that no container in the library uses — left by containers deleted in earlier versions, or by a library that had to be rebuilt. Anvil never removes them by itself. One marked “May hold saves” has files in its Windows user folders: look in drive_c › users before you trash it, or bring the saves across with Import Saves.")
                        .font(.caption)
                }
            }

            SwiftUI.Section("This Mac") {
                LabeledContent("Chip", value: SystemInfo.current.cpuBrand)
                LabeledContent("GPU", value: SystemInfo.current.gpuName)
                LabeledContent("Cores", value: "\(SystemInfo.current.performanceCores)P + \(SystemInfo.current.efficiencyCores)E")
                LabeledContent("Unified memory", value: "\(SystemInfo.current.memoryGB) GB")
                LabeledContent("Metal working set", value: "\(SystemInfo.current.recommendedVRAMMB) MB")
                LabeledContent("macOS", value: SystemInfo.current.macOSVersion)
                LabeledContent("Rosetta", value: SystemInfo.current.hasRosetta ? "Installed" : "Not installed")
            }

            SwiftUI.Section {
                Button {
                    runtimes.discover()
                } label: {
                    Label("Rescan for Toolchains", systemImage: "arrow.clockwise")
                }
                Button {
                    NSWorkspace.shared.open(RuntimeManager.support)
                } label: {
                    Label("Open Anvil's Data Folder", systemImage: "folder")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Runtimes")
        .task {
            shaders.refresh()
            await scanLeftovers()
            // The kept list shows at once; a fresh one is fetched when there's a connection.
            if catalog.releases.isEmpty || catalog.fromCache { await catalog.check() }
        }
        .confirmationDialog("Move this container to the Trash?", isPresented: .constant(trashTarget != nil),
                            presenting: trashTarget) { item in
            Button("Move to Trash", role: .destructive) {
                do {
                    try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                    AnvilLog.write("leftover container moved to the Trash: \(item.url.lastPathComponent)")
                } catch { self.error = error.localizedDescription }
                trashTarget = nil
                Task { await scanLeftovers() }
            }
            Button("Cancel", role: .cancel) { trashTarget = nil }
        } message: { item in
            Text(item.hasUserData
                 ? "It has files in its Windows user folders that may be saves. It goes to the Trash, not away for good: until the Trash is emptied, it can be put back."
                 : "It goes to the Trash, not away for good: until the Trash is emptied, it can be put back.")
        }
        .alert("Error", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    /// Sizes come from walking each prefix, so off the main thread.
    private func scanLeftovers() async {
        // With no library loaded every prefix would look unclaimed; say nothing then.
        guard !library.containers.isEmpty, library.lastError == nil else { leftovers = []; return }
        let known = Set(library.containers.map(\.id))
        leftovers = await Task.detached(priority: .utility) {
            Housekeeping.leftoverContainers(known: known)
        }.value
    }

    private func cacheDetail(_ entry: ShaderCacheManager.Entry) -> String {
        func mb(_ b: Int64) -> String { String(format: "%.1f MB", Double(b) / 1_048_576) }
        if entry.isRecoverable && entry.liveBytes == 0 {
            return "System copy gone · Anvil holds \(mb(entry.storedBytes)), restored on next launch"
        }
        if entry.storedBytes == 0 { return "\(mb(entry.liveBytes)) live · not kept yet" }
        return "\(mb(entry.liveBytes)) live · \(mb(entry.storedBytes)) kept"
    }

    private func isInstalled(_ release: EngineCatalog.Release) -> Bool {
        runtimes.runtimes.contains { $0.id == release.runtimeID || $0.version == release.version }
    }

    private func install(_ release: EngineCatalog.Release) {
        installing = release.id
        Task {
            defer { installing = nil }
            do { try await catalog.install(release) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func usageDescription(_ runtime: Runtime) -> String {
        let count = library.containers.filter { $0.runtimeID == runtime.id }.count
        if count == 0 { return "Not used by any container" }
        return "Used by \(count) container\(count == 1 ? "" : "s")"
    }
}

private struct Tag: View {
    let text: String
    let color: Color
    init(_ text: String, _ color: Color) { self.text = text; self.color = color }
    var body: some View {
        Text(text)
            .font(.caption2).bold()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }
}
