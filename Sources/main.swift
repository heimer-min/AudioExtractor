import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Job Model
struct ExtractionJob: Identifiable {
    let id = UUID()
    let sourceURL: URL
    var outputURL: URL?
    var status: JobStatus = .queued
    var progress: Double = 0.0
    var errorMessage: String?
    var duration: TimeInterval?
    var fileSize: String?

    var fileName: String { sourceURL.lastPathComponent }
    var outputFileName: String {
        sourceURL.deletingPathExtension().lastPathComponent + "_audio.m4a"
    }
}

enum JobStatus {
    case queued, extracting, done, failed

    var label: String {
        switch self {
        case .queued:     return "대기 중"
        case .extracting: return "추출 중"
        case .done:       return "완료"
        case .failed:     return "실패"
        }
    }

    var color: Color {
        switch self {
        case .queued:     return Color(.systemGray)
        case .extracting: return Color(.systemBlue)
        case .done:       return Color(.systemGreen)
        case .failed:     return Color(.systemRed)
        }
    }
}

// MARK: - ExtractionManager
@MainActor
class ExtractionManager: ObservableObject {
    @Published var jobs: [ExtractionJob] = []
    @Published var isRunning = false
    @Published var outputDirectory: URL?

    private var taskQueue: [UUID] = []

    func addVideos(_ urls: [URL]) {
        let videoTypes = ["mp4","mov","m4v","avi","mkv","webm","flv","wmv","ts","mts","mpg","mpeg"]
        let newJobs = urls
            .filter { videoTypes.contains($0.pathExtension.lowercased()) }
            .filter { url in !jobs.contains(where: { $0.sourceURL == url }) }
            .map { url -> ExtractionJob in
                var job = ExtractionJob(sourceURL: url)
                if let attr = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let size = attr[.size] as? Int64 {
                    job.fileSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                }
                return job
            }
        jobs.append(contentsOf: newJobs)
    }

    func removeJob(id: UUID) {
        jobs.removeAll { $0.id == id }
    }

    func clearCompleted() {
        jobs.removeAll { $0.status == .done || $0.status == .failed }
    }

    func startAll() {
        guard !isRunning else { return }
        taskQueue = jobs.filter { $0.status == .queued || $0.status == .failed }.map { $0.id }
        guard !taskQueue.isEmpty else { return }
        isRunning = true
        processNext()
    }

    private func processNext() {
        guard !taskQueue.isEmpty else {
            isRunning = false
            return
        }
        let nextId = taskQueue.removeFirst()
        guard let idx = jobs.firstIndex(where: { $0.id == nextId }) else {
            processNext()
            return
        }
        extract(jobIndex: idx)
    }

