import Foundation
import Combine

/// Recursively scans a folder into a TreeNode tree with aggregated sizes, off the main thread.
@MainActor
final class FolderScanner: ObservableObject {
    @Published var root: TreeNode?
    @Published var isScanning = false
    @Published var filesScanned: Int = 0
    @Published var errorText: String?

    private var scanID = UUID()

    func scan(_ path: String) {
        // Canonicalize with realpath: the enumerator walks symlinked paths by their REAL path
        // (/tmp -> /private/tmp), so an unresolved root orphans every child in the parent
        // lookup. (NSString.resolvingSymlinksInPath would strip /private back off — unusable.)
        let resolved: String = path.withCString { realpath($0, nil) }.map { cStr in
            let s = String(cString: cStr); free(cStr); return s
        } ?? path
        let url = URL(fileURLWithPath: resolved)
        var isDir = ObjCBool(false)
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        guard exists, isDir.boolValue else {
            errorText = "Not found or not a directory: \(path)"
            root = nil
            return
        }
        errorText = nil
        isScanning = true
        filesScanned = 0
        let myID = UUID()
        scanID = myID

        Task.detached(priority: .userInitiated) { [weak self] in
            let counter = Counter { count in
                Task { @MainActor in self?.filesScanned = count }
            }
            let tree = Self.build(url: url, depth: 0, counter: counter)
            let count = counter.value
            await MainActor.run {
                guard let self, self.scanID == myID else { return }
                self.root = tree
                self.filesScanned = count
                self.isScanning = false
            }
        }
    }

    nonisolated private static func build(url: URL, depth: Int, counter: Counter) -> TreeNode {
        let name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let node = TreeNode(name: name, url: url, isDirectory: isDir)
        guard isDir, depth < 12 else {
            if !isDir {
                node.size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
                counter.bump()
            }
            return node
        }
        let fm = FileManager.default
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                     options: [], errorHandler: { _, _ in true }) else { return node }
        var dirCache: [URL: TreeNode] = [url: node]
        var order: [URL] = [url]
        for case let childURL as URL in en {
            if childURL.path.contains(".git/") { continue }
            let isChildDir = (try? childURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let child = TreeNode(name: childURL.lastPathComponent, url: childURL, isDirectory: isChildDir)
            dirCache[childURL] = child
            order.append(childURL)
            let parent = dirCache[childURL.deletingLastPathComponent()]
            parent?.children.append(child)
            if !isChildDir {
                child.size = (try? childURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
                counter.bump()
            }
        }
        // aggregate bottom-up
        for u in order.reversed() {
            guard let n = dirCache[u], n.isDirectory else { continue }
            n.size = n.children.reduce(0) { $0 + $1.size }
        }
        return node
    }

    final class Counter: @unchecked Sendable {
        private var v = 0
        private let lock = NSLock()
        private let onEvery: Int
        private let report: (Int) -> Void
        init(every: Int = 500, report: @escaping (Int) -> Void) { self.onEvery = every; self.report = report }
        func bump() {
            lock.lock(); v += 1
            let shouldReport = v % onEvery == 0
            let snapshot = v
            lock.unlock()
            if shouldReport { report(snapshot) }
        }
        var value: Int { lock.lock(); defer { lock.unlock() }; return v }
    }
}
