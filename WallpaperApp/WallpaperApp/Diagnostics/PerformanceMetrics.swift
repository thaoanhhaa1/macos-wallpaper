import Darwin
import Foundation
import IOKit
import Observation

struct DroppedFrameStats: Equatable {
    var droppedFrames = 0
    var stalls = 0
    var observedBitrate: Double?
    var indicatedBitrate: Double?
    var mediaRequests = 0

    static let zero = DroppedFrameStats()

    static func + (lhs: DroppedFrameStats, rhs: DroppedFrameStats) -> DroppedFrameStats {
        DroppedFrameStats(
            droppedFrames: lhs.droppedFrames + rhs.droppedFrames,
            stalls: lhs.stalls + rhs.stalls,
            observedBitrate: rhs.observedBitrate ?? lhs.observedBitrate,
            indicatedBitrate: rhs.indicatedBitrate ?? lhs.indicatedBitrate,
            mediaRequests: lhs.mediaRequests + rhs.mediaRequests
        )
    }
}

struct PerformanceSample: Equatable {
    var cpuPercent: Double = 0
    var memoryBytes: UInt64 = 0
    var gpuPercent: Double?
    var droppedFrames = 0
    var droppedFramesPerSecond: Double = 0
    var stalls = 0
    var sampledAt: Date?
    var sampleDuration: TimeInterval = 0

    var memoryMegabytes: Double {
        Double(memoryBytes) / 1_048_576
    }

    var droppedFrameSummary: String {
        String(format: "%.1f/s (%d total)", droppedFramesPerSecond, droppedFrames)
    }

    var cpuSummary: String {
        String(format: "%.1f%%", cpuPercent)
    }

    var memorySummary: String {
        String(format: "%.1f MB", memoryMegabytes)
    }

    var gpuSummary: String {
        guard let gpuPercent else { return "unavailable" }
        return String(format: "%.1f%%", gpuPercent)
    }
}

@MainActor
@Observable
final class PerformanceMonitor {
    private(set) var sample = PerformanceSample()

    @ObservationIgnored var droppedFramesProvider: (() -> DroppedFrameStats)?
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var previousCPUTime: ProcessCPUTime?
    @ObservationIgnored private var previousDroppedFrames = DroppedFrameStats.zero
    @ObservationIgnored private var previousSampleDate: Date?

    private let interval: TimeInterval = 2

    func start() {
        guard loopTask == nil else { return }

        loopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.sampleNow()
                try? await Task.sleep(nanoseconds: UInt64(2_000_000_000))
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        previousCPUTime = nil
        previousDroppedFrames = .zero
        previousSampleDate = nil
    }

    func sampleNow() {
        let now = Date()
        let cpuTime = ProcessCPUTime.current()
        let memoryBytes = ProcessMemory.physicalFootprint()
        let gpuPercent = GPUProbe.utilization()
        let droppedFrames = droppedFramesProvider?() ?? .zero

        var cpuPercent: Double = 0
        var sampleDuration: TimeInterval = 0

        if let previousSampleDate, let previousCPUTime, let cpuTime {
            sampleDuration = now.timeIntervalSince(previousSampleDate)
            if sampleDuration > 0 {
                let cpuDelta = cpuTime.totalSeconds - previousCPUTime.totalSeconds
                cpuPercent = max(0, cpuDelta / sampleDuration * 100)
            }
        }

        var droppedFrameRate: Double = 0
        let droppedDelta = max(0, droppedFrames.droppedFrames - previousDroppedFrames.droppedFrames)
        if sampleDuration > 0 {
            droppedFrameRate = Double(droppedDelta) / sampleDuration
        }

        sample = PerformanceSample(
            cpuPercent: cpuPercent,
            memoryBytes: memoryBytes,
            gpuPercent: gpuPercent,
            droppedFrames: droppedFrames.droppedFrames,
            droppedFramesPerSecond: droppedFrameRate,
            stalls: droppedFrames.stalls,
            sampledAt: now,
            sampleDuration: previousSampleDate == nil ? 0 : sampleDuration
        )

        previousCPUTime = cpuTime
        previousDroppedFrames = droppedFrames
        previousSampleDate = now
    }

    deinit {
        loopTask?.cancel()
    }
}

private struct ProcessCPUTime {
    let userSeconds: Double
    let systemSeconds: Double
    let sampledAt: Date

    var totalSeconds: Double { userSeconds + systemSeconds }

    static func current() -> ProcessCPUTime? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else { return nil }

        let user = Double(info.user_time.seconds)
            + Double(info.user_time.microseconds) / 1_000_000
        let system = Double(info.system_time.seconds)
            + Double(info.system_time.microseconds) / 1_000_000
        return ProcessCPUTime(userSeconds: user, systemSeconds: system, sampledAt: Date())
    }
}

private enum ProcessMemory {
    static func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    rebound,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }
}

private enum GPUProbe {
    private static let utilizationKeys = [
        "Device Utilization %",
        "Renderer Utilization %",
        "Tiler Utilization %",
        "GPU Activity(%)"
    ]

    static func utilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOAccelerator"),
            &iterator
        ) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var highest: Double?

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            guard let statistics = IORegistryEntryCreateCFProperty(
                service,
                "PerformanceStatistics" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any] else {
                continue
            }

            for key in utilizationKeys {
                guard let value = statistics[key] as? NSNumber else { continue }
                highest = max(highest ?? 0, value.doubleValue)
                break
            }
        }

        return highest
    }
}
