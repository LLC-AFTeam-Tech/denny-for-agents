import Darwin
import Foundation

/// CPU, memory and swap of this Mac, read straight from the kernel.
final class SystemStats {
    struct Snapshot {
        var cpu: Double?
        var memoryUsed: UInt64
        var memoryTotal: UInt64
        var compressed: UInt64
        var swapUsed: UInt64
        /// 1 normal, 2 warning, 4 critical (kern.memorystatus_vm_pressure_level).
        var pressure: Int
        var uptime: TimeInterval
    }

    private var lastTicks: (busy: UInt64, total: UInt64)?

    func sample() -> Snapshot {
        let pageSize = UInt64(vm_kernel_page_size)
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var used: UInt64 = 0
        var compressed: UInt64 = 0
        if vmResult == KERN_SUCCESS {
            // What Activity Monitor calls "Memory Used": app memory + wired + compressed.
            let app = UInt64(vm.internal_page_count) - min(UInt64(vm.internal_page_count), UInt64(vm.purgeable_count))
            compressed = UInt64(vm.compressor_page_count) * pageSize
            used = (app + UInt64(vm.wire_count)) * pageSize + compressed
        }
        return Snapshot(
            cpu: cpuUsage(),
            memoryUsed: used,
            memoryTotal: ProcessInfo.processInfo.physicalMemory,
            compressed: compressed,
            swapUsed: Self.swapUsed(),
            pressure: Self.sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1,
            uptime: ProcessInfo.processInfo.systemUptime
        )
    }

    /// Share of CPU time busy since the previous sample (nil on the first one).
    private func cpuUsage() -> Double? {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(load.cpu_ticks.0), system = UInt64(load.cpu_ticks.1)
        let idle = UInt64(load.cpu_ticks.2), nice = UInt64(load.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle
        defer { lastTicks = (busy, total) }
        guard let last = lastTicks, total > last.total else { return nil }
        return Double(busy - last.busy) / Double(total - last.total)
    }

    private static func swapUsed() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}
