import Foundation

/// One node in the size tree. Directory size is the recursive sum.
final class TreeNode: Identifiable, ObservableObject, Equatable {
    static func == (lhs: TreeNode, rhs: TreeNode) -> Bool { lhs.id == rhs.id }

    let id = UUID()
    let name: String
    let url: URL
    let isDirectory: Bool
    @Published var size: Int64          // file bytes, or recursive total for dirs
    var children: [TreeNode] = []

    init(name: String, url: URL, isDirectory: Bool, size: Int64 = 0) {
        self.name = name
        self.url = url
        self.isDirectory = isDirectory
        self.size = size
    }

    var sortedChildren: [TreeNode] {
        children.sorted { $0.size > $1.size }
    }
}

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useAll]
        fmt.countStyle = .file
        return fmt.string(fromByteCount: bytes)
    }
}

struct SyncOptions: Codable, Equatable {
    var source: String = ("~/git_repos" as NSString).expandingTildeInPath
    var destination: String = ("~/SimpleFileSync-Destination" as NSString).expandingTildeInPath
    var deleteExtraneous = false
    var dryRun = true
    var compress = false
    var preservePermissions = true
    var verbose = true

    func rsyncArgs(modernRsync: Bool = true) -> [String] {
        var args = ["-a"]                       // archive: recursive, times, perms, symlinks
        if deleteExtraneous { args.append("--delete") }
        if dryRun { args.append("-n") }
        if compress { args.append("-z") }
        if !preservePermissions {
            args += ["--no-perms", "--no-owner", "--no-group"]
        }
        if verbose { args.append("-v") }
        if modernRsync {
            args += ["--info=progress2,stats2"]
        } else {
            args += ["--progress"]      // openrsync (macOS default) lacks --info
        }
        args += ["--human-readable"]
        // Trailing slash = copy the *contents* of source into destination.
        let src = source.hasSuffix("/") ? source : source + "/"
        args += [src, destination]
        return args
    }
}

struct JobRecord: Codable, Identifiable {
    var id: Date { started }
    let started: Date
    let options: SyncOptions
    let exitCode: Int32?
    let duration: TimeInterval
    let bytesTransferred: Int64?
}
