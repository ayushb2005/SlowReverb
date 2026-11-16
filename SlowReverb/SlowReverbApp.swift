import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import Security
import MediaPlayer

enum APIKeychain {
    private static let service = Bundle.main.bundleIdentifier ?? "com.personal.slowreverb"
    private static let account = "api-bearer-token"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard !token.isEmpty, let data = token.data(using: .utf8) else { return }
        var item = query
        item[kSecValueData as String] = data
        SecItemAdd(item as CFDictionary, nil)
    }
}

struct Track: Identifiable, Codable, Equatable {
    var id: String { filename }
    let filename: String
    var title: String
    var sourceVideoID: String? = nil
    var speed: Double = 0.72
    var reverb: Double = 35
    var url: URL { LibraryStore.directory.appendingPathComponent(filename) }

    enum CodingKeys: String, CodingKey { case filename, title, sourceVideoID, speed, reverb }

    init(filename: String, title: String, sourceVideoID: String? = nil, speed: Double = 0.72, reverb: Double = 35) {
        self.filename = filename
        self.title = title
        self.sourceVideoID = sourceVideoID
        self.speed = speed
        self.reverb = reverb
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        filename = try values.decode(String.self, forKey: .filename)
        title = try values.decode(String.self, forKey: .title)
        sourceVideoID = try values.decodeIfPresent(String.self, forKey: .sourceVideoID)
        speed = try values.decodeIfPresent(Double.self, forKey: .speed) ?? 0.72
        reverb = try values.decodeIfPresent(Double.self, forKey: .reverb) ?? 35
    }
}

@MainActor
final class LibraryStore: ObservableObject {
    nonisolated static let directory: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Songs", isDirectory: true)
    }()

    @Published private(set) var tracks: [Track] = []
    private var manifest: URL { Self.directory.appendingPathComponent("library.json") }

    init() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        load()
    }

    func importFile(from source: URL, title: String? = nil) throws {
        guard source.startAccessingSecurityScopedResource() else {
            _ = try copyAudio(from: source, title: title)
            return
        }
        defer { source.stopAccessingSecurityScopedResource() }
        _ = try copyAudio(from: source, title: title)
    }

    func track(downloadedFrom videoID: String) -> Track? {
        tracks.first { $0.sourceVideoID == videoID }
    }

    func updateEffects(for trackID: String, speed: Double, reverb: Double) {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        tracks[index].speed = min(max(speed, 0.5), 1.0)
        tracks[index].reverb = min(max(reverb, 0), 100)
        save()
    }

    func rename(_ track: Track, to newTitle: String) {
        let cleanedTitle = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTitle.isEmpty,
              let index = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        tracks[index].title = cleanedTitle
        tracks.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        save()
    }

    func addDownloadedFile(from temporaryURL: URL, title: String, sourceVideoID: String) throws -> Track {
        if let existing = track(downloadedFrom: sourceVideoID) { return existing }
        return try copyAudio(from: temporaryURL, title: title, sourceVideoID: sourceVideoID)
    }

    private func copyAudio(from source: URL, title: String?, sourceVideoID: String? = nil) throws -> Track {
        let ext = source.pathExtension.isEmpty ? "mp3" : source.pathExtension
        let base = (title ?? source.deletingPathExtension().lastPathComponent)
            .replacingOccurrences(of: "/", with: "-")
        var filename = "\(base).\(ext)"
        var counter = 2
        while FileManager.default.fileExists(atPath: Self.directory.appendingPathComponent(filename).path) {
            filename = "\(base) (\(counter)).\(ext)"
            counter += 1
        }
        let destination = Self.directory.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: source, to: destination)
        let track = Track(filename: filename, title: destination.deletingPathExtension().lastPathComponent, sourceVideoID: sourceVideoID)
        tracks.append(track)
        tracks.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        save()
        return track
    }

    func remove(_ track: Track) {
        try? FileManager.default.removeItem(at: track.url)
        tracks.removeAll { $0 == track }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: manifest),
              let saved = try? JSONDecoder().decode([Track].self, from: data) else { return }
        tracks = saved.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(tracks) else { return }
        try? data.write(to: manifest, options: .atomic)
    }
}

