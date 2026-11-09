import Foundation

/// Szótár-szerkesztés (felvétel, módosítás) tiszta logikája — a Hub és az önteszt is ezt használja.
public enum DictionaryEditing {
    public static func parseHeard(_ s: String) -> [String] {
        var seen = Set<String>()
        return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    public static func make(term: String, heard: String) -> DictionaryEntry? {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return DictionaryEntry(term: t, heardAs: parseHeard(heard).filter { $0.caseInsensitiveCompare(t) != .orderedSame })
    }

    /// Új bejegyzés az elejére; ha a szó már szerepel (kis/nagybetűtől függetlenül), a téves alakokat összefésüli.
    public static func insert(_ e: DictionaryEntry, into list: [DictionaryEntry]) -> [DictionaryEntry] {
        var out = list
        if let i = out.firstIndex(where: { $0.term.caseInsensitiveCompare(e.term) == .orderedSame }) {
            var m = out[i]
            m.term = e.term
            for h in e.heardAs where !m.heardAs.contains(where: { $0.caseInsensitiveCompare(h) == .orderedSame }) { m.heardAs.append(h) }
            m.autoLearned = m.autoLearned && e.autoLearned
            out.remove(at: i)
            out.insert(m, at: 0)
            return out
        }
        out.insert(e, at: 0)
        return out
    }

    /// Kézi szerkesztés: a bejegyzés ezután már nem „automatikus”.
    public static func update(id: UUID, term: String, heard: String, in list: [DictionaryEntry]) -> [DictionaryEntry] {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let i = list.firstIndex(where: { $0.id == id }) else { return list }
        var out = list
        out[i].term = t
        out[i].heardAs = parseHeard(heard).filter { $0.caseInsensitiveCompare(t) != .orderedSame }
        out[i].autoLearned = false
        return out
    }
}

public enum SnippetEditing {
    /// Mentés: `id` esetén módosítás, különben új az elejére. Azonos kulcsmondat esetén a régit felülírja.
    public static func save(id: UUID?, trigger: String, expansion: String, in list: [Snippet]) -> [Snippet] {
        let t = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !expansion.isEmpty else { return list }
        var out = list
        if let id, let i = out.firstIndex(where: { $0.id == id }) {
            out[i].trigger = t; out[i].expansion = expansion
            out.removeAll { $0.id != id && $0.trigger.caseInsensitiveCompare(t) == .orderedSame }
            return out
        }
        out.removeAll { $0.trigger.caseInsensitiveCompare(t) == .orderedSame }
        out.insert(Snippet(trigger: t, expansion: expansion), at: 0)
        return out
    }
}

/// Előzmény-keresés: ékezet- és kisbetű-független („kerdes” megtalálja a „kérdés”-t), a nyers átiratban és az app nevében is.
public enum HistorySearch {
    static func fold(_ s: String) -> String { s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "hu_HU")) }

    public static func filter(_ items: [HistoryItem], query: String) -> [HistoryItem] {
        let words = fold(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return items }
        return items.filter { it in
            let hay = fold(it.text + " " + it.rawText + " " + it.appName)
            return words.allSatisfy { hay.contains($0) }
        }
    }
}

/// „Első lépések” ellenőrzőlista állapota.
public struct OnboardingState: Equatable, Sendable {
    public var hasKey: Bool
    public var microphone: Bool
    public var accessibility: Bool
    public var inputMonitoring: Bool
    public var hasDictated: Bool
    public init(hasKey: Bool, microphone: Bool, accessibility: Bool, inputMonitoring: Bool, hasDictated: Bool) {
        self.hasKey = hasKey; self.microphone = microphone; self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring; self.hasDictated = hasDictated
    }
    public var steps: [Bool] { [hasKey, microphone, accessibility, inputMonitoring, hasDictated] }
    public var doneCount: Int { steps.filter { $0 }.count }
    public var complete: Bool { doneCount == steps.count }
    /// Az első még hiányzó lépés indexe.
    public var next: Int? { steps.firstIndex(of: false) }
}

public enum AppVersion {
    /// Fejlesztői futtatásnál (nincs Info.plist) ezt mutatjuk; a kiadott .app a build-app.sh VERSION értékét kapja.
    public static let current = "0.4.0"
}
