import Foundation
import Compression

/// Minimaler ZIP-Entpacker (reicht für EPUBs: "stored" und "deflate").
enum ZipArchive {
    static func extract(_ archive: URL, to destination: URL) throws {
        let bytes = [UInt8](try Data(contentsOf: archive, options: .mappedIfSafe))
        guard bytes.count > 22 else { throw BabelError.epub("Datei ist zu klein") }

        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }

        // End of Central Directory suchen (vom Ende her)
        var eocd = -1
        var i = bytes.count - 22
        let lowest = max(0, bytes.count - 65_557)
        while i >= lowest {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw BabelError.epub("Kein gültiges ZIP-Archiv") }

        let entryCount = u16(eocd + 10)
        var offset = u32(eocd + 16)
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let root = destination.standardizedFileURL.path

        for _ in 0..<entryCount {
            guard offset + 46 <= bytes.count, u32(offset) == 0x0201_4B50 else { throw BabelError.epub("Beschädigtes Inhaltsverzeichnis") }
            let method = u16(offset + 10)
            let compressedSize = u32(offset + 20)
            let size = u32(offset + 24)
            let nameLength = u16(offset + 28)
            let extraLength = u16(offset + 30)
            let commentLength = u16(offset + 32)
            let localOffset = u32(offset + 42)
            guard offset + 46 + nameLength + extraLength + commentLength <= bytes.count else {
                throw BabelError.epub("Beschädigtes Inhaltsverzeichnis")
            }
            let nameBytes = Array(bytes[(offset + 46)..<(offset + 46 + nameLength)])
            let name = String(decoding: nameBytes, as: UTF8.self)
            offset += 46 + nameLength + extraLength + commentLength

            // Pfad absichern
            let clean = name.split(separator: "/").filter { $0 != ".." && $0 != "." }.joined(separator: "/")
            guard !clean.isEmpty else { continue }
            let target = destination.appendingPathComponent(clean)
            guard target.standardizedFileURL.path.hasPrefix(root) else { continue }

            if name.hasSuffix("/") {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }

            guard localOffset + 30 <= bytes.count, u32(localOffset) == 0x0403_4B50 else { throw BabelError.epub("Beschädigter Eintrag \(name)") }
            let dataStart = localOffset + 30 + u16(localOffset + 26) + u16(localOffset + 28)
            guard dataStart + compressedSize <= bytes.count else { throw BabelError.epub("Abgeschnittene Datei") }

            let output: Data
            switch method {
            case 0:
                output = Data(bytes[dataStart..<(dataStart + compressedSize)])
            case 8:
                output = try inflate(bytes, start: dataStart, length: compressedSize, expected: size)
            default:
                continue
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try output.write(to: target)
        }
    }

    private static func inflate(_ bytes: [UInt8], start: Int, length: Int, expected: Int) throws -> Data {
        if expected == 0 { return Data() }
        var out = [UInt8](repeating: 0, count: expected)
        let written = bytes.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                // COMPRESSION_ZLIB entspricht rohem DEFLATE (ohne zlib-Header) – genau wie in ZIP.
                compression_decode_buffer(dst.baseAddress!, expected, src.baseAddress! + start, length, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { throw BabelError.epub("Entpacken fehlgeschlagen") }
        return Data(out.prefix(written))
    }
}