@MainActor
final class AudioPlayer: ObservableObject {
    @Published private(set) var current: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: Double = 0
    @Published var position: Double = 0
    @Published var speed: Double = 0.72 { didSet { varispeed.rate = Float(speed) } }
    @Published var reverb: Double = 35 { didSet { reverbUnit.wetDryMix = Float(reverb) } }

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let varispeed = AVAudioUnitVarispeed()
    private let reverbUnit = AVAudioUnitReverb()
    private var audioFile: AVAudioFile?
    private var timer: Timer?
    private var hasScheduledAudio = false
    private var playbackGeneration: UInt = 0
    private var libraryTracks: [Track] = []
    private var didAttemptCheckpointRestore = false
    private var lastCheckpointBucket = -1
    private let remoteCommandCenter = MPRemoteCommandCenter.shared()
    private var lastNowPlayingSecond = -1
    private let checkpointTrackKey = "playbackCheckpointTrack"
    private let checkpointPositionKey = "playbackCheckpointPosition"

    init() {
        engine.attach(playerNode)
        engine.attach(varispeed)
        engine.attach(reverbUnit)
        engine.connect(playerNode, to: varispeed, format: nil)
        engine.connect(varispeed, to: reverbUnit, format: nil)
        engine.connect(reverbUnit, to: engine.mainMixerNode, format: nil)
        reverbUnit.loadFactoryPreset(.largeHall)
        reverbUnit.wetDryMix = Float(reverb)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
        configureRemoteCommands()
    }

