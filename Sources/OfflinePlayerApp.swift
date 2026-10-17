import SwiftUI
import SwiftData
import AVFoundation

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
        if let c = try? ModelContainer(for: Playlist.self, DownloadRecord.self) { return c }
        // Fallback so a corrupt store can never crash the app at launch.
        let mem = ModelConfiguration(isStoredInMemoryOnly: true)
        return try! ModelContainer(for: Playlist.self, DownloadRecord.self, configurations: mem)
    }()
}

@main
struct OfflinePlayerApp: App {
    init() {
        FileService.shared.bootstrap()          // creates the folder tree so Files shows it at once
        UserDefaults.standard.register(defaults: ["autoDownload": true])
        // Playback category: sound works with the silent switch on and keeps going in the background.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
    }

    var body: some Scene {
        WindowGroup { RootView() }
            .modelContainer(Persistence.container)
    }
}
