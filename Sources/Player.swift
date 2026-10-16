import SwiftUI
import AVKit
import MediaPlayer
import Combine

@MainActor
final class MediaPlayerManager: ObservableObject {
    static let shared = MediaPlayerManager()

    let player = AVQueuePlayer()
    @Published private(set) var queue: [URL] = []
    @Published private(set) var index = 0
    @Published private(set) var isPlaying = false
    @Published var position = 0.0
    @Published var duration = 0.0
    @Published var loop = false

    private var timeObserver: Any?
    private var bag = Set<AnyCancellable>()

    var current: URL? { queue.indices.contains(index) ? queue[index] : nil }
    var isVideo: Bool { current.map(FileService.shared.isVideo) ?? false }

    private init() {
        player.actionAtItemEnd = .advance

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1),
                                                      queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                position = t.seconds.isFinite ? t.seconds : 0
                let d = player.currentItem?.duration.seconds ?? 0
                duration = d.isFinite ? d : 0
                updateNowPlaying()
            }
        }

        player.publisher(for: \.timeControlStatus)
            .receive(on: RunLoop.main)
            .sink { [weak self] s in self?.isPlaying = (s == .playing); self?.updateNowPlaying() }
            .store(in: &bag)

        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.itemEnded() }
            .store(in: &bag)

        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] n in
                guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
                let opts = (n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                    .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
                if opts.contains(.shouldResume) { self?.player.play() }
            }
            .store(in: &bag)

        setupRemoteCommands()
    }

    // MARK: Transport

    func play(_ urls: [URL], startAt i: Int = 0) {
        guard urls.indices.contains(i) else { return }
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default)      // needs UIBackgroundModes = audio
        try? s.setActive(true)
        queue = urls
        rebuild(from: i)
        player.play()
    }

    private func rebuild(from i: Int) {
        index = i
        player.removeAllItems()
        for u in queue[i...] { player.insert(AVPlayerItem(url: u), after: nil) }
    }

    func toggle() { isPlaying ? player.pause() : player.play() }

    func next() {
        if index < queue.count - 1 { rebuild(from: index + 1); player.play() }
        else if loop { rebuild(from: 0); player.play() }
    }

    func previous() {
        if position > 3 || index == 0 { seek(0) } else { rebuild(from: index - 1); player.play() }
    }

    func seek(_ seconds: Double) { player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) }

    private func itemEnded() {
        if index < queue.count - 1 { index += 1 }          // AVQueuePlayer already advanced
        else if loop { rebuild(from: 0); player.play() }
        updateNowPlaying()
    }

    // MARK: Lock screen / Control Center

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.player.play(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.player.pause(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.toggle(); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            if let e = e as? MPChangePlaybackPositionCommandEvent { self?.seek(e.positionTime) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let u = current else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: u.deletingPathExtension().lastPathComponent,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
    }
}

// MARK: - UI

/// AVPlayerViewController gives the native controls, including the PiP button.
struct VideoSurface: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true   // PiP when the app goes to background
        return vc
    }
    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}
}

struct PlayerView: View {
    @ObservedObject var pm = MediaPlayerManager.shared

    var body: some View {
        VStack(spacing: 16) {
            if pm.isVideo {
                VideoSurface(player: pm.player).aspectRatio(16 / 9, contentMode: .fit)
            } else {
                Image(systemName: "music.note").font(.system(size: 80))
                    .frame(maxWidth: .infinity, minHeight: 220)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
            }
            Text(pm.current?.deletingPathExtension().lastPathComponent ?? "Nothing playing")
                .font(.headline).lineLimit(2)
            Slider(value: Binding(get: { pm.position }, set: { pm.position = $0 }),
                   in: 0...max(pm.duration, 1)) { editing in
                if !editing { pm.seek(pm.position) }
            }
            HStack(spacing: 34) {
                Button { pm.loop.toggle() } label: { Image(systemName: pm.loop ? "repeat.circle.fill" : "repeat.circle") }
                Button { pm.previous() } label: { Image(systemName: "backward.fill") }
                Button { pm.toggle() } label: {
                    Image(systemName: pm.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 54))
                }
                Button { pm.next() } label: { Image(systemName: "forward.fill") }
            }
            .font(.title)
            Spacer()
        }
        .padding()
    }
}

struct MiniPlayerBar: View {
    @ObservedObject var pm = MediaPlayerManager.shared
    let onTap: () -> Void
    var body: some View {
        HStack {
            Text(pm.current?.deletingPathExtension().lastPathComponent ?? "").lineLimit(1)
            Spacer()
            Button { pm.toggle() } label: { Image(systemName: pm.isPlaying ? "pause.fill" : "play.fill") }
            Button { pm.next() } label: { Image(systemName: "forward.fill") }
        }
        .padding(12)
        .background(.regularMaterial)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}