    private func configureRemoteCommands() {
        remoteCommandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.resume() }
            return .success
        }
        remoteCommandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.pause() }
            return .success
        }
        remoteCommandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.toggle() }
            return .success
        }
        remoteCommandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.playNext(in: self.libraryTracks, direction: -1)
            }
            return .success
        }
        remoteCommandCenter.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.playNext(in: self.libraryTracks)
            }
            return .success
        }
        updateRemoteCommandAvailability()
    }

    func setLibraryTracks(_ tracks: [Track]) {
        libraryTracks = tracks
        if let current, let updated = tracks.first(where: { $0.id == current.id }) {
            self.current = updated
        }
        if !didAttemptCheckpointRestore {
            didAttemptCheckpointRestore = true
            restoreCheckpoint(from: tracks)
        }
        updateRemoteCommandAvailability()
    }

    func play(_ track: Track) {
        do {
            if current == track, !isPlaying { resume(); return }
            saveCheckpoint()
            stopScheduledPlayback()
            timer?.invalidate()
            let file = try AVAudioFile(forReading: track.url)
            audioFile = file
            current = track
            duration = Double(file.length) / file.processingFormat.sampleRate
            position = 0
            lastCheckpointBucket = 0
            lastNowPlayingSecond = -1
            speed = track.speed
            reverb = track.reverb
            startSegment(at: 0)
            saveCheckpoint()
        } catch {
            isPlaying = false
        }
    }

    func toggle() {
        if isPlaying { pause() }
        else if current != nil { resume() }
    }

    private func pause() {
        guard current != nil else { return }
        playerNode.pause()
        isPlaying = false
        timer?.invalidate()
        saveCheckpoint()
        updateNowPlayingInfo()
    }

    func stopAndClear() {
        stopScheduledPlayback()
        timer?.invalidate()
        timer = nil
        audioFile = nil
        isPlaying = false
        current = nil
        position = 0
        duration = 0
        clearCheckpoint()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        updateRemoteCommandAvailability()
    }

    func playNext(in tracks: [Track], direction: Int = 1) {
        guard !tracks.isEmpty else { return }
        let index = current.flatMap { tracks.firstIndex(of: $0) } ?? 0
        let next = (index + direction + tracks.count) % tracks.count
        play(tracks[next])
    }

    func seek(to seconds: Double) {
        guard let file = audioFile else { return }
        let target = min(max(seconds, 0), duration)
        let wasPlaying = isPlaying
        stopScheduledPlayback()
        timer?.invalidate()
        position = target
        lastCheckpointBucket = Int(position) / 5
        schedule(file, from: target)
        if wasPlaying, hasScheduledAudio { playerNode.play(); isPlaying = true; startTimer() }
        else { isPlaying = false }
        saveCheckpoint()
        updateNowPlayingInfo()
    }

    private func resume() {
        guard let audioFile else { return }
        if !engine.isRunning { try? engine.start() }
        if !hasScheduledAudio || position >= duration {
            stopScheduledPlayback()
            position = 0
            lastCheckpointBucket = 0
            schedule(audioFile, from: position)
        }
        guard hasScheduledAudio else { return }
        playerNode.play()
        isPlaying = true
        startTimer()
        saveCheckpoint()
        updateNowPlayingInfo()
    }

    private func startSegment(at seconds: Double) {
        if !engine.isRunning { try? engine.start() }
        schedule(audioFile!, from: seconds)
        guard hasScheduledAudio else { return }
        playerNode.play()
        isPlaying = true
        startTimer()
        updateNowPlayingInfo()
    }

    private func schedule(_ file: AVAudioFile, from seconds: Double) {
        playbackGeneration &+= 1
        let generation = playbackGeneration
        let sampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(seconds * sampleRate)
        let remaining = max(0, file.length - startFrame)
        guard remaining > 0 else { isPlaying = false; hasScheduledAudio = false; return }
        hasScheduledAudio = true
        playerNode.scheduleSegment(file, startingFrame: startFrame, frameCount: AVAudioFrameCount(remaining), at: nil) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.playbackGeneration == generation else { return }
                self.isPlaying = false
                self.hasScheduledAudio = false
                self.position = self.duration
                self.timer?.invalidate()
                self.saveCheckpoint()
                self.updateNowPlayingInfo()
            }
        }
    }

    private func stopScheduledPlayback() {
        playbackGeneration &+= 1
        playerNode.stop()
        hasScheduledAudio = false
    }

    func saveCheckpoint() {
        guard let current else { return }
        let defaults = UserDefaults.standard
        defaults.set(current.filename, forKey: checkpointTrackKey)
        defaults.set(position, forKey: checkpointPositionKey)
        lastCheckpointBucket = Int(position) / 5
    }

    private func restoreCheckpoint(from tracks: [Track]) {
        let defaults = UserDefaults.standard
        guard let filename = defaults.string(forKey: checkpointTrackKey),
              let track = tracks.first(where: { $0.filename == filename }) else {
            clearCheckpoint()
            return
        }
        do {
            let file = try AVAudioFile(forReading: track.url)
            audioFile = file
            current = track
            duration = Double(file.length) / file.processingFormat.sampleRate
            let savedPosition = defaults.double(forKey: checkpointPositionKey)
            position = savedPosition >= duration ? 0 : min(max(savedPosition, 0), duration)
            lastCheckpointBucket = Int(position) / 5
            speed = track.speed
            reverb = track.reverb
            schedule(file, from: position)
            updateNowPlayingInfo()
        } catch {
            clearCheckpoint()
        }
    }

    private func clearCheckpoint() {
        UserDefaults.standard.removeObject(forKey: checkpointTrackKey)
        UserDefaults.standard.removeObject(forKey: checkpointPositionKey)
    }

    private func updateRemoteCommandAvailability() {
        let hasTrack = current != nil
        remoteCommandCenter.playCommand.isEnabled = hasTrack
        remoteCommandCenter.pauseCommand.isEnabled = hasTrack
        remoteCommandCenter.togglePlayPauseCommand.isEnabled = hasTrack
        let canSkip = hasTrack && libraryTracks.count > 1
        remoteCommandCenter.previousTrackCommand.isEnabled = canSkip
        remoteCommandCenter.nextTrackCommand.isEnabled = canSkip
    }

    private func updateNowPlayingInfo() {
        guard let current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            updateRemoteCommandAvailability()
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: current.title,
            MPMediaItemPropertyMediaType: MPMediaType.music.rawValue,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? speed : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: speed
        ]
        info[MPMediaItemPropertyArtist] = "SlowReverb"
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        updateRemoteCommandAvailability()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }
                self.position = min(self.duration, self.position + 0.2 * self.speed)
                if self.position >= self.duration {
                    self.isPlaying = false
                    self.timer?.invalidate()
                    self.saveCheckpoint()
                    self.updateNowPlayingInfo()
                } else if Int(self.position) != self.lastNowPlayingSecond {
                    self.lastNowPlayingSecond = Int(self.position)
                    self.updateNowPlayingInfo()
                }
                if Int(self.position) / 5 != self.lastCheckpointBucket { self.saveCheckpoint() }
            }
        }
    }
}

struct SearchResult: Identifiable, Decodable {
    var id: String { videoID }
    let videoID: String
    let title: String
    let channelTitle: String
    let thumbnailURL: URL?
    let viewCount: Int

    enum CodingKeys: String, CodingKey {
        case videoID = "video_id", title
        case channelTitle = "channel_title"
        case thumbnailURL = "thumbnail_url"
        case viewCount = "view_count"
    }
}

