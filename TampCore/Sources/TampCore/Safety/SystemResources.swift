import Darwin
import Foundation

/// The system's memory pressure as the kernel reports it.
public enum MemoryPressure: Int, Comparable, Sendable {
    case normal
    case warning
    case critical

    public static func < (lhs: MemoryPressure, rhs: MemoryPressure) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One look at memory, swap and disk, taken once a second while jobs run.
public struct ResourceSample: Equatable, Sendable {
    public var pressure: MemoryPressure
    /// Footprint of every running job's helpers, plus what Tamp itself grew by for
    /// engines that work in-process.
    public var jobFootprintBytes: UInt64
    /// Free, inactive and purgeable memory: what can be had without swapping.
    public var availableMemoryBytes: UInt64
    public var physicalMemoryBytes: UInt64
    public var swapUsedBytes: UInt64
    /// Free space on each output folder's volume, by the volume's name.
    public var freeDiskBytes: [String: Int64]

    public init(pressure: MemoryPressure = .normal, jobFootprintBytes: UInt64 = 0, availableMemoryBytes: UInt64,
                physicalMemoryBytes: UInt64, swapUsedBytes: UInt64 = 0, freeDiskBytes: [String: Int64] = [:]) {
        self.pressure = pressure
        self.jobFootprintBytes = jobFootprintBytes
        self.availableMemoryBytes = availableMemoryBytes
        self.physicalMemoryBytes = physicalMemoryBytes
        self.swapUsedBytes = swapUsedBytes
        self.freeDiskBytes = freeDiskBytes
    }
}

/// Where samples come from, so tests can simulate pressure, swap growth and low disk.
public protocol ResourceSampling: Sendable {
    /// - Parameters:
    ///   - footprints: The helpers' process IDs for each job; the result's footprint is their total.
    ///   - volumes: Folders whose volumes' free space to report.
    func sample(processIDs: [pid_t], volumes: [URL]) -> ResourceSample
    /// Footprint of one job's helpers, to record its peak.
    func footprint(of processIDs: [pid_t]) -> UInt64
}

/// Reads the real system: proc_pid_rusage for helpers, task_info for Tamp,
/// host_statistics64 for free pages, vm.swapusage for swap, and a dispatch
/// memory-pressure source for the kernel's own verdict.
public final class SystemResources: ResourceSampling, @unchecked Sendable {
    private let lock = NSLock()
    private var pressure: MemoryPressure = .normal
    private let source: DispatchSourceMemoryPressure
    /// Tamp's footprint when monitoring began, so only growth counts toward jobs.
    private let ownBaseline: UInt64

    public init() {
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
        ownBaseline = Self.ownFootprint()
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = source.data
            let level: MemoryPressure = event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal
            lock.withLock { pressure = level }
        }
        source.activate()
    }

    deinit {
        source.cancel()
    }

    public func sample(processIDs: [pid_t], volumes: [URL]) -> ResourceSample {
        let own = Self.ownFootprint()
        return ResourceSample(
            pressure: lock.withLock { pressure },
            jobFootprintBytes: footprint(of: processIDs) + (own > ownBaseline ? own - ownBaseline : 0),
            availableMemoryBytes: Self.availableMemory(),
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            swapUsedBytes: Self.swapUsed(),
            freeDiskBytes: Self.freeDisk(on: volumes)
        )
    }

    public func footprint(of processIDs: [pid_t]) -> UInt64 {
        processIDs.reduce(0) { $0 + Self.footprint(of: $1) }
    }

    /// A helper's physical footprint, the figure Activity Monitor shows as Memory.
    static func footprint(of pid: pid_t) -> UInt64 {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return result == 0 ? info.ri_phys_footprint : 0
    }

    static func ownFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// Free plus inactive plus purgeable pages.
    public static func availableMemory() -> UInt64 {
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return ProcessInfo.processInfo.physicalMemory / 2 }
        let pages = UInt64(statistics.free_count) + UInt64(statistics.inactive_count) + UInt64(statistics.purgeable_count)
        return pages * UInt64(vm_kernel_page_size)
    }

    static func swapUsed() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    /// Free space for important files (which counts purgeable space) on each folder's volume.
    public static func freeDisk(on folders: [URL]) -> [String: Int64] {
        var result: [String: Int64] = [:]
        for folder in folders {
            guard let values = try? folder.resourceValues(forKeys: [.volumeNameKey, .volumeAvailableCapacityForImportantUsageKey]),
                  let free = values.volumeAvailableCapacityForImportantUsage else { continue }
            result[values.volumeName ?? folder.path] = free
        }
        return result
    }
}
