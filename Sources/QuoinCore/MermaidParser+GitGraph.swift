import Foundation

extension MermaidParser {

    static func parseGitGraph(body: [String]) -> GitGraph? {
        let main = "main"
        var branches = [main]
        var current = main
        var headOfBranch: [String: Int] = [:]   // branch → index of its latest commit
        var commits: [GitGraph.Commit] = []
        var autoID = 0

        /// Extracts a `key: "value"` (or `key: value`) field from a command.
        func field(_ key: String, in line: String) -> String? {
            guard let range = line.range(of: "\(key):") else { return nil }
            var rest = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("\"") {
                rest = String(rest.dropFirst())
                if let close = rest.firstIndex(of: "\"") { return String(rest[..<close]) }
            }
            return rest.split(separator: " ").first.map(String.init)
        }

        for line in body {
            let tokens = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard let command = tokens.first else { continue }
            switch command {
            case "commit":
                let parent = headOfBranch[current]
                let id = field("id", in: line) ?? { autoID += 1; return "c\(autoID)" }()
                commits.append(GitGraph.Commit(
                    id: id, branch: current, tag: field("tag", in: line),
                    isMerge: false, parents: parent.map { [$0] } ?? []))
                headOfBranch[current] = commits.count - 1

            case "branch":
                guard tokens.count > 1 else { continue }
                let name = tokens[1].split(separator: " ").first.map(String.init) ?? tokens[1]
                if !branches.contains(name) { branches.append(name) }
                // New branch starts at the current branch's head, then becomes current.
                headOfBranch[name] = headOfBranch[current]
                current = name

            case "checkout", "switch":
                guard tokens.count > 1 else { continue }
                let name = tokens[1].split(separator: " ").first.map(String.init) ?? tokens[1]
                if branches.contains(name) { current = name }

            case "merge":
                guard tokens.count > 1 else { continue }
                let from = tokens[1].split(separator: " ").first.map(String.init) ?? tokens[1]
                var parents: [Int] = []
                if let head = headOfBranch[current] { parents.append(head) }
                if let sourceHead = headOfBranch[from] { parents.append(sourceHead) }
                autoID += 1
                commits.append(GitGraph.Commit(
                    id: field("id", in: line) ?? "merge\(autoID)", branch: current,
                    tag: field("tag", in: line), isMerge: true, parents: parents))
                headOfBranch[current] = commits.count - 1

            default:
                continue
            }
        }

        guard !commits.isEmpty else { return nil }
        // Drop branches that never received a commit (e.g. a lane with no work).
        let used = Set(commits.map(\.branch))
        return GitGraph(commits: commits, branches: branches.filter { used.contains($0) })
    }
}