struct ConversionJob: Decodable {
    let id: String
    let status: String
    let error: String?
}

enum APIError: LocalizedError {
    case invalidURL, badResponse, server(String)
    var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a valid HTTPS API URL in Search."
        case .badResponse: "The server returned an unexpected response."
        case .server(let message): message
        }
    }
}

struct SlowReverbAPI {
    let baseURL: String
    let token: String
    private var root: URL? { URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) }

    private func authorizedRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    func search(_ query: String) async throws -> [SearchResult] {
        guard let root, var components = URLComponents(url: root.appendingPathComponent("search"), resolvingAgainstBaseURL: false) else { throw APIError.invalidURL }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { throw APIError.invalidURL }
        let (data, response) = try await URLSession.shared.data(for: authorizedRequest(url))
        try validate(response, data: data)
        return try JSONDecoder().decode([SearchResult].self, from: data)
    }

    func download(videoID: String, title: String) async throws -> URL {
        guard let root else { throw APIError.invalidURL }
        var request = authorizedRequest(root.appendingPathComponent("conversions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["video_id": videoID])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        let job = try JSONDecoder().decode(ConversionJob.self, from: data)
        for _ in 0..<150 {
            try await Task.sleep(for: .seconds(2))
            let (statusData, statusResponse) = try await URLSession.shared.data(for: authorizedRequest(root.appendingPathComponent("conversions/\(job.id)")))
            try validate(statusResponse, data: statusData)
            let status = try JSONDecoder().decode(ConversionJob.self, from: statusData)
            if status.status == "failed" { throw APIError.server(status.error ?? "Conversion failed.") }
            if status.status == "completed" {
                let endpoint = root.appendingPathComponent("conversions/\(job.id)/download")
                let (temp, audioResponse) = try await URLSession.shared.download(for: authorizedRequest(endpoint))
                try validate(audioResponse, data: Data())
                let localTemp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp3")
                try FileManager.default.moveItem(at: temp, to: localTemp)
                return localTemp
            }
        }
        throw APIError.server("Conversion timed out. Try again later.")
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            if let detail = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let message = detail["detail"] as? String { throw APIError.server(message) }
            throw APIError.server("Request failed (HTTP \(http.statusCode)).")
        }
    }
}

@main
struct SlowReverbApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var player = AudioPlayer()
    var body: some Scene {
        WindowGroup {
            MainView().environmentObject(library).environmentObject(player)
                .tint(Color(red: 0.75, green: 0.43, blue: 0.30))
        }
    }
}

struct MainView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    @State private var showingImporter = false
    @State private var alertMessage: String?

    var body: some View {
        TabView(selection: $selectedTab) {
            LibraryView(showingImporter: $showingImporter).tabItem { Label("Library", systemImage: "music.note.list") }.tag(0)
            YouTubeSearchView(onSongAdded: { selectedTab = 0 })
                .tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(1)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let current = player.current { MiniPlayer(track: current) }
        }
        .onAppear { player.setLibraryTracks(library.tracks) }
        .onChange(of: library.tracks) { _, tracks in player.setLibraryTracks(tracks) }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { player.saveCheckpoint() }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            do {
                for url in try result.get() { try library.importFile(from: url) }
            } catch { alertMessage = error.localizedDescription }
        }
        .alert("Something went wrong", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button("OK", role: .cancel) { alertMessage = nil }
        } message: { Text(alertMessage ?? "") }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: AudioPlayer
    @Binding var showingImporter: Bool
    @State private var query = ""
    @State private var showingRename = false
    @State private var trackToRename: Track?
    @State private var renameTitle = ""
    private var filtered: [Track] { library.tracks.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) } }

    var body: some View {
        NavigationStack {
            Group {
                if filtered.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "Your library is empty" : "No matching songs", systemImage: "music.note", description: Text(query.isEmpty ? "Import an audio file or search for a song." : "Try a different search."))
                } else {
                    List(filtered) { track in
                        HStack(spacing: 8) {
                            Button { player.play(track) } label: { TrackRow(track: track, isPlaying: player.current == track && player.isPlaying) }
                                .buttonStyle(.plain)
                            Menu {
                                Button("Rename", systemImage: "pencil") {
                                    trackToRename = track
                                    renameTitle = track.title
                                    showingRename = true
                                }
                                Button("Delete", systemImage: "trash", role: .destructive) { library.remove(track) }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 32, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("Song options")
                        }
                            .swipeActions { Button("Delete", role: .destructive) { library.remove(track) } }
                    }.listStyle(.plain)
                }
            }
            .navigationTitle("My Songs")
            .searchable(text: $query, prompt: "Search your songs")
            .alert("Rename song", isPresented: $showingRename) {
                TextField("Song name", text: $renameTitle)
                Button("Cancel", role: .cancel) { trackToRename = nil }
                Button("Save") {
                    if let trackToRename { library.rename(trackToRename, to: renameTitle) }
                    trackToRename = nil
                }
                .disabled(renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                Text("Choose a name for this song.")
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingImporter = true } label: { Image(systemName: "plus") }.accessibilityLabel("Import audio")
                }
            }
        }
    }
}

