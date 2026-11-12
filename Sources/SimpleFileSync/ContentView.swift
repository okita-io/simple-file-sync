import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var sync: RsyncRunner
    @EnvironmentObject var scanner: FolderScanner
    @State private var options = SyncOptions()
    @State private var destScanner = FolderScanner()
    @State private var mode: ViewMode = .single
    @State private var diff: DiffResult?

    enum ViewMode: String, CaseIterable, Identifiable {
        case single = "Treemap", compare = "Compare"
        var id: String { rawValue }
    }

    init(initialMode: ViewMode = .single, initialSource: String? = nil, initialDest: String? = nil,
         initialDestScanner: FolderScanner? = nil) {
        _mode = State(initialValue: initialMode)
        var opts = SyncOptions()
        if let initialSource { opts.source = initialSource }
        if let initialDest { opts.destination = initialDest }
        // Snapshot/CLI runs: the WindowGroup instance must scan the SAME (small) trees as the
        // snapshot host — otherwise it hammers the huge default source and starves the scan.
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--snapshot"), a.count > i + 2 {
            if opts.source == SyncOptions().source { opts.source = a[i + 2] }
            if a.count > i + 3 { opts.destination = a[i + 3] }
        }
        _options = State(initialValue: opts)
        if let initialDestScanner { _destScanner = State(initialValue: initialDestScanner) }
    }

    var body: some View {
        NavigationSplitView {
            syncPanel
                .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 420)
        } detail: {
            VStack(spacing: 0) {
                Picker("", selection: $mode) {
                    ForEach(ViewMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                .padding(6)

                if mode == .single {
                    if let root = scanner.root {
                        TreemapView(root: root)
                            .id(root.id)   // reset drill path when a new scan lands
                    } else {
                        placeholder
                    }
                } else {
                    compareView
                }
                Divider()
                logView.frame(height: 180)
            }
            .frame(minWidth: 620)
        }
        .onAppear {
            scanner.scan(options.source)
            if mode == .compare { destScanner.scan(options.destination) }
        }
        .onChange(of: mode) { _, newMode in
            if newMode == .compare {
                scanner.scan(options.source)
                destScanner.scan(options.destination)
            }
        }
        .task(id: "\(scanner.root?.id.uuidString ?? "0")|\(destScanner.root?.id.uuidString ?? "0")") {
            if mode == .compare {
                diff = DirectoryDiff.compare(source: scanner.root, dest: destScanner.root)
            }
        }
        .toolbar {
            ToolbarItem {
                Button { scanner.scan(options.source) } label: {
                    Image(systemName: "arrow.clockwise")
                }.help("Rescan source")
            }
        }
    }

    // MARK: - Left: sync panel

    private var syncPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sync").font(.title3.weight(.semibold))

            pathField(title: "Source", key: \SyncOptions.source,
                      hint: "contents copied")
            pathField(title: "Destination", key: \SyncOptions.destination,
                      hint: "sync into")

            Toggle("Delete extra files", isOn: $options.deleteExtraneous)
                .toggleStyle(.checkbox).font(.caption)
                .help("rsync --delete: remove files in target that are not in source")
            Toggle("Dry run", isOn: $options.dryRun)
                .toggleStyle(.checkbox).font(.caption)
                .help("Preview only — nothing is written")
            Toggle("Compress (-z)", isOn: $options.compress)
                .toggleStyle(.checkbox).font(.caption)
            Toggle("Preserve perms", isOn: $options.preservePermissions)
                .toggleStyle(.checkbox).font(.caption)

            HStack {
                Button {
                    scanner.scan(options.source)
                    sync.start(options: options)
                } label: {
                    Label(sync.isRunning ? "…" : (options.dryRun ? "Dry Run" : "Sync Now"),
                          systemImage: sync.isRunning ? "hourglass" : "arrow.right.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(sync.isRunning)

                if sync.isRunning {
                    Button(role: .destructive) { sync.stop() } label: {
                        Image(systemName: "stop.circle.fill")
                    }.controlSize(.large)
                }
            }

            if sync.isRunning || sync.lastExitCode != nil {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: sync.percent)
                    HStack {
                        Text("\(Int(sync.percent * 100))%").font(.caption.monospaced())
                        Spacer()
                        Text(sync.speedText).font(.caption.monospaced())
                        Text(sync.etaText).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }

            Divider()
            Text("Recent").font(.headline)
            if sync.recentJobs.isEmpty {
                Text("no jobs yet").font(.caption).foregroundStyle(.secondary)
            } else {
                List(sync.recentJobs.prefix(6)) { job in
                    HStack {
                        Image(systemName: job.exitCode == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(job.exitCode == 0 ? .green : .red)
                        VStack(alignment: .leading) {
                            Text((job.options.source as NSString).lastPathComponent)
                                .font(.caption.weight(.medium))
                            Text("\(job.options.dryRun ? "dry run · " : "")\(String(format: "%.1f", job.duration))s")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(job.started, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .scrollDisabled(true)
                .frame(height: CGFloat(min(sync.recentJobs.count, 6)) * 44)
            }
            Spacer()
        }
        .padding(16)
        .background(.background.secondary)
    }

    private func pathField(title: String, key: WritableKeyPath<SyncOptions, String>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            HStack {
                TextField(hint, text: Binding(get: { options[keyPath: key] },
                                              set: { options[keyPath: key] = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                    .onSubmit { if key == \SyncOptions.source { scanner.scan(options.source) } }
                Button("…") { pick(&options[keyPath: key]) }
            }
        }
    }

    private func pick(_ binding: inout String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            binding = url.path
            scanner.scan(options.source)
        }
    }

    // MARK: - Compare (side-by-side source → target)

    @ViewBuilder
    private var compareView: some View {
        let liveDiff = diff ?? DirectoryDiff.compare(source: scanner.root, dest: destScanner.root)
        HStack(spacing: 0) {
            sideView(title: "Source", node: scanner.root, statuses: liveDiff.sourceStatus,
                     scanning: scanner.isScanning)
            VStack(spacing: 8) {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.tint)
                if scanner.root != nil && destScanner.root != nil {
                    Text(liveDiff.summaryText)
                        .font(.caption2).multilineTextAlignment(.center)
                    legend
                }
                Button("Rescan both") {
                    scanner.scan(options.source)
                    destScanner.scan(options.destination)
                }
                .controlSize(.small)
            }
            .frame(width: 190)
            .padding(8)
            sideView(title: "Target", node: destScanner.root, statuses: liveDiff.destStatus,
                     scanning: destScanner.isScanning)
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 3) {
            chip(.onlyInSource, "new — would copy")
            chip(.differs, "size differs")
            chip(.onlyInDest, "extra in target")
            chip(.same, "in sync")
        }
        .font(.caption2)
    }

    private func chip(_ s: DiffResult.Status, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(tileColor(s)).frame(width: 10, height: 10)
            Text(label)
        }
    }

    private func tileColor(_ s: DiffResult.Status) -> Color {
        switch s {
        case .onlyInSource: return Color(hue: 0.36, saturation: 0.75, brightness: 0.75)
        case .onlyInDest:   return Color(hue: 0.02, saturation: 0.75, brightness: 0.75)
        case .differs:      return Color(hue: 0.10, saturation: 0.80, brightness: 0.85)
        case .same:         return Color(hue: 0.58, saturation: 0.45, brightness: 0.55)
        }
    }

    @ViewBuilder
    private func sideView(title: String, node: TreeNode?, statuses: [String: DiffResult.Status]?,
                          scanning: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let node { Text(ByteFormat.string(node.size)).font(.caption2.monospaced()).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            if let node {
                TreemapView(root: node, statuses: statuses)
                    .id(node.id)
            } else {
                VStack(spacing: 6) {
                    if scanning { ProgressView().controlSize(.small) }
                    Text("empty / not scanned")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Right pieces

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.3x3.topleft.filled").font(.system(size: 44)).foregroundStyle(.tertiary)
            if scanner.isScanning {
                ProgressView("Measuring \(options.source)… (\(scanner.filesScanned) files)")
            } else {
                Text(scanner.errorText ?? "Choose a source folder to visualize its sizes")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(sync.log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(6)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: sync.log.count) { _, n in
                if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
            }
        }
    }
}
