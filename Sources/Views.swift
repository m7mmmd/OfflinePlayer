import SwiftUI
import SwiftData
import PhotosUI
import QuickLook
import UniformTypeIdentifiers

// MARK: - Root

struct RootView: View {
    @StateObject private var browser = BrowserModel()
    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject private var pm = MediaPlayerManager.shared
    @State private var showPlayer = false

    var body: some View {
        TabView {
            BrowserView(browser: browser).tabItem { Label("Browser", systemImage: "safari") }
            NavigationStack { FilesView(directory: FileService.shared.root) }
                .tabItem { Label("Files", systemImage: "folder") }
            NavigationStack { PlaylistsView() }
                .tabItem { Label("Playlists", systemImage: "music.note.list") }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .safeAreaInset(edge: .bottom) {
            if pm.current != nil { MiniPlayerBar { showPlayer = true } }
        }
        .overlay(alignment: .top) {
            if let t = downloads.toast {
                Text(t).font(.footnote).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule()).padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: downloads.toast)
        .sheet(isPresented: $showPlayer) { PlayerView() }
    }
}

// MARK: - Files

/// Videos picked from Photos are copied straight into /Videos.
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { m in SentTransferredFile(m.url) }
        importing: { received in
            let fs = FileService.shared
            let dest = fs.uniqueURL(in: fs.url(for: .videos), filename: received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMovie(url: dest)
        }
    }
}

struct FilesView: View {
    let directory: URL
    private let fs = FileService.shared
    private static let importTypes: [UTType] =
        [.audio, .movie, .image, .pdf, UTType(filenameExtension: "docx") ?? .data]

    @State private var items: [URL] = []
    @State private var sort: SortKey = .name
    @State private var previewURL: URL?
    @State private var renaming: URL?
    @State private var newName = ""
    @State private var moving: URL?
    @State private var showNewFolder = false
    @State private var folderName = ""
    @State private var showImporter = false
    @State private var photoItems: [PhotosPickerItem] = []

