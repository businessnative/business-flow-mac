import Foundation

/// Szótár-tanulás a beillesztés utáni kézi javításból: ha a mezőben pontosan egy, a beillesztett szövegből származó
/// szót írtál át egy hasonlóra (pl. „Szőts” → „Szőcs”), azt felvesszük a szótárba. A mező tartalmát nem tároljuk.
public enum AutoLearn {
    static func tokens(_ s: String) -> [Substring] {
        s.split(whereSeparator: { $0.isWhitespace })
    }

    static func core(_ w: Substring) -> String {
        String(w).trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
    }

    /// `pasted`: a mező tartalma közvetlenül a beillesztés után; `later`: néhány másodperccel később.
    public static func correction(inserted: String, pasted: String, later: String, dictionary: [DictionaryEntry]) -> (heard: String, term: String)? {
        guard pasted != later else { return nil }
        let a = tokens(pasted), b = tokens(later)
        guard abs(a.count - b.count) == 0, !a.isEmpty else { return nil }
        var p = 0
        while p < a.count && a[p] == b[p] { p += 1 }
        var sfx = 0
        while sfx < a.count - p && a[a.count - 1 - sfx] == b[b.count - 1 - sfx] { sfx += 1 }
        guard a.count - p - sfx == 1 else { return nil }
        let old = core(a[p]), new = core(b[p])
        guard old != new, old.count >= 3, new.count >= 3, new.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }) else { return nil }
        // Csak a most beillesztett szövegben szereplő szót tanuljuk.
        guard TextRules.words(inserted).contains(old.lowercased()) else { return nil }
        guard EvalScoring.similarity(old.lowercased(), new.lowercased()) >= 0.5 else { return nil }
        let known = dictionary.contains { e in
            e.term.compare(new, options: .caseInsensitive) == .orderedSame && e.heardAs.contains { $0.compare(old, options: .caseInsensitive) == .orderedSame }
        }
        guard !known else { return nil }
        // Csupán egy betű kis/nagy eltérése mondat elején nem tanulnivaló.
        if old.lowercased() == new.lowercased() && p == 0 { return nil }
        return (old, new)
    }

    public static func learn(_ c: (heard: String, term: String), into dict: inout [DictionaryEntry]) {
        if let i = dict.firstIndex(where: { $0.term == c.term }) {
            if !dict[i].heardAs.contains(c.heard) { dict[i].heardAs.append(c.heard) }
        } else {
            dict.append(DictionaryEntry(term: c.term, heardAs: c.heard.lowercased() == c.term.lowercased() ? [] : [c.heard], autoLearned: true))
        }
    }
}
