import SwiftUI
import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--sync-test") {
            runSyncTest()
            return
        }
        if CommandLine.arguments.contains("--scan-test") {
            runScanTest()
            return
        }
        maybeSnapshot()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// `--scan-test <path>`: scan a folder, print stats, exit.
    @MainActor
    private func runScanTest() {
        let a = CommandLine.arguments
        let path = a.count > 2 ? a[2] : "/tmp/sfs-compare-target"
        let scanner = FolderScanner()
        scanner.scan(path)
        waitScan(scanner: scanner, path: path, attempts: 120)
    }

    @MainActor
    private func waitScan(scanner: FolderScanner, path: String, attempts: Int) {
        if scanner.root != nil || scanner.errorText != nil || attempts <= 0 {
            let r = scanner.root
            let text = "SCAN path=\(path) exists=\(FileManager.default.fileExists(atPath: path)) root=\(r?.name ?? "nil") isDir=\(r?.isDirectory.description ?? "nil") size=\(r?.size ?? -1) children=\(r?.children.count ?? -1) files=\(scanner.filesScanned) err=\(scanner.errorText ?? "nil")\n"
            FileHandle.standardOutput.write(text.data(using: .utf8)!)
            exit(r != nil ? 0 : 1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.waitScan(scanner: scanner, path: path, attempts: attempts - 1)
        }
    }

    /// `--sync-test <src> <dst>`: run a real dry-run rsync through RsyncRunner, print state, exit.
    @MainActor
    private func runSyncTest() {
        let a = CommandLine.arguments
        let src = a.count > 2 ? a[2] : ("~/git_repos/simple-file-sync" as NSString).expandingTildeInPath
        let dst = a.count > 3 ? a[3] : "/tmp/sfs-dst-test"
        let runner = RsyncRunner()
        var opts = SyncOptions()
        opts.source = src; opts.destination = dst; opts.dryRun = true
        runner.start(options: opts)
        waitSync(runner: runner, attempts: 600)   // up to 5 min
    }

    @MainActor
    private func waitSync(runner: RsyncRunner, attempts: Int) {
        if (!runner.isRunning && runner.lastExitCode != nil) || attempts <= 0 {
            let code = runner.lastExitCode ?? -1
            let text = """
            RESULT exit=\(code) percent=\(runner.percent) speed=\(runner.speedText) logLines=\(runner.log.count)
            \(runner.log.prefix(3).joined(separator: "\n"))
            …
            \(runner.log.suffix(6).joined(separator: "\n"))

            """
            FileHandle.standardOutput.write(text.data(using: .utf8)!)
            exit(code == 0 ? 0 : 1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.waitSync(runner: runner, attempts: attempts - 1)
        }
    }

    /// `--snapshot <png> [sourcePath]`: render ContentView headlessly, write PNG, exit.
    /// (Uses NSHostingView caching — no Screen Recording permission needed.)
    @MainActor
    private func maybeSnapshot() {
        guard let idx = CommandLine.arguments.firstIndex(of: "--snapshot"),
              CommandLine.arguments.count > idx + 1 else { return }
        let outPath = CommandLine.arguments[idx + 1]
        let source = CommandLine.arguments.count > idx + 2
            ? CommandLine.arguments[idx + 2]
            : ("~/git_repos" as NSString).expandingTildeInPath
        let dest = CommandLine.arguments.count > idx + 3
            ? CommandLine.arguments[idx + 3]
            : ("~/SimpleFileSync-Destination" as NSString).expandingTildeInPath
        let sync = RsyncRunner()
        let scanner = FolderScanner()
        let destScanner = FolderScanner()
        let compare = CommandLine.arguments.contains("--compare")
        let host = NSHostingView(rootView: ContentView(initialMode: compare ? .compare : .single,
                                                       initialSource: source, initialDest: dest,
                                                       initialDestScanner: destScanner)
            .environmentObject(sync).environmentObject(scanner)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(x: 0, y: 0, width: 1440, height: 820)
        scanner.scan(source)
        if compare { destScanner.scan(dest) }
        waitAndCapture(scanner: scanner, destScanner: compare ? destScanner : nil,
                       host: host, outPath: outPath, attempts: 360, extraGrace: compare)  // up to 3 min
    }

    @MainActor
    private func waitAndCapture<V: View>(scanner: FolderScanner, destScanner: FolderScanner?,
                                         host: NSHostingView<V>,
                                         outPath: String, attempts: Int, extraGrace: Bool = false) {
        let ready = scanner.root != nil && (destScanner?.root != nil || destScanner == nil)
        if ready || attempts <= 0 {
            // brief grace so tiles finish laying out; longer in compare mode (diff compute)
            DispatchQueue.main.asyncAfter(deadline: .now() + (extraGrace ? 3 : 1)) {
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
                host.cacheDisplay(in: host.bounds, to: rep)
                let img = NSImage(size: host.bounds.size)
                img.addRepresentation(rep)
                guard let tiff = img.tiffRepresentation,
                      let bmp = NSBitmapImageRep(data: tiff),
                      let png = bmp.representation(using: .png, properties: [:]) else { exit(1) }
                do { try png.write(to: URL(fileURLWithPath: outPath)); exit(0) } catch { exit(1) }
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.waitAndCapture(scanner: scanner, destScanner: destScanner, host: host,
                                outPath: outPath, attempts: attempts - 1, extraGrace: extraGrace)
        }
    }
}

@main
struct SimpleFileSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var sync = RsyncRunner()
    @StateObject private var scanner = FolderScanner()

    var body: some Scene {
        WindowGroup("Simple File Sync") {
            ContentView()
                .environmentObject(sync)
                .environmentObject(scanner)
                .frame(minWidth: 1040, minHeight: 640)
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