struct TrackRow: View {
    let track: Track
    let isPlaying: Bool
    var body: some View {
        HStack(spacing: 13) {
            RoundedRectangle(cornerRadius: 11).fill(Color.orange.opacity(0.15)).frame(width: 44, height: 44)
                .overlay(Image(systemName: isPlaying ? "waveform" : "music.note").foregroundStyle(.orange))
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title).font(.body.weight(.medium)).lineLimit(1)
                Text(track.url.pathExtension.uppercased()).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isPlaying { Image(systemName: "speaker.wave.2.fill").foregroundStyle(.orange) }
        }
        .contentShape(Rectangle()).padding(.vertical, 4)
    }
}

struct MiniPlayer: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: AudioPlayer
    let track: Track
    @State private var showingEffects = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "waveform").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("\(player.speed, specifier: "%.2f")× speed · reverb \(Int(player.reverb))%").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button { player.playNext(in: library.tracks, direction: -1) } label: { Image(systemName: "backward.end.fill") }
                Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3) }
                Button { player.playNext(in: library.tracks) } label: { Image(systemName: "forward.end.fill") }
                Button { player.stopAndClear() } label: { Image(systemName: "xmark.circle").font(.title3).foregroundStyle(.secondary) }
                    .accessibilityLabel("Stop and dismiss player")
            }.buttonStyle(.plain)
            Slider(value: $player.position, in: 0...max(player.duration, 0.01)) { editing in if !editing { player.seek(to: player.position) } }
                .tint(.orange)
            HStack {
                Text(timeString(player.position)); Spacer()
                Button { showingEffects = true } label: { Label("Effects", systemImage: "slider.horizontal.3").font(.caption) }
                Spacer(); Text(timeString(player.duration))
            }.font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
        .background(.regularMaterial)
        .sheet(isPresented: $showingEffects) { EffectsView().presentationDetents([.medium]) }
    }
}

struct EffectPreset: Identifiable {
    let name: String
    let speed: Double
    let reverb: Double
    var id: String { name }

    static let all: [EffectPreset] = [
        EffectPreset(name: "Original", speed: 1.00, reverb: 0),
        EffectPreset(name: "Subtle", speed: 0.90, reverb: 20),
        EffectPreset(name: "Slow Jam", speed: 0.75, reverb: 40),
        EffectPreset(name: "Dreamy", speed: 0.65, reverb: 70),
        EffectPreset(name: "Washed Out", speed: 0.60, reverb: 90)
    ]
}