    var body: some View {
        List {
            ForEach(items, id: \.self) { u in
                row(u)
                    .swipeActions { Button("Delete", role: .destructive) { fs.delete(u); reload() } }
                    .contextMenu {
                        Button("Rename", systemImage: "pencil") { renaming = u; newName = u.lastPathComponent }
                        Button("Move", systemImage: "folder") { moving = u }
                    }
            }
        }
        .navigationTitle(directory == fs.root ? FileService.appName : directory.lastPathComponent)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu("Sort", systemImage: "arrow.up.arrow.down") {
                    Picker("Sort", selection: $sort) { ForEach(SortKey.allCases, id: \.self) { Text($0.rawValue.capitalized) } }
                }
                PhotosPicker(selection: $photoItems, matching: .any(of: [.images, .videos])) {
                    Image(systemName: "photo.on.rectangle")
                }
                Menu("Add", systemImage: "plus") {
                    Button("New folder", systemImage: "folder.badge.plus") { folderName = ""; showNewFolder = true }
                    Button("Import files", systemImage: "square.and.arrow.down") { showImporter = true }
                }
            }
        }
        .quickLookPreview($previewURL)     // QLPreviewController under the hood: PDF, DOCX, images
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.importTypes,
                      allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { urls.forEach { try? fs.importCopy($0, into: directory) }; reload() }
        }
        .onChange(of: photoItems) { _, new in
            Task { for i in new { await importPhoto(i) }; photoItems = []; reload() }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") { if let u = renaming { _ = try? fs.rename(u, to: newName); reload() }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("New folder", isPresented: $showNewFolder) {
            TextField("Name", text: $folderName)
            Button("Create") { fs.createFolder(named: folderName, in: directory); reload() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: Binding(get: { moving != nil }, set: { if !$0 { moving = nil } })) {
            FolderPicker { dest in
                if let u = moving { try? fs.move(u, into: dest) }
                moving = nil; reload()
            }
        }
        .onAppear(perform: reload)
        .onChange(of: sort) { reload() }
    }

    @ViewBuilder private func row(_ u: URL) -> some View {
        if fs.isDir(u) {
            NavigationLink { FilesView(directory: u) } label: {
                Label(u.lastPathComponent, systemImage: "folder.fill")
            }
        } else {
            Button { open(u) } label: {
                HStack {
                    Image(systemName: fs.isMedia(u) ? (fs.isVideo(u) ? "film" : "music.note") : "doc")
                    VStack(alignment: .leading) {
                        Text(u.lastPathComponent).lineLimit(1)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(fs.size(u)), countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func open(_ u: URL) {
        if fs.isMedia(u) {
            let media = items.filter(fs.isMedia)
            MediaPlayerManager.shared.play(media, startAt: media.firstIndex(of: u) ?? 0)
        } else {
            previewURL = u
        }
    }

    private func reload() { items = fs.list(directory, sort: sort) }

    private func importPhoto(_ item: PhotosPickerItem) async {
        if (try? await item.loadTransferable(type: PickedMovie.self)) != nil { return }
        if let data = try? await item.loadTransferable(type: Data.self) {
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
            try? data.write(to: fs.uniqueURL(in: fs.url(for: .documents), filename: "Photo.\(ext)"))
        }
    }
}

struct FolderPicker: View {
    let onPick: (URL) -> Void
    var body: some View {
        NavigationStack {
            List(FileService.shared.allFolders(), id: \.self) { f in
                Button {
                    onPick(f)
                } label: {
                    Label(f == FileService.shared.root ? FileService.appName : FileService.shared.relative(f),
                          systemImage: "folder")
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Move to")
        }
    }
}

// MARK: - Playlists

struct PlaylistsView: View {
    @Environment(\.modelContext) private var ctx
    @Query(sort: \Playlist.created) private var lists: [Playlist]
    @State private var showNew = false
    @State private var name = ""

    var body: some View {
        List {
            ForEach(lists) { p in NavigationLink(p.name) { PlaylistDetail(playlist: p) } }
                .onDelete { offsets in offsets.map { lists[$0] }.forEach { ctx.delete($0) } }
        }
        .navigationTitle("Playlists")
        .toolbar { Button("New", systemImage: "plus") { name = ""; showNew = true } }
        .alert("New playlist", isPresented: $showNew) {
            TextField("Name", text: $name)
            Button("Create") { ctx.insert(Playlist(name: name.isEmpty ? "Untitled" : name)) }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct PlaylistDetail: View {
    @Bindable var playlist: Playlist
    @State private var showAdd = false
    @State private var showRename = false
    @State private var newName = ""

    var body: some View {
        List {
            ForEach(Array(playlist.items.enumerated()), id: \.offset) { i, rel in
                Button(FileService.shared.absolute(rel).deletingPathExtension().lastPathComponent) { play(at: i) }
                    .buttonStyle(.plain)
            }
            .onDelete { playlist.items.remove(atOffsets: $0) }
            .onMove { playlist.items.move(fromOffsets: $0, toOffset: $1) }
        }
        .navigationTitle(playlist.name)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                EditButton()
                Button("Play", systemImage: "play.fill") { play(at: 0) }
                Menu("More", systemImage: "ellipsis.circle") {
                    Button("Add media", systemImage: "plus") { showAdd = true }
                    Button("Rename", systemImage: "pencil") { newName = playlist.name; showRename = true }
                }
            }
        }
        .alert("Rename playlist", isPresented: $showRename) {
            TextField("Name", text: $newName)
            Button("Save") { playlist.name = newName }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showAdd) { MediaPicker { playlist.items.append(contentsOf: $0) } }
        .onAppear {   // drop entries whose files were deleted in the Files app
            playlist.items = playlist.items.filter {
                FileManager.default.fileExists(atPath: FileService.shared.absolute($0).path)
            }
        }
    }

    private func play(at i: Int) {
        MediaPlayerManager.shared.play(playlist.items.map(FileService.shared.absolute), startAt: i)
    }
}

struct MediaPicker: View {
    let onDone: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var picked = Set<String>()
    private let files: [URL] = FileService.shared.allFolders()
        .flatMap { FileService.shared.list($0, sort: .name) }
        .filter(FileService.shared.isMedia)

    var body: some View {
        NavigationStack {
            List(files, id: \.self) { u in
                let rel = FileService.shared.relative(u)
                Button {
                    if picked.contains(rel) { picked.remove(rel) } else { picked.insert(rel) }
                } label: {
                    HStack {
                        Image(systemName: picked.contains(rel) ? "checkmark.circle.fill" : "circle")
                        Text(u.lastPathComponent).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Add media")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onDone(files.map(FileService.shared.relative).filter(picked.contains))
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @StateObject private var server = WiFiServer()

    var body: some View {
        NavigationStack {
            Form {
                Section("Wi-Fi transfer") {
                    Toggle("Receive files from a computer",
                           isOn: Binding(get: { server.isRunning }, set: { $0 ? server.start() : server.stop() }))
                    if let a = server.address {
                        Text(a).font(.callout.monospaced()).textSelection(.enabled)
                        Text("Open this address in a browser on the same Wi-Fi network.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("Files app") {
                    Button("Open app folder in Files") {
                        if let u = URL(string: "shareddocuments://\(FileService.shared.root.path)") {
                            UIApplication.shared.open(u)
                        }
                    }
                    Text("Downloads are saved to Files > On My iPhone > \(FileService.appName) > Downloads.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
