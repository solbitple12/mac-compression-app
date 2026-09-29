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
    let mediaRegistry: MediaEngineRegistry
    private(set) var choice: ArchiveChoice
    /// Dropped or chosen, not yet started.
    private(set) var pendingItems: [URL] = []
    /// What the start button will do with the pending items. Nil while there are
    /// none, while Tamp is still checking them (`isCheckingItems`), and while
    /// `mediaItems` holds the pending batch instead.
    private(set) var pendingAction: DropAction?
    private(set) var isCheckingItems = false
    /// Every pending item recognized as its own image, audio or video source,
    /// each with its own format and quality; empty unless every pending item
    /// qualifies, in which case `pendingAction` stays nil.
    private(set) var mediaItems: [MediaItem] = []
    /// The largest single item's peak-memory estimate in `mediaItems`, since the
    /// queue runs one job at a time; nil until the probe finishes. See
    /// `scheduleMediaEstimate()`.
    var mediaPeakMemoryBytes: UInt64?
    @ObservationIgnored var mediaEstimateTask: Task<Void, Never>?
    /// Every job since launch, oldest first, until "Clear Finished".
    private(set) var jobs: [JobSnapshot] = []

    /// The input's size and samples, measured with the check; nil while checking or extracting.
    var profile: InputProfile?
    /// Time, size and memory for the current settings; rough until a probe finishes.
    var estimate: Estimate?
    var isEstimating = false
    /// The RAM gauge, the banner, and the question when the monitor paused jobs.
    var resourceStatus = ResourceStatus()
    /// Archives a stopped batch hadn't finished, for Resume.
    var unfinishedBatch: [URL]
    /// The question the window asks before starting, if any.
    var startQuestion: StartQuestion?
    /// A faster step for the long-job question, found after it opens.
    var fasterOption: FasterOption?
    var isFindingFasterOption = false
    /// Set once the monitor stopped jobs on its own, until the summary is dismissed.
    var automaticStopSummary: String?

    let settings: SettingsStore
    let safety = SafetySettings()
    let queue: JobQueue
    let estimator: Estimator
    let monitor: ResourceMonitor
    @ObservationIgnored var estimateTask: Task<Void, Never>?
    @ObservationIgnored var fasterTask: Task<Void, Never>?
    @ObservationIgnored var approvals: StartApproval = []
    /// What each running compress job was asked to do, so the pause dialog can restart it with lower settings.
    @ObservationIgnored var compressJobs: [JobID: CompressJob] = [:]
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    /// Bumped whenever the pending items change, so a check that finishes late is ignored.
    @ObservationIgnored private var checkGeneration = 0

    init(registry: EngineRegistry = .standard(), mediaRegistry: MediaEngineRegistry = .standard(), settings: SettingsStore = SettingsStore()) {
        self.registry = registry
        self.mediaRegistry = mediaRegistry
        self.settings = settings
        // One job at a time: the memory checks guard a job, and two large ones at
        // once would each pass their check and then compete for the same memory.
        queue = JobQueue(maxConcurrentJobs: 1)
        choice = settings.archiveChoice(availableFormats: registry.availableFormats)
        estimator = Estimator(history: .standard)
        monitor = ResourceMonitor(queue: queue, policy: safety.policy)
        unfinishedBatch = settings.unfinishedBatch
        observeJobs()
        observeResources()
    }

    // MARK: Format and speed

    var hint: StepHint? {
        registry.engine(for: choice.format)?.hint(for: choice.step, options: choice.options)
    }

    /// The methods the current format can hold inside, empty if it has only one.
    var methods: [CompressionMethod] {
        choice.format.methods
    }

    var method: CompressionMethod? {
        choice.method(for: choice.format)
    }

    func select(method: CompressionMethod) {
        choice.setMethod(method, for: choice.format)
        settings.archiveChoice = choice
        scheduleEstimate()
    }

    /// False for plain TAR, which only bundles files.
    var hasSpeedSteps: Bool {
        choice.format != .tar
    }

    /// The step the slider shows: Store for plain TAR, whatever was chosen for the others.
    var effectiveStep: SpeedStep {
        hasSpeedSteps ? choice.step : .store
    }

    func select(format: ArchiveFormat) {
        choice.format = format
        settings.archiveChoice = choice
        scheduleEstimate()
    }

    func select(step: SpeedStep) {
        choice.step = step
        settings.archiveChoice = choice
        scheduleEstimate()
    }

    // MARK: Advanced settings

    /// Never saved, and cleared once a job starts with it.
    var password = ""
    var passwordConfirmation = ""

    /// The Advanced panel's format-specific settings for the current format and method.
    var advancedOptions: [AdvancedOption] {
        choice.format.advancedOptions(method: method)
    }

    var takesPassword: Bool {
        registry.engine(for: choice.format)?.capabilities.contains(.encryption) == true
    }

    var canSplit: Bool {
        choice.format.canSplit(method: method)
    }

    /// hdiutil copies everything into a disk image, so the junk setting doesn't apply there.
    var canExcludeJunk: Bool {
        choice.format != .dmg
    }

    /// Why the password can't be used yet, or nil.
    var passwordProblem: String? {
        guard takesPassword, !password.isEmpty || !passwordConfirmation.isEmpty else { return nil }
        return password == passwordConfirmation ? nil : "The passwords don't match"
    }

    /// Changes and saves the choice, for the Advanced panel's controls.
    func update(_ change: (inout ArchiveChoice) -> Void) {
        let before = choice
        change(&choice)
        settings.archiveChoice = choice
        // Checking, the Trash and the junk setting don't change what a probe measures.
        if before.options != choice.options { scheduleEstimate() }
    }

    // MARK: Items

    func add(_ urls: [URL]) {
        for url in urls where url.isFileURL {
            let item = url.standardizedFileURL
            if !pendingItems.contains(item) { pendingItems.append(item) }
        }
        checkPendingItems()
    }

    func clearPendingItems() {
        pendingItems = []
        checkPendingItems()
    }

    /// Works out whether the items are archives to extract, off the main thread:
    /// that reads each archive's first bytes, which can stall on a file iCloud
    /// has yet to download or on a slow network share.
    private func checkPendingItems() {
        checkGeneration += 1
        pendingAction = nil
        profile = nil
        scheduleEstimate()
        guard !pendingItems.isEmpty else {
            isCheckingItems = false
            mediaItems = []
            mediaPeakMemoryBytes = nil
            return
        }
        // Extension checks only, no disk access, so this can run on the main actor.
        if let items = MediaBatch.items(for: pendingItems, registry: mediaRegistry) {
            mediaItems = items
            isCheckingItems = false
            scheduleMediaEstimate()
            return
        }
        mediaItems = []
        mediaPeakMemoryBytes = nil
        isCheckingItems = true
        let generation = checkGeneration
        let items = pendingItems
        let registry = registry
        Task.detached(priority: .userInitiated) { [weak self] in
            let action = ArchivePlanner.action(for: items, registry: registry)
            // The estimator needs the input's size and samples; measure them now, once.
            var profile: InputProfile?
            if case let .compress(items) = action { profile = InputProfile.scan(items) }
            await self?.finishCheck(action, profile: profile, generation: generation)
        }
    }

    private func finishCheck(_ action: DropAction, profile: InputProfile?, generation: Int) {
        guard generation == checkGeneration else { return }
        pendingAction = action
        self.profile = profile
        isCheckingItems = false
        scheduleEstimate()
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

    /// Set while the window asks whether the originals may go to the Trash.
    var isConfirmingTrash = false

    var canStart: Bool {
        if !mediaItems.isEmpty { return true }
        guard let action = pendingAction else { return false }
        if case .compress = action { return passwordProblem == nil }
        return true
    }

    /// Changes one pending media item's format, step or quality, for its row's controls.
    func updateMediaItem(_ id: MediaItem.ID, _ change: (inout MediaItem) -> Void) {
        guard let index = mediaItems.firstIndex(where: { $0.id == id }) else { return }
        change(&mediaItems[index])
        scheduleMediaEstimate()
    }

    /// Probes each pending media item's peak memory (video's probe reads the
    /// source's real dimensions; image and audio are cheap enough to compute
    /// directly) and keeps the largest, since the queue runs one job at a time.
    /// A source Tamp fails to read falls back to an HD-sized guess rather than
    /// blocking the estimate on one bad file.
    func scheduleMediaEstimate() {
        mediaEstimateTask?.cancel()
        guard !mediaItems.isEmpty else {
            mediaPeakMemoryBytes = nil
            return
        }
        let items = mediaItems
        mediaEstimateTask = Task { [weak self] in
            var peak: UInt64 = 0
            for item in items {
                guard !Task.isCancelled else { return }
                let bytes: UInt64
                switch item.target {
                case let .image(format):
                    bytes = (try? ImageMemoryHint.peakMemoryBytes(source: item.source, format: format))
                        ?? ImageMemoryHint.peakMemoryBytes(format: format, pixelWidth: 1920, pixelHeight: 1080)
                case let .audio(format):
                    bytes = AudioMemoryHint.peakMemoryBytes(format: format)
                case let .video(format):
                    bytes = (try? await VideoMemoryHint.peakMemoryBytes(source: item.source, format: format, step: item.step))
                        ?? VideoMemoryHint.peakMemoryBytes(format: format, step: item.step, pixelWidth: 1920, pixelHeight: 1080)
                }
                peak = max(peak, bytes)
            }
            guard !Task.isCancelled else { return }
            self?.mediaPeakMemoryBytes = peak
        }
    }

    /// The start button: runs the checks from the top (see `proceed()`).
    func start() {
        approvals = []
        proceed()
    }

    /// Compresses the pending items into one archive, or extracts each pending archive
    /// beside itself, once every check has passed or been answered.
    func launch() {
        guard let action = pendingAction, canStart else { return }
        let estimate = estimate
        clearPendingItems()
        startQuestion = nil
        let registry = registry
        let choice = choice
        let password = takesPassword && !password.isEmpty ? password : nil
        self.password = ""
        passwordConfirmation = ""
        switch action {
        case let .compress(items):
            guard let engine = registry.engine(for: choice.format) else { return }
            let request = CompressRequest(
                items: items,
                destination: ArchivePlanner.destination(for: items, format: choice.format),
                step: choice.step,
                options: choice.options,
                password: password,
                excludesMacOSJunk: choice.excludesMacOSJunk,
                volumeBytes: choice.volumeBytes
            )
            let afterwards = ArchiveJobs.Afterwards(verifies: choice.verifies, trashesOriginals: choice.trashesOriginals)
            enqueueCompress(CompressJob(request: request, afterwards: afterwards, format: choice.format), estimate: estimate)
        case let .extract(archives):
            extract(archives)
        }
    }

    /// Compresses each pending media item as its own independent job, with its
    /// own format, step and quality - unlike `launch()`'s archive path, which
    /// bundles everything into one output.
    func launchMediaBatch() {
        guard !mediaItems.isEmpty else { return }
        let items = mediaItems
        clearPendingItems()
        startQuestion = nil
        let registry = mediaRegistry
        let queue = queue
        let willWrite = outputFolderHandler
        for item in items {
            switch item.target {
            case let .image(format):
                guard let engine = registry.imageEngine(for: format) else { continue }
                let destination = MediaPlanner.destination(for: item.source, fileExtension: format.fileExtension)
                let request = ImageCompressRequest(source: item.source, destination: destination, format: format, step: item.step, quality: item.quality)
                Task { await MediaJobs.compress(request, engine: engine, on: queue, willWrite: willWrite) }
            case let .audio(format):
                guard let engine = registry.audioEngine(for: format) else { continue }
                let destination = MediaPlanner.destination(for: item.source, fileExtension: format.fileExtension)
                let request = AudioCompressRequest(source: item.source, destination: destination, format: format, step: item.step, quality: item.quality)
                Task { await MediaJobs.compress(request, engine: engine, on: queue, willWrite: willWrite) }
            case let .video(format):
                guard let engine = registry.videoEngine(for: format) else { continue }
                let destination = MediaPlanner.destination(for: item.source, fileExtension: format.fileExtension)
                let request = VideoCompressRequest(source: item.source, destination: destination, format: format, step: item.step, quality: item.quality)
                Task { await MediaJobs.compress(request, engine: engine, on: queue, willWrite: willWrite) }
            }
        }
    }

    /// Enqueues a compress job after launch cleanup, and remembers it for a restart.
    func enqueueCompress(_ job: CompressJob, estimate: Estimate?) {
        guard let engine = registry.engine(for: job.format) else { return }
        let queue = queue
        let cleanup = cleanupTask
        let history = estimator.history
        let willWrite = outputFolderHandler
        Task { [weak self] in
            // Launch cleanup must not delete the partial file of a job started right after launch.
            await cleanup?.value
            let id = await ArchiveJobs.compress(job.request, engine: engine, on: queue, afterwards: job.afterwards,
                                                estimate: estimate, history: history, willWrite: willWrite)
            self?.compressJobs[id] = job
        }
    }

    /// Extracts each archive in turn. Stopping one stops the batch, and what it hadn't
    /// finished (the stopped archive included) is saved for Resume.
    func extract(_ archives: [URL]) {
        let queue = queue
        let registry = registry
        let cleanup = cleanupTask
        let willWrite = outputFolderHandler
        Task.detached(priority: .userInitiated) { [weak self] in
            await cleanup?.value
            // One at a time, so the jobs run in the order the archives were dropped,
            // and a password can be asked for before the next one starts.
            for (index, archive) in archives.enumerated() {
                guard let engine = registry.extractor(for: archive) else { continue }
                var password: String?
                while true {
                    let request = ExtractRequest(archive: archive, destinationDirectory: archive.deletingLastPathComponent(),
                                                 password: password)
                    let id = await ArchiveJobs.extract(request, engine: engine, on: queue, willWrite: willWrite)
                    let state = await queue.waitUntilDone(id)?.state
                    if state == .cancelled {
                        await self?.saveUnfinishedBatch(Array(archives[index...]))
                        return
                    }
                    guard case let .failed(error)? = state,
                          error == .passwordRequired || error == .wrongPassword,
                          let entered = await self?.askForPassword(archive: archive, wasWrong: error == .wrongPassword)
                    else { break }
                    password = entered
                }
            }
        }
    }

    private var outputFolderHandler: ArchiveJobs.OutputFolderHandler {
        let settings = settings
        return { folder in settings.noteOutputDirectory(folder) }
    }

    // MARK: Passwords for extracting

    struct PasswordRequest: Identifiable {
        let id = UUID()
        let archiveName: String
        let wasWrong: Bool
    }

    /// Set while the window asks for an archive's password.
    private(set) var passwordRequest: PasswordRequest?
    @ObservationIgnored private var passwordContinuation: CheckedContinuation<String?, Never>?

    /// - Returns: The password entered, or nil if the person cancelled.
    func askForPassword(archive: URL, wasWrong: Bool) async -> String? {
        answerPasswordRequest(nil)
        return await withCheckedContinuation { continuation in
            passwordContinuation = continuation
            passwordRequest = PasswordRequest(archiveName: archive.lastPathComponent, wasWrong: wasWrong)
        }
    }

    func answerPasswordRequest(_ password: String?) {
        passwordRequest = nil
        let continuation = passwordContinuation
        passwordContinuation = nil
        continuation?.resume(returning: password.flatMap { $0.isEmpty ? nil : $0 })
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

    /// For quitting: stops every job, refuses new ones, and returns once each
    /// helper has stopped and its partial output is gone.
    func stopAllJobs() async {
        await queue.shutDown()
    }

    func showInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Deletes hidden partial files that a crash or forced quit left in recent
    /// output folders. Jobs started meanwhile wait for it (see `start()`).
    func removeStalePartialFiles() {
        let directories = settings.recentOutputDirectories
        cleanupTask = Task.detached(priority: .utility) {
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
            // A job publishes nothing after its final state, so a cleared job never comes back.
            jobs.append(snapshot)
        }
    }
}
