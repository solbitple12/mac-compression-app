import Foundation
import TampCore

/// The estimate beside the slider, the checks before a job starts, and the
/// answers to the resource monitor's questions.
extension AppModel {
    /// A compress job as it was asked for, kept while it runs so it can be restarted.
    struct CompressJob {
        var request: CompressRequest
        var afterwards: ArchiveJobs.Afterwards
        var format: ArchiveFormat
    }

    /// One running media item, kept while it runs so a paused one can be restarted.
    struct MediaJob {
        var item: MediaItem
        var destination: URL
    }

    /// Checks already answered for the job about to start.
    struct StartApproval: OptionSet {
        let rawValue: Int
        static let memory = StartApproval(rawValue: 1 << 0)
        static let disk = StartApproval(rawValue: 1 << 1)
        static let longJob = StartApproval(rawValue: 1 << 2)
        static let trash = StartApproval(rawValue: 1 << 3)
    }

    /// What the window asks before a job starts.
    enum StartQuestion: Identifiable {
        case memory(needed: UInt64, available: UInt64, fix: Preflight.MemoryFix)
        case disk(needed: Int64, free: Int64, volume: String)
        case longJob(Estimate)
        /// A media batch's version of `.memory`: no per-format fix to offer yet
        /// (see `scheduleMediaEstimate()`), and different wording since there's
        /// no single format or thread count to name.
        case mediaMemory(needed: UInt64, available: UInt64)
        /// A media batch's version of `.disk`: each item writes its own file
        /// rather than one archive, so the wording doesn't say "archive".
        case mediaDisk(needed: Int64, free: Int64, volume: String)

        var id: String {
            switch self {
            case .memory: "memory"
            case .disk: "disk"
            case .longJob: "longJob"
            case .mediaMemory: "mediaMemory"
            case .mediaDisk: "mediaDisk"
            }
        }
    }

    struct FasterOption {
        var step: SpeedStep
        var estimate: Estimate
    }

    /// Restarting paused jobs with lower settings: one step down and half the
    /// threads for an archive job; media has no thread count, so `threads` is
    /// nil there, and only a video item has a step that changes its memory estimate.
    struct RestartOption {
        var step: SpeedStep
        var threads: Int?
        var memory: UInt64
    }

    // MARK: Hint

    /// "Best: ~4 min · ~350 MB · uses ~2.1 GB RAM" once there's an estimate, else
    /// what the mapping alone knows.
    var hintText: String? {
        guard let hint else { return nil }
        if let estimate { return estimate.hintText(step: effectiveStep) }
        return isEstimating ? "\(hint.text) · estimating…" : hint.text
    }

    /// Re-estimates after the settings or items change: a cached result at once, a
    /// rough one from history meanwhile, and a probe 300 ms after the last change,
    /// cancelling any probe still running.
    func scheduleEstimate() {
        estimateTask?.cancel()
        estimate = nil
        guard let profile, case .compress? = pendingAction, let engine = registry.engine(for: choice.format) else {
            isEstimating = false
            return
        }
        let step = effectiveStep
        let options = choice.options
        let estimator = estimator
        isEstimating = true
        estimateTask = Task { [weak self] in
            if let cached = await estimator.cachedEstimate(for: profile, engine: engine, step: step, options: options) {
                guard !Task.isCancelled else { return }
                self?.finishEstimate(cached)
                return
            }
            self?.estimate = estimator.roughEstimate(for: profile, engine: engine, step: step, options: options)
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let probed = try? await estimator.estimate(for: profile, engine: engine, step: step, options: options)
            guard !Task.isCancelled else { return }
            self?.finishEstimate(probed ?? self?.estimate)
        }
    }

    private func finishEstimate(_ result: Estimate?) {
        estimate = result
        isEstimating = false
    }

    // MARK: Checks before starting

    /// Answers the current question and carries on with the next check.
    func approve(_ approval: StartApproval) {
        startQuestion = nil
        approvals.insert(approval)
        proceed()
    }

    func dismissStartQuestion() {
        startQuestion = nil
        fasterTask?.cancel()
        fasterOption = nil
        isFindingFasterOption = false
    }

