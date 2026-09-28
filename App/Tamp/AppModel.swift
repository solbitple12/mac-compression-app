import AppKit
import Observation
import TampCore

/// The window's state: the items waiting to be compressed or extracted, the
/// chosen format and speed step (remembered between launches), and the jobs.
/// All the work happens in TampCore; this only connects it to the views.
@MainActor
@Observable
final class AppModel {
    let registry: EngineRegistry
    private(set) var choice: ArchiveChoice
    /// Dropped or chosen, not yet started.
    private(set) var pendingItems: [URL] = []
    /// What the start button will do with the pending items, or nil when there are none.
    /// Worked out when the items change, since it reads each file's first bytes.
    private(set) var pendingAction: DropAction?
    /// Every job since launch, oldest first, until "Clear Finished".
    private(set) var jobs: [JobSnapshot] = []

    private let settings: SettingsStore
    private let queue: JobQueue
    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    init(registry: EngineRegistry = .standard(), settings: SettingsStore = SettingsStore()) {
        self.registry = registry
        self.settings = settings
        // One job at a time until Phase 2c adds the memory checks that make running several safe.
        queue = JobQueue(maxConcurrentJobs: 1)
        choice = settings.archiveChoice(availableFormats: registry.availableFormats)
        observeJobs()
    }

    // MARK: Format and speed

    var hint: StepHint? {
        registry.engine(for: choice.format)?.hint(for: choice.step, options: ArchiveOptions())
    }

    func select(format: ArchiveFormat) {
        choice.format = format
        settings.archiveChoice = choice
    }

    func select(step: SpeedStep) {
        choice.step = step
        settings.archiveChoice = choice
    }

    // MARK: Items

    func add(_ urls: [URL]) {
        for url in urls where url.isFileURL {
            let item = url.standardizedFileURL
            if !pendingItems.contains(item) { pendingItems.append(item) }
        }
        pendingAction = pendingItems.isEmpty ? nil : ArchivePlanner.action(for: pendingItems, registry: registry)
    }

    func clearPendingItems() {
        pendingItems = []
        pendingAction = nil
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose files or folders to compress, or archives to extract."
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in self?.add(urls) }
        }
    }

    /// Compresses the pending items into one archive, or extracts each pending archive beside itself.
    func start() {
        guard let action = pendingAction else { return }
        clearPendingItems()
        let queue = queue
        switch action {
        case let .compress(items):
            guard let engine = registry.engine(for: choice.format) else { return }
            let request = CompressRequest(
                items: items,
                destination: ArchivePlanner.destination(for: items, format: choice.format),
                step: choice.step
            )
            // Noted before the job runs, so a crash mid-job still gets its partial file cleaned up.
            settings.noteOutputDirectory(request.destination.deletingLastPathComponent())
            Task { await ArchiveJobs.compress(request, engine: engine, on: queue) }
        case let .extract(archives):
            for archive in archives {
                guard let engine = registry.extractor(for: archive) else { continue }
                let request = ExtractRequest(archive: archive, destinationDirectory: archive.deletingLastPathComponent())
                settings.noteOutputDirectory(request.destinationDirectory)
                Task { await ArchiveJobs.extract(request, engine: engine, on: queue) }
            }
        }
    }

    // MARK: Jobs

    var activeJobCount: Int {
        jobs.filter { !$0.state.isFinal }.count
    }

    var hasFinishedJobs: Bool {
        jobs.contains { $0.state.isFinal }
    }

    func cancel(_ id: JobID) {
        let queue = queue
        Task { await queue.cancel(id) }
    }

    func clearFinishedJobs() {
        jobs.removeAll { $0.state.isFinal }
        let queue = queue
        Task { await queue.removeFinishedJobs() }
    }

    /// Cancels every job and returns once each helper has stopped and its partial output is gone.
    func stopAllJobs() async {
        await queue.cancelAll()
        for job in await queue.snapshots where !job.state.isFinal {
            _ = await queue.waitUntilDone(job.id)
        }
    }

    func showInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Deletes hidden partial files that a crash or forced quit left in recent output folders.
    func removeStalePartialFiles() {
        let directories = settings.recentOutputDirectories
        Task.detached(priority: .utility) {
            for directory in directories {
                SafeOutput.removeStalePartials(in: directory)
            }
        }
    }

    private func observeJobs() {
        let queue = queue
        updatesTask = Task { [weak self] in
            for await snapshot in await queue.updates() {
                self?.apply(snapshot)
            }
        }
    }

    private func apply(_ snapshot: JobSnapshot) {
        if let index = jobs.firstIndex(where: { $0.id == snapshot.id }) {
            jobs[index] = snapshot
        } else {
            jobs.append(snapshot)
        }
    }
}
