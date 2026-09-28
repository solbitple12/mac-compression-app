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
    /// What the start button will do with the pending items. Nil while there are
    /// none, and while Tamp is still checking them (`isCheckingItems`).
    private(set) var pendingAction: DropAction?
    private(set) var isCheckingItems = false
    /// Every job since launch, oldest first, until "Clear Finished".
    private(set) var jobs: [JobSnapshot] = []

    private let settings: SettingsStore
    private let queue: JobQueue
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    /// Bumped whenever the pending items change, so a check that finishes late is ignored.
    @ObservationIgnored private var checkGeneration = 0

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
    }

    func select(step: SpeedStep) {
        choice.step = step
        settings.archiveChoice = choice
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
        change(&choice)
        settings.archiveChoice = choice
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
        guard !pendingItems.isEmpty else {
            isCheckingItems = false
            return
        }
        isCheckingItems = true
        let generation = checkGeneration
        let items = pendingItems
        let registry = registry
        Task.detached(priority: .userInitiated) { [weak self] in
            let action = ArchivePlanner.action(for: items, registry: registry)
            await self?.finishCheck(action, generation: generation)
        }
    }

    private func finishCheck(_ action: DropAction, generation: Int) {
        guard generation == checkGeneration else { return }
        pendingAction = action
        isCheckingItems = false
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
        guard let action = pendingAction else { return false }
        if case .compress = action { return passwordProblem == nil }
        return true
    }

    /// Compresses the pending items into one archive, or extracts each pending archive
    /// beside itself. With "Move originals to the Trash" on, asks first.
    func start(trashConfirmed: Bool = false) {
        guard let action = pendingAction, canStart else { return }
        if case .compress = action, choice.trashesOriginals, !trashConfirmed {
            isConfirmingTrash = true
            return
        }
        clearPendingItems()
        let queue = queue
        let registry = registry
        let choice = choice
        let password = takesPassword && !password.isEmpty ? password : nil
        self.password = ""
        passwordConfirmation = ""
        let cleanup = cleanupTask
        let settings = settings
        let willWrite: ArchiveJobs.OutputFolderHandler = { folder in settings.noteOutputDirectory(folder) }
        Task.detached(priority: .userInitiated) { [weak self] in
            // Launch cleanup must not delete the partial file of a job started right after launch.
            await cleanup?.value
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
                await ArchiveJobs.compress(request, engine: engine, on: queue, afterwards: afterwards, willWrite: willWrite)
            case let .extract(archives):
                // One at a time, so the jobs run in the order the archives were dropped,
                // and a password can be asked for before the next one starts.
                for archive in archives {
                    guard let engine = registry.extractor(for: archive) else { continue }
                    var password: String?
                    while true {
                        let request = ExtractRequest(archive: archive, destinationDirectory: archive.deletingLastPathComponent(),
                                                     password: password)
                        let id = await ArchiveJobs.extract(request, engine: engine, on: queue, willWrite: willWrite)
                        guard case let .failed(error)? = await queue.waitUntilDone(id)?.state,
                              error == .passwordRequired || error == .wrongPassword,
                              let entered = await self?.askForPassword(archive: archive, wasWrong: error == .wrongPassword)
                        else { break }
                        password = entered
                    }
                }
            }
        }
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
