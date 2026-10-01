import Foundation

/// A job's progress as the progress view shows it.
public struct JobProgress: Equatable, Sendable {
    public var bytesProcessed: Int64
    /// Zero when the total is unknown.
    public var totalBytes: Int64
    public var elapsed: TimeInterval
    public var bytesPerSecond: Double
    public var estimatedTimeRemaining: TimeInterval?

    public var fractionCompleted: Double {
        totalBytes > 0 ? min(1, Double(bytesProcessed) / Double(totalBytes)) : 0
    }
}

/// Turns raw byte counts into a smoothed speed and ETA. Speed is an exponential
/// moving average over `smoothingWindow` seconds, so the ETA doesn't jump on
/// every sample, and over the first `blendFraction` of the job the ETA leans on
/// the pre-start estimate, when there is one.
public struct ThroughputTracker: Sendable {
    public let totalBytes: Int64
    public let initialEstimate: TimeInterval?
    public let smoothingWindow: TimeInterval
    public let blendFraction: Double
    private let startTime: TimeInterval
    private var lastTime: TimeInterval
    private var lastBytes: Int64 = 0
    private var smoothedRate: Double?

    public init(
        totalBytes: Int64,
        startTime: TimeInterval,
        initialEstimate: TimeInterval? = nil,
        smoothingWindow: TimeInterval = 10,
        blendFraction: Double = 0.05
    ) {
        self.totalBytes = max(0, totalBytes)
        self.startTime = startTime
        self.lastTime = startTime
        self.initialEstimate = initialEstimate
        self.smoothingWindow = smoothingWindow
        self.blendFraction = blendFraction
    }

    public mutating func record(bytesProcessed: Int64, at time: TimeInterval) -> JobProgress {
        let upperBound = totalBytes > 0 ? totalBytes : Int64.max
        let bytes = min(max(bytesProcessed, lastBytes), upperBound)
        let interval = time - lastTime
        if interval > 0 {
            let instantRate = Double(bytes - lastBytes) / interval
            if let previous = smoothedRate {
                let weight = 1 - exp(-interval / smoothingWindow)
                smoothedRate = previous + weight * (instantRate - previous)
            } else {
                smoothedRate = instantRate
            }
            lastTime = time
            lastBytes = bytes
        }

        let elapsed = time - startTime
        var remaining: TimeInterval?
        if totalBytes > 0 {
            let bytesLeft = Double(totalBytes - bytes)
            if bytesLeft == 0 {
                remaining = 0
            } else if let rate = smoothedRate, rate > 0 {
                remaining = bytesLeft / rate
            }
            let fraction = Double(bytes) / Double(totalBytes)
            if let initialEstimate, fraction < blendFraction {
                let planned = max(0, initialEstimate - elapsed)
                let weight = fraction / blendFraction
                remaining = remaining.map { weight * $0 + (1 - weight) * planned } ?? planned
            }
        }

        return JobProgress(
            bytesProcessed: bytes,
            totalBytes: totalBytes,
            elapsed: elapsed,
            bytesPerSecond: smoothedRate ?? 0,
            estimatedTimeRemaining: remaining
        )
    }
}
