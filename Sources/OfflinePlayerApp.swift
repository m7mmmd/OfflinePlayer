import SwiftUI
import SwiftData

// MARK: - SwiftData models (metadata only; media lives on disk in Documents)

@Model final class Playlist {
    var name: String
    var items: [String]          // paths relative to Documents, so they survive container moves
    var created: Date
    init(name: String) { self.name = name; self.items = []; self.created = .now }
}

@Model final class DownloadRecord {
    var filename: String
    var source: String
    var date: Date
    init(filename: String, source: String) { self.filename = filename; self.source = source; self.date = .now }
}

enum Persistence {
    static let container: ModelContainer = {
        try! ModelContainer(for: Playlist.self, DownloadRecord.self)
    }()
}

@main
struct OfflinePlayerApp: App {
    init() { FileService.shared.bootstrap() }   // creates the folder tree so Files shows it at once

    var body: some Scene {
        WindowGroup { RootView() }
            .modelContainer(Persistence.container)
    }
}