    /// Runs the checks that haven't been answered, asking the first that fails, then
    /// launches: memory, then disk, then the long-job warning, then the Trash.
    func proceed() {
        guard canStart else { return }
        guard mediaItems.isEmpty else {
            proceedWithMediaBatch()
            return
        }
        guard let action = pendingAction else { return }
        guard case .compress = action, let engine = registry.engine(for: choice.format) else {
            launch()
            return
        }
        let inputBytes = profile?.totalBytes ?? 0
        let method = choice.method(for: choice.format)

        if !approvals.contains(.memory) {
            let correction = estimator.history.memoryCorrection(format: choice.format, method: method, step: effectiveStep)
            let memory: (SpeedStep, Int) -> UInt64 = { [choice] step, threads in
                var options = choice.options
                options.threads = threads
                return UInt64(Double(Estimator.inputAwarePeakMemory(engine: engine, step: step, options: options,
                                                                    totalBytes: inputBytes)) * correction)
            }
            let needed = estimate?.peakMemoryBytes ?? memory(effectiveStep, choice.options.threads)
            let available = SystemResources.availableMemory()
            if case let .memory(needed, available)? = Preflight.memoryProblem(peakMemoryBytes: needed, availableMemoryBytes: available,
                                                                              settings: safety) {
                let limit = UInt64(safety.memoryShare * Double(available))
                let fix = Preflight.memoryFix(step: effectiveStep, threads: choice.options.threads, limit: limit, memory: memory)
                startQuestion = .memory(needed: needed, available: available, fix: fix)
                return
            }
        }
        if !approvals.contains(.disk), let items = pendingItemsForCompress {
            let destination = ArchivePlanner.destination(for: items, format: choice.format).deletingLastPathComponent()
            let output = estimate?.outputBytes.upperBound ?? inputBytes
            if case let .disk(needed, free, volume)? = Preflight.diskProblem(
                outputBytes: output, verifyBytes: choice.verifies ? inputBytes : 0, destination: destination, settings: safety
            ) {
                startQuestion = .disk(needed: needed, free: free, volume: volume)
                return
            }
        }
        if !approvals.contains(.longJob), let estimate, !estimate.isRough, estimate.likelySeconds > safety.longJobSeconds {
            startQuestion = .longJob(estimate)
            findFasterOption(engine: engine)
            return
        }
        if !approvals.contains(.trash), choice.trashesOriginals {
            isConfirmingTrash = true
            return
        }
        launch()
    }

    private var pendingItemsForCompress: [URL]? {
        if case let .compress(items)? = pendingAction { items } else { nil }
    }

    /// The media batch's own, simpler version of `proceed()`'s checks: memory
    /// (once the probe in `scheduleMediaEstimate()` finishes), then disk, no
    /// long-job or Trash question yet. No fix is offered for memory, since a
    /// batch can mix formats with no one step or thread count to lower.
    private func proceedWithMediaBatch() {
        if !approvals.contains(.memory), let needed = mediaPeakMemoryBytes {
            let available = SystemResources.availableMemory()
            if Preflight.memoryProblem(peakMemoryBytes: needed, availableMemoryBytes: available, settings: safety) != nil {
                startQuestion = .mediaMemory(needed: needed, available: available)
                return
            }
        }
        if !approvals.contains(.disk), let firstItem = mediaItems.first {
            // Items are usually dropped from the same folder; the first item's
            // volume stands in for all of them rather than checking each one.
            let destination = firstItem.source.deletingLastPathComponent()
            let outputBytes = mediaItems.reduce(Int64(0)) { $0 + InputSize.totalBytes(of: [$1.source]) }
            if case let .disk(needed, free, volume)? = Preflight.diskProblem(
                outputBytes: outputBytes, verifyBytes: 0, destination: destination, settings: safety
            ) {
                startQuestion = .mediaDisk(needed: needed, free: free, volume: volume)
                return
            }
        }
        launchMediaBatch()
    }

    private func findFasterOption(engine: any ArchiveEngine) {
        fasterTask?.cancel()
        fasterOption = nil
        guard let profile else { return }
        isFindingFasterOption = true
        let estimator = estimator
        let step = effectiveStep
        let options = choice.options
        let limit = safety.longJobSeconds
        fasterTask = Task { [weak self] in
            let found = try? await estimator.fasterStep(for: profile, engine: engine, below: step, options: options, limit: limit)
            guard !Task.isCancelled else { return }
            self?.fasterOption = found.map { FasterOption(step: $0.0, estimate: $0.1) }
            self?.isFindingFasterOption = false
        }
    }

    /// The memory question's fixes and the long-job question's faster step.
    func useStep(_ step: SpeedStep, approving approval: StartApproval) {
        select(step: step)
        approve(approval)
    }

    func useThreads(_ threads: Int) {
        update { $0.threads = threads }
        approve(.memory)
    }

    // MARK: Resource monitor