    private func extract(jobIndex: Int) {
        jobs[jobIndex].status = .extracting
        jobs[jobIndex].progress = 0.0

        let job = jobs[jobIndex]
        let sourceURL = job.sourceURL
        let outDir = outputDirectory ?? sourceURL.deletingLastPathComponent()
        let outURL = outDir.appendingPathComponent(job.outputFileName)
        let jobId = job.id

        Task {
            do {
                let asset = AVURLAsset(url: sourceURL)
                let duration = try await asset.load(.duration)
                await MainActor.run {
                    if let i = self.jobs.firstIndex(where: { $0.id == jobId }) {
                        self.jobs[i].duration = duration.seconds
                    }
                }

                let tracks = try await asset.loadTracks(withMediaType: .audio)
                guard !tracks.isEmpty else {
                    throw NSError(domain: "AudioExtractor", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "오디오 트랙이 없습니다"])
                }

                guard let session = AVAssetExportSession(asset: asset,
                                                         presetName: AVAssetExportPresetAppleM4A) else {
                    throw NSError(domain: "AudioExtractor", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Export session 생성 실패"])
                }

                try? FileManager.default.removeItem(at: outURL)
                session.outputURL = outURL
                session.outputFileType = .m4a
                session.audioTimePitchAlgorithm = .spectral

                // Progress polling timer on main thread
                let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    let p = Double(session.progress)
                    if let i = self.jobs.firstIndex(where: { $0.id == jobId }) {
                        self.jobs[i].progress = p
                    }
                }

                // Export via completion handler — avoids async/Sendable issues entirely
                let (exportStatus, exportError) = await withCheckedContinuation { continuation in
                    session.exportAsynchronously {
                        continuation.resume(returning: (session.status, session.error))
                    }
                }

                timer.invalidate()

                await MainActor.run {
                    if let i = self.jobs.firstIndex(where: { $0.id == jobId }) {
                        switch exportStatus {
                        case .completed:
                            self.jobs[i].status = .done
                            self.jobs[i].progress = 1.0
                            self.jobs[i].outputURL = outURL
                        case .failed:
                            self.jobs[i].status = .failed
                            self.jobs[i].errorMessage = exportError?.localizedDescription ?? "Export 실패"
                        case .cancelled:
                            self.jobs[i].status = .failed
                            self.jobs[i].errorMessage = "취소됨"
                        default:
                            self.jobs[i].status = .failed
                            self.jobs[i].errorMessage = "알 수 없는 오류"
                        }
                    }
                    self.processNext()
                }
            } catch {
                await MainActor.run {
                    if let i = self.jobs.firstIndex(where: { $0.id == jobId }) {
                        self.jobs[i].status = .failed
                        self.jobs[i].errorMessage = error.localizedDescription
                    }
                    self.processNext()
                }
            }
        }
    }
}

// MARK: - ContentView
struct ContentView: View {
    @StateObject private var manager = ExtractionManager()
    @State private var isTargeted = false

