import SwiftUI

/// Path-keyed comparison of two scanned trees, for the side-by-side view.
struct DiffResult {
    enum Status { case same, differs, onlyInSource, onlyInDest }

    var sourceStatus: [String: Status] = [:]
    var destStatus: [String: Status] = [:]
    var onlySourceCount = 0
    var onlySourceBytes: Int64 = 0
    var onlyDestCount = 0
    var onlyDestBytes: Int64 = 0
    var differsCount = 0

    var summaryText: String {
        "\(onlySourceCount) new (\(ByteFormat.string(onlySourceBytes))) · "
        + "\(differsCount) changed · "
        + "\(onlyDestCount) extra in target (\(ByteFormat.string(onlyDestBytes)))"
    }
}

enum DirectoryDiff {
    struct Entry { let isDir: Bool; let size: Int64 }

    /// Flatten a tree into relPath -> Entry. relPath is relative to the scanned root.
    private static func flatten(_ node: TreeNode, prefix: String,
                                into dict: inout [String: Entry]) {
        for child in node.children {
            let rel = prefix.isEmpty ? child.name : prefix + "/" + child.name
            dict[rel] = Entry(isDir: child.isDirectory, size: child.size)
            if child.isDirectory { flatten(child, prefix: rel, into: &dict) }
        }
    }

    static func compare(source: TreeNode?, dest: TreeNode?) -> DiffResult {
        var result = DiffResult()
        guard let source, let dest else { return result }
        var srcFlat: [String: Entry] = [:]
        var dstFlat: [String: Entry] = [:]
        flatten(source, prefix: "", into: &srcFlat)
        flatten(dest, prefix: "", into: &dstFlat)

        for (rel, s) in srcFlat {
            if let d = dstFlat[rel] {
                if d.size == s.size { result.sourceStatus[rel] = .same; result.destStatus[rel] = .same }
                else { result.sourceStatus[rel] = .differs; result.destStatus[rel] = .differs; result.differsCount += 1 }
            } else {
                result.sourceStatus[rel] = .onlyInSource
                if !s.isDir { result.onlySourceCount += 1; result.onlySourceBytes += s.size }
            }
        }
        for (rel, d) in dstFlat where srcFlat[rel] == nil {
            result.destStatus[rel] = .onlyInDest
            if !d.isDir { result.onlyDestCount += 1; result.onlyDestBytes += d.size }
        }
        return result
    }
}
