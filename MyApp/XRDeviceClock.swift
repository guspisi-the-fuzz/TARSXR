import Foundation

/// Read-only snapshot of the phone clock. Never used for motion, watchdogs or deadlines.
/// Capture on every request; a Date retained from app launch would become stale.
enum XRDeviceClock {
    static func snapshot(
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> [String: Any] {
        [
            "schema_version": 1,
            "source": "xr_system_clock",
            "unix_seconds": now.timeIntervalSince1970,
            "utc_offset_seconds": timeZone.secondsFromGMT(for: now),
            "time_zone": timeZone.identifier
        ]
    }
}
