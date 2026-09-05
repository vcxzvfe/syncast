import Foundation
import Darwin

/// Monotonic clock helper. Wraps `mach_absolute_time` so the sync logic uses
/// a single, well-defined time base across capture, scheduler, and IPC.
///
/// Per the sync brief, we use `mach_absolute_time` as the master clock and
/// schedule both local AUHAL render and AirPlay anchor times against it.
public enum Clock {
    private static let info: mach_timebase_info_data_t = {
        var i = mach_timebase_info_data_t()
        mach_timebase_info(&i)
        return i
    }()

    /// Current monotonic time in nanoseconds.
    public static func nowNs() -> UInt64 {
        hostTimeToNs(mach_absolute_time())
    }

    /// Convert host-time ticks to nanoseconds (for CoreAudio time stamps,
    /// which are in host-time units).
    ///
    /// Split into whole and remainder rather than multiplied outright: on
    /// Apple silicon the timebase is 125/3, and a raw `ticks * 125` overflows
    /// 64 bits after a few years of uptime. The LAN link stamps every packet
    /// from this, so a wrap here would not be a rounding error.
    public static func hostTimeToNs(_ ticks: UInt64) -> UInt64 {
        let numer = UInt64(info.numer)
        let denom = UInt64(info.denom)
        let whole = ticks / denom
        let rest = ticks % denom
        return whole &* numer &+ (rest &* numer) / denom
    }

    /// Convert nanoseconds to host-time ticks (for AudioUnit scheduled writes).
    public static func nsToHostTime(_ ns: UInt64) -> UInt64 {
        ns &* UInt64(info.denom) / UInt64(info.numer)
    }
}