    var completedCount: Int { manager.jobs.filter { $0.status == .done }.count }
    var failedCount: Int { manager.jobs.filter { $0.status == .failed }.count }
    var totalCount: Int { manager.jobs.count }
    var overallProgress: Double {
        guard totalCount > 0 else { return 0 }
        let sum = manager.jobs.reduce(0.0) { acc, j in
            acc + (j.status == .done ? 1.0 : j.progress)
        }
        return sum / Double(totalCount)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if manager.jobs.isEmpty {
                dropZoneEmpty
            } else {
                VStack(spacing: 0) {
                    jobList
                    Divider()
                    bottomBar
                }
            }
        }
        .background(Color(.windowBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
        .overlay {
            if isTargeted {
                dropOverlay
            }
        }
    }

    var headerBar: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.3, green: 0.5, blue: 1), Color(red: 0.6, green: 0.3, blue: 1)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 36, height: 36)
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Audio Extractor")
                    .font(.system(size: 15, weight: .semibold))
                Text("강의 영상에서 음성만 추출합니다")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.prompt = "선택"
                if panel.runModal() == .OK {
                    manager.outputDirectory = panel.url
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                    Text(manager.outputDirectory?.lastPathComponent ?? "원본 위치")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 150)
                }
                .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = true
                panel.canChooseDirectories = false
                if panel.runModal() == .OK {
                    manager.addVideos(panel.urls)
                }
            } label: {
                Label("파일 추가", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    var dropZoneEmpty: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color(red: 0.3, green: 0.5, blue: 1, opacity: 0.08))
                        .frame(width: 90, height: 90)
                    Image(systemName: "film.stack")
                        .font(.system(size: 38))
                        .foregroundStyle(
                            LinearGradient(colors: [Color(red: 0.3, green: 0.5, blue: 1), Color(red: 0.6, green: 0.3, blue: 1)],
                                           startPoint: .top, endPoint: .bottom))
                }

                VStack(spacing: 6) {
                    Text("영상 파일을 드래그해서 놓으세요")
                        .font(.system(size: 17, weight: .semibold))
                    Text("MP4, MOV, MKV 등 여러 파일을 한 번에 추가할 수 있습니다")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button {
                    let panel = NSOpenPanel()
                    panel.allowsMultipleSelection = true
                    panel.canChooseDirectories = false
                    if panel.runModal() == .OK {
                        manager.addVideos(panel.urls)
                    }
                } label: {
                    Text("파일 선택...")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var jobList: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(manager.jobs) { job in
                    JobRow(job: job) {
                        manager.removeJob(id: job.id)
                    } onReveal: {
                        if let url = job.outputURL {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    var bottomBar: some View {
        HStack(spacing: 12) {
            if totalCount > 0 {
                HStack(spacing: 8) {
                    Text("\(totalCount)개 파일")
                        .foregroundColor(.secondary)
                    if completedCount > 0 {
                        Label("\(completedCount) 완료", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                    if failedCount > 0 {
                        Label("\(failedCount) 실패", systemImage: "xmark.circle.fill")
                            .foregroundColor(.red)
                    }
                }
                .font(.system(size: 12))

                if manager.isRunning {
                    ProgressView(value: overallProgress)
                        .frame(width: 120)
                        .tint(Color(red: 0.3, green: 0.5, blue: 1))
                }
            }

            Spacer()

            if !manager.jobs.filter({ $0.status == .done || $0.status == .failed }).isEmpty {
                Button("완료 항목 지우기") {
                    manager.clearCompleted()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            }

            Button {
                manager.startAll()
            } label: {
                Label(manager.isRunning ? "추출 중..." : "🎵 음성 추출 시작",
                      systemImage: manager.isRunning ? "waveform" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(manager.isRunning || manager.jobs.filter({ $0.status == .queued || $0.status == .failed }).isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    var dropOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 0.3, green: 0.5, blue: 1, opacity: 0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color(red: 0.3, green: 0.5, blue: 1), style: StrokeStyle(lineWidth: 2, dash: [8]))
                )
                .padding(12)

            VStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(Color(red: 0.3, green: 0.5, blue: 1))
                Text("파일을 놓으세요")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Color(red: 0.3, green: 0.5, blue: 1))
            }
        }
        .allowsHitTesting(false)
    }

    func handleDrop(providers: [NSItemProvider]) {
        var urls: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            manager.addVideos(urls)
        }
    }
}

// MARK: - JobRow
struct JobRow: View {
    let job: ExtractionJob
    let onRemove: () -> Void
    let onReveal: () -> Void
    @State private var isHovered = false

    var statusIcon: String {
        switch job.status {
        case .queued:     return "clock"
        case .extracting: return "waveform"
        case .done:       return "checkmark.circle.fill"
        case .failed:     return "xmark.circle.fill"
        }
    }

    var durationText: String? {
        guard let d = job.duration, d > 0 else { return nil }
        let mins = Int(d) / 60
        let secs = Int(d) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon)
                .font(.system(size: 16))
                .foregroundColor(job.status.color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(job.fileName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    if let size = job.fileSize {
                        Text(size)
                            .foregroundColor(.secondary)
                    }
                    if let dur = durationText {
                        Text("•").foregroundColor(.secondary)
                        Text(dur)
                            .foregroundColor(.secondary)
                    }
                    if let err = job.errorMessage {
                        Text("•").foregroundColor(.secondary)
                        Text(err)
                            .foregroundColor(.red)
                            .lineLimit(1)
                    } else if job.status == .done {
                        Text("•").foregroundColor(.secondary)
                        Text("→ \(job.outputFileName)")
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(job.status.label)
                            .foregroundColor(job.status.color)
                    }
                }
                .font(.system(size: 11))

                if job.status == .extracting {
                    ProgressView(value: job.progress)
                        .tint(Color(red: 0.3, green: 0.5, blue: 1))
                        .frame(height: 4)
                }
            }

            Spacer()

            if isHovered {
                HStack(spacing: 4) {
                    if job.status == .done {
                        Button {
                            onReveal()
                        } label: {
                            Image(systemName: "folder")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                        .help("Finder에서 보기")
                    }

                    Button {
                        onRemove()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help("제거")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isHovered ? Color.gray.opacity(0.1) : Color.clear)
        .onHover { isHovered = $0 }
    }
}

// MARK: - App Entry Point
@main
struct AudioExtractorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
