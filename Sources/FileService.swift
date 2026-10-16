import Foundation

enum AppFolder: String, CaseIterable {
    case downloads = "Downloads", music = "Music", videos = "Videos"
    case documents = "Documents", playlists = "Playlists"
}

enum SortKey: String, CaseIterable { case name, date, size, type }

final class FileService {
    static let shared = FileService()
    static let appName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? "Offline Player"

    /// Root = the app's Documents directory, which Files shows under "On My iPhone > <App Name>".
    let root = URL.documentsDirectory
    private let fm = FileManager.default

    static let videoExts: Set<String> = ["mp4", "mov", "m4v"]
    static let audioExts: Set<String> = ["mp3", "aac", "wav", "m4a"]

    func url(for folder: AppFolder) -> URL {
        root.appending(path: folder.rawValue, directoryHint: .isDirectory)
    }

    func bootstrap() {
        AppFolder.allCases.forEach {
            try? fm.createDirectory(at: url(for: $0), withIntermediateDirectories: true)
        }
    }

    // MARK: Naming

    func sanitized(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters)
        let s = name.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "file" : s
    }

    func uniqueURL(in dir: URL, filename: String) -> URL {
        var candidate = dir.appending(path: filename)
        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var n = 1
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appending(path: ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    // MARK: Operations

    @discardableResult
    func moveToDownloads(_ tmp: URL, name: String) throws -> URL {
        let dest = uniqueURL(in: url(for: .downloads), filename: name)
        try fm.moveItem(at: tmp, to: dest)
        return dest
    }

    func rename(_ u: URL, to new: String) throws -> URL {
        let dest = u.deletingLastPathComponent().appending(path: sanitized(new))
        try fm.moveItem(at: u, to: dest)
        return dest
    }

    func move(_ u: URL, into dir: URL) throws {
        try fm.moveItem(at: u, to: uniqueURL(in: dir, filename: u.lastPathComponent))
    }

    func delete(_ u: URL) { try? fm.removeItem(at: u) }

    func createFolder(named n: String, in dir: URL) {
        try? fm.createDirectory(at: dir.appending(path: sanitized(n), directoryHint: .isDirectory),
                                withIntermediateDirectories: true)
    }

    /// Copy a file picked with fileImporter (security-scoped) into the app folder.
    func importCopy(_ src: URL, into dir: URL) throws {
        let ok = src.startAccessingSecurityScopedResource()
        defer { if ok { src.stopAccessingSecurityScopedResource() } }
        try fm.copyItem(at: src, to: uniqueURL(in: dir, filename: src.lastPathComponent))
    }

    // MARK: Listing

    func isDir(_ u: URL) -> Bool { (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
    func size(_ u: URL) -> Int { (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
    func date(_ u: URL) -> Date {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
    func isVideo(_ u: URL) -> Bool { Self.videoExts.contains(u.pathExtension.lowercased()) }
    func isMedia(_ u: URL) -> Bool {
        let e = u.pathExtension.lowercased()
        return Self.videoExts.contains(e) || Self.audioExts.contains(e)
    }

    func list(_ dir: URL, sort: SortKey) -> [URL] {
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                 options: .skipsHiddenFiles)) ?? []
        return items.sorted { a, b in
            if isDir(a) != isDir(b) { return isDir(a) }           // folders first
            switch sort {
            case .name: return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
            case .date: return date(a) > date(b)
            case .size: return size(a) > size(b)
            case .type: return a.pathExtension.lowercased() < b.pathExtension.lowercased()
            }
        }
    }

    func allFolders() -> [URL] {
        var out = [root]
        if let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) {
            for case let u as URL in e where isDir(u) { out.append(u) }
        }
        return out
    }

    func relative(_ u: URL) -> String { u.path.replacingOccurrences(of: root.path + "/", with: "") }
    func absolute(_ rel: String) -> URL { root.appending(path: rel) }
}
