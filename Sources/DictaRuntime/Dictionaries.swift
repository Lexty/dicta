import DictaCore
import Foundation

/// The Tier 0 dictionary, read off disk (D19: the decision is pure in `DictaCore`, the I/O here).
///
/// It is read **per attempt**, not once at start-up, and that is deliberate rather than lazy:
/// step 3 is scored by adding a deliberately wrong rule, running one dictation, and naming the rule
/// from the record. A dictionary cached at start-up would make that workflow "edit the file, then
/// restart the daemon", and a user testing a rule would eventually test it against the previous
/// version of the file without noticing. The file is a few kilobytes and the read happens during
/// `processing`, where the 150 ms budget of F4 has already been spent.
public struct FileDictionary: Sendable {
    public let url: URL

    public init(url: URL = Paths.current.dictionary) {
        self.url = url
    }

    /// Reads and parses. Never throws: §7 says a config file never blocks a dictation, and an error
    /// here would have to be swallowed by every caller anyway.
    ///
    /// **An absent file is not a degraded one.** §7 lists "missing" beside "unparsable", and the
    /// separation made here is that a file that has never existed is the normal state of a fresh
    /// install -- there is no configuration switch enabling the dictionary, so absence is how a
    /// user who does not want one says so. Notifying them on every dictation would train them to
    /// dismiss dicta's notifications, which is the property §7 exists to protect. A file that
    /// exists and cannot be read or parsed is a different claim entirely, and that one is loud.
    public func load() -> ReplacementDictionary {
        guard FileManager.default.fileExists(atPath: url.path) else { return .none }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return ReplacementDictionary(
                problems: [DictionaryProblem(line: nil,
                                             detail: "\(url.path) could not be read: \(error)")],
                version: version
            )
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return ReplacementDictionary(
                problems: [DictionaryProblem(line: nil,
                                             detail: "\(url.path) is not valid UTF-8")],
                version: version
            )
        }
        return Replacements.parse(text, version: version)
    }

    /// §9's "version or mtime". The mtime, in the record's own timestamp format, so a `rules` field
    /// and an `at` field read the same way -- and so that "which file said that" can be answered
    /// against a backup by its date.
    private var version: String? {
        guard let modified = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        else { return nil }
        return Record.timestamp(modified)
    }
}