    func observeResources() {
        let monitor = monitor
        Task { [weak self] in
            await monitor.start()
            for await status in await monitor.updates() {
                self?.apply(status)
            }
        }
    }

    private func apply(_ status: ResourceStatus) {
        resourceStatus = status
        for id in compressJobs.keys where !jobs.contains(where: { $0.id == id && !$0.state.isFinal }) {
            compressJobs[id] = nil
        }
        for id in mediaJobs.keys where !jobs.contains(where: { $0.id == id && !$0.state.isFinal }) {
            mediaJobs[id] = nil
        }
        if let stop = status.automaticStop {
            let count = stop.jobs.count
            automaticStopSummary = "\(stop.reason), and nobody answered, so Tamp stopped \(count == 1 ? "the job" : "\(count) jobs") safely. "
                + "Finished archives were kept and the stopped job's partial output was removed."
                + (unfinishedBatch.isEmpty ? "" : " Archives not yet extracted can be resumed from the Jobs list.")
            let monitor = monitor
            Task { await monitor.acknowledgeAutomaticStop() }
        }
    }

    func dismissAutomaticStopSummary() {
        automaticStopSummary = nil
    }

    func resumePausedJobs() {
        let monitor = monitor
        Task { await monitor.resumePausedJobs() }
    }

    func stopPausedJobs() {
        let monitor = monitor
        Task { await monitor.stopPausedJobs() }
    }

    /// One step down and half the threads, for the first paused compress job -
    /// or, for a paused media batch, one step down for the first paused video
    /// item (image and audio's memory estimate doesn't change with step, so
    /// there's no lower-memory step to offer those).
    var restartOption: RestartOption? {
        if let id = resourceStatus.pausedJobs.first(where: { compressJobs[$0] != nil }),
           let job = compressJobs[id], let engine = registry.engine(for: job.format) {
            let step = SpeedStep(rawValue: max(SpeedStep.fastest.rawValue, job.request.step.rawValue - 1)) ?? .fastest
            let threads = max(1, job.request.options.threads / 2)
            var options = job.request.options
            options.threads = threads
            return RestartOption(step: step, threads: threads, memory: engine.hint(for: step, options: options).peakMemoryBytes)
        }
        if let id = resourceStatus.pausedJobs.first(where: { mediaJobs[$0] != nil }), let job = mediaJobs[id],
           case let .video(format) = job.item.target, job.item.step > .fastest {
            let step = SpeedStep(rawValue: job.item.step.rawValue - 1) ?? .fastest
            // The real dimensions aren't kept around after scheduleMediaEstimate()
            // finishes; an HD-sized guess matches that estimate's own fallback.
            let memory = VideoMemoryHint.peakMemoryBytes(format: format, step: step, pixelWidth: 1920, pixelHeight: 1080)
            return RestartOption(step: step, threads: nil, memory: memory)
        }
        return nil
    }

    /// Stops the paused jobs and starts each one again with lower settings.
    func restartPausedJobs() {
        guard let option = restartOption else { return }
        let paused = resourceStatus.pausedJobs
        let monitor = monitor
        let queue = queue
        if paused.contains(where: { compressJobs[$0] != nil }) {
            let restarts = paused.compactMap { compressJobs[$0] }.map { job -> CompressJob in
                var job = job
                job.request.step = option.step
                job.request.options.threads = option.threads ?? job.request.options.threads
                return job
            }
            Task { [weak self] in
                await monitor.stopPausedJobs()
                // The stopped jobs remove their partial output before the name is free again.
                for id in paused { _ = await queue.waitUntilDone(id) }
                for job in restarts { self?.enqueueCompress(job, estimate: nil) }
            }
            return
        }
        let restarts = paused.compactMap { mediaJobs[$0] }.map { job -> MediaJob in
            var job = job
            job.item.step = option.step
            return job
        }
        Task { [weak self] in
            await monitor.stopPausedJobs()
            for id in paused { _ = await queue.waitUntilDone(id) }
            for job in restarts { self?.enqueueMediaItem(job.item, destination: job.destination) }
        }
    }

    // MARK: Unfinished batch

    func saveUnfinishedBatch(_ archives: [URL]) {
        unfinishedBatch = archives
        settings.unfinishedBatch = archives
    }

    func resumeUnfinishedBatch() {
        let archives = unfinishedBatch.filter { FileManager.default.fileExists(atPath: $0.path) }
        discardUnfinishedBatch()
        if !archives.isEmpty { extract(archives) }
    }

    func discardUnfinishedBatch() {
        unfinishedBatch = []
        settings.unfinishedBatch = []
    }
}