struct EffectsView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: AudioPlayer
    var body: some View {
        NavigationStack {
            Form {
                Section("Presets") {
                    ForEach(EffectPreset.all) { preset in
                        Button {
                            player.speed = preset.speed
                            player.reverb = preset.reverb
                            saveSettings()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(preset.name).foregroundStyle(.primary)
                                    Text("\(preset.speed, specifier: "%.2f")× speed · \(Int(preset.reverb))% reverb")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if abs(player.speed - preset.speed) < 0.005 && Int(player.reverb.rounded()) == Int(preset.reverb) {
                                    Image(systemName: "checkmark").foregroundStyle(.orange)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section("Slow") {
                    HStack { Text("Speed"); Spacer(); Text("\(player.speed, specifier: "%.2f")×").foregroundStyle(.secondary) }
                    Slider(value: $player.speed, in: 0.5...1.0, step: 0.01)
                }
                Section("Reverb") {
                    HStack { Text("Amount"); Spacer(); Text("\(Int(player.reverb))%").foregroundStyle(.secondary) }
                    Slider(value: $player.reverb, in: 0...100, step: 1)
                }
                Section { Text("Effects apply while playing. Your saved song stays unchanged.").font(.footnote).foregroundStyle(.secondary) }
            }.navigationTitle("Playback Effects").navigationBarTitleDisplayMode(.inline)
                .onChange(of: player.speed) { _, _ in saveSettings() }
                .onChange(of: player.reverb) { _, _ in saveSettings() }
        }
    }

    private func saveSettings() {
        guard let current = player.current else { return }
        library.updateEffects(for: current.id, speed: player.speed, reverb: player.reverb)
    }
}

struct YouTubeSearchView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: AudioPlayer
    let onSongAdded: () -> Void
    @AppStorage("apiBaseURL") private var apiBaseURL = "http://127.0.0.1:8000"
    @State private var apiToken = APIKeychain.load() ?? ""
    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var isSearching = false
    @State private var convertingID: String?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search YouTube songs", text: $query).submitLabel(.search).onSubmit { Task { await search() } }
                        if isSearching { ProgressView() }
                        else { Button("Search") { Task { await search() } }.disabled(query.trimmingCharacters(in: .whitespaces).isEmpty) }
                    }
                    .padding(12).background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    DisclosureGroup("API server") {
                        TextField("http://127.0.0.1:8000", text: $apiBaseURL).textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                            .font(.footnote).padding(.top, 8)
                        SecureField("API access token", text: $apiToken)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .font(.footnote)
                            .onChange(of: apiToken) { _, newValue in APIKeychain.save(newValue) }
                    }.font(.caption).foregroundStyle(.secondary)
                }.padding()

                if results.isEmpty && !isSearching {
                    ContentUnavailableView("Find a song", systemImage: "magnifyingglass", description: Text("Search YouTube, then choose a result to add its MP3 to your library."))
                } else {
                    List(results) { result in
                            SearchResultRow(result: result, isConverting: convertingID == result.id, isDisabled: convertingID != nil) {
                            beginConversion(result)
                        }
                    }.listStyle(.plain)
                }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary).padding(.horizontal).padding(.bottom, 8) }
            }
            .navigationTitle("Search")
            .toolbar { if !library.tracks.isEmpty { ToolbarItem(placement: .topBarTrailing) { Text("\(library.tracks.count) songs").font(.caption).foregroundStyle(.secondary) } } }
        }
    }

    private func search() async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        isSearching = true; message = nil
        defer { isSearching = false }
        do { results = try await SlowReverbAPI(baseURL: apiBaseURL, token: apiToken).search(term) }
        catch { results = []; message = error.localizedDescription }
    }

    private func beginConversion(_ result: SearchResult) {
        guard convertingID == nil else { return }
        if let existing = library.track(downloadedFrom: result.videoID) {
            player.play(existing)
            message = "Already in your library. Playing “\(existing.title)”."
            onSongAdded()
            return
        }
        convertingID = result.id
        Task { await convert(result) }
    }

    private func convert(_ result: SearchResult) async {
        message = "Converting “\(result.title)”…"
        defer { convertingID = nil }
        do {
            let file = try await SlowReverbAPI(baseURL: apiBaseURL, token: apiToken).download(videoID: result.videoID, title: result.title)
            let track = try library.addDownloadedFile(from: file, title: result.title, sourceVideoID: result.videoID)
            try? FileManager.default.removeItem(at: file)
            message = "Added “\(result.title)” to your library."
            player.play(track)
            onSongAdded()
        } catch { message = error.localizedDescription }
    }
}

struct SearchResultRow: View {
    let result: SearchResult
    let isConverting: Bool
    let isDisabled: Bool
    let action: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: result.thumbnailURL) { image in image.resizable().scaledToFill() } placeholder: {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary).overlay(Image(systemName: "music.note"))
            }.frame(width: 76, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(result.title).font(.subheadline.weight(.medium)).lineLimit(2)
                Text(result.channelTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text("\(result.viewCount.formatted()) views").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Button(action: action) {
                if isConverting { ProgressView() } else { Image(systemName: "arrow.down.circle.fill").font(.title2) }
            }.disabled(isDisabled).accessibilityLabel(isConverting ? "Converting \(result.title)" : "Convert and add \(result.title)")
        }.padding(.vertical, 5)
    }
}

func timeString(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "0:00" }
    let total = max(0, Int(seconds))
    return "\(total / 60):\(String(format: "%02d", total % 60))"
}
