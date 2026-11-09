import Foundation

public enum WAV {
    /// 16 bites PCM mono WAV a megadott mintavételezéssel.
    /// Egyetlen lefoglalt pufferbe ír (a mintánkénti `Data.append` hosszú felvételnél a stop utáni úton állt).
    public static func encode(samples: [Int16], sampleRate: Int = 16_000) -> Data {
        let dataBytes = samples.count * 2
        var d = Data(count: 44 + dataBytes)
        d.withUnsafeMutableBytes { raw in
            let b = raw.bindMemory(to: UInt8.self).baseAddress!
            func put(_ s: String, _ i: Int) { for (k, c) in s.utf8.enumerated() { b[i + k] = c } }
            func u32(_ v: UInt32, _ i: Int) {
                let x = v.littleEndian
                b[i] = UInt8(truncatingIfNeeded: x)
                b[i + 1] = UInt8(truncatingIfNeeded: x >> 8)
                b[i + 2] = UInt8(truncatingIfNeeded: x >> 16)
                b[i + 3] = UInt8(truncatingIfNeeded: x >> 24)
            }
            func u16(_ v: UInt16, _ i: Int) {
                let x = v.littleEndian
                b[i] = UInt8(truncatingIfNeeded: x)
                b[i + 1] = UInt8(truncatingIfNeeded: x >> 8)
            }
            put("RIFF", 0); u32(UInt32(36 + dataBytes), 4); put("WAVE", 8)
            put("fmt ", 12); u32(16, 16); u16(1, 20); u16(1, 22); u32(UInt32(sampleRate), 24); u32(UInt32(sampleRate * 2), 28); u16(2, 32); u16(16, 34)
            put("data", 36); u32(UInt32(dataBytes), 40)
            samples.withUnsafeBufferPointer { src in
                guard let sp = src.baseAddress else { return }
                let dp = raw.baseAddress!.advanced(by: 44).assumingMemoryBound(to: Int16.self)
                for i in 0..<src.count { dp[i] = sp[i].littleEndian }
            }
        }
        return d
    }

    public static func floatToInt16(_ f: [Float]) -> [Int16] {
        f.map { Int16(max(-1, min(1, $0)) * 32767) }
    }

    /// RMS 0…1 tartományban, a hullámformához.
    public static func level(_ f: UnsafeBufferPointer<Float>) -> Float {
        guard !f.isEmpty else { return 0 }
        var sum: Float = 0
        for v in f { sum += v * v }
        let rms = sqrt(sum / Float(f.count))
        // dB-szerű görbe: −50 dB → 0, −10 dB → 1
        let db = 20 * log10(max(rms, 1e-6))
        return max(0, min(1, (db + 50) / 40))
    }
}

public enum EnvFile {
    /// Egy kulcs értéke egy .env tartalomból. Az értéket soha nem naplózzuk.
    public static func value(for key: String, in contents: String) -> String? {
        for rawLine in contents.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.isEmpty { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard k == key else { continue }
            var v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
                v = String(v.dropFirst().dropLast())
            } else if let hash = v.range(of: " #") {
                v = String(v[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            return v.isEmpty ? nil : v
        }
        return nil
    }

    public static func keys(in contents: String) -> [String] {
        contents.components(separatedBy: .newlines).compactMap { raw in
            var l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("#") { return nil }
            if l.hasPrefix("export ") { l = String(l.dropFirst(7)) }
            guard let eq = l.firstIndex(of: "=") else { return nil }
            let k = l[..<eq].trimmingCharacters(in: .whitespaces)
            return k.isEmpty ? nil : k
        }
    }
}

public enum WordDiff {
    public enum Op: Equatable, Sendable { case same(String), added(String), removed(String) }

    /// Szószintű diff (LCS) a „Változások” nézethez.
    public static func diff(_ a: String, _ b: String) -> [Op] {
        let x = a.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let y = b.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let n = x.count, m = y.count
        if n * m > 4_000_000 { return [.removed(a), .added(b)] }
        var t = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    t[i][j] = x[i] == y[j] ? t[i + 1][j + 1] + 1 : max(t[i + 1][j], t[i][j + 1])
                }
            }
        }
        var ops: [Op] = []; var i = 0, j = 0
        while i < n && j < m {
            if x[i] == y[j] { ops.append(.same(x[i])); i += 1; j += 1 }
            else if t[i + 1][j] >= t[i][j + 1] { ops.append(.removed(x[i])); i += 1 }
            else { ops.append(.added(y[j])); j += 1 }
        }
        while i < n { ops.append(.removed(x[i])); i += 1 }
        while j < m { ops.append(.added(y[j])); j += 1 }
        return ops
    }
}
