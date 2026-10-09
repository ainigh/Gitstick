import Foundation

/// Writes the commit message so the user never has to.
/// Deterministic and descriptive: "Add index.html", "Add 2 files, update style.css".
public enum CommitMessage {
    public static func make(from changes: [(status: Character, path: String)]) -> String {
        guard !changes.isEmpty else { return "Sync" }

        var added: [String] = [], updated: [String] = [], deleted: [String] = [], moved: [String] = []
        for c in changes {
            let name = (c.path as NSString).lastPathComponent
            switch c.status {
            case "A", "C": added.append(name)
            case "D": deleted.append(name)
            case "R": moved.append(name)
            default: updated.append(name)
            }
        }

        func phrase(_ verb: String, _ names: [String]) -> String? {
            switch names.count {
            case 0: return nil
            case 1: return "\(verb) \(names[0])"
            case 2 where changes.count <= 3: return "\(verb) \(names[0]) and \(names[1])"
            default: return "\(verb) \(names.count) files"
            }
        }

        let parts = [phrase("Add", added), phrase("update", updated), phrase("move", moved), phrase("delete", deleted)]
            .compactMap { $0 }
        var subject = parts.joined(separator: ", ")
        subject = subject.prefix(1).uppercased() + subject.dropFirst()

        // Body lists every path, so history stays searchable even when the subject is a summary.
        if changes.count > 1 {
            let body = changes.map { "\($0.status) \($0.path)" }.joined(separator: "\n")
            return subject + "\n\n" + body + "\n\n[gitstick]"
        }
        return subject + "\n\n[gitstick]"
    }
}
