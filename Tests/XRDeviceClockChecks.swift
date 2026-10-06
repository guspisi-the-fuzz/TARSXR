import Foundation

@main struct XRDeviceClockChecks {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        let formatter = ISO8601DateFormatter()
        func date(_ value: String) -> Date { formatter.date(from: value)! }
        let now = date("2026-10-06T16:19:53Z")
        let saoPaulo = TimeZone(identifier: "America/Sao_Paulo")!
        let value = XRDeviceClock.snapshot(now: now, timeZone: saoPaulo)
        check(Set(value.keys) == Set(["schema_version", "source", "unix_seconds", "utc_offset_seconds", "time_zone"]), "bounded wire fields")
        check(value["schema_version"] as? Int == 1, "version")
        check(value["source"] as? String == "xr_system_clock", "phone source")
        check(value["time_zone"] as? String == "America/Sao_Paulo", "phone timezone")
        check(value["utc_offset_seconds"] as? Int == -10800, "Brazil offset")
        check(value["unix_seconds"] as? Double == now.timeIntervalSince1970, "exact supplied clock")
        check(JSONSerialization.isValidJSONObject(value), "serializable")
        let json = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: value)) as! [String: Any]
        check(json["unix_seconds"] as? Double == now.timeIntervalSince1970, "JSON round trip")
        let later = XRDeviceClock.snapshot(now: now.addingTimeInterval(60), timeZone: saoPaulo)
        check(later["unix_seconds"] as! Double - (value["unix_seconds"] as! Double) == 60, "snapshot not cached")
        let before = XRDeviceClock.snapshot(now: date("2026-10-07T02:59:59Z"), timeZone: saoPaulo)
        let after = XRDeviceClock.snapshot(now: date("2026-10-07T03:00:00Z"), timeZone: saoPaulo)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = saoPaulo
        check(calendar.component(.day, from: Date(timeIntervalSince1970: before["unix_seconds"] as! Double)) == 6, "local day before midnight")
        check(calendar.component(.day, from: Date(timeIntervalSince1970: after["unix_seconds"] as! Double)) == 7, "local day after midnight")
        let newYork = TimeZone(identifier: "America/New_York")!
        check(XRDeviceClock.snapshot(now: date("2026-01-15T12:00:00Z"), timeZone: newYork)["utc_offset_seconds"] as? Int == -18000, "winter offset uses capture date")
        check(XRDeviceClock.snapshot(now: date("2026-07-15T12:00:00Z"), timeZone: newYork)["utc_offset_seconds"] as? Int == -14400, "summer offset uses capture date")
        for offset in [-43200, -12600, 0, 19800, 20700, 45900, 50400] {
            let fixed = TimeZone(secondsFromGMT: offset)!
            check(XRDeviceClock.snapshot(now: now, timeZone: fixed)["utc_offset_seconds"] as? Int == offset, "fractional and edge offsets")
        }
        for second in 0..<1000 {
            let stamp = now.addingTimeInterval(Double(second))
            check(XRDeviceClock.snapshot(now: stamp, timeZone: saoPaulo)["unix_seconds"] as? Double == stamp.timeIntervalSince1970, "1000 independently refreshed snapshots")
        }
        let realBefore = Date().timeIntervalSince1970
        let real = XRDeviceClock.snapshot()
        let realAfter = Date().timeIntervalSince1970
        check((real["unix_seconds"] as! Double) >= realBefore && (real["unix_seconds"] as! Double) <= realAfter, "default reads OS clock at call time")
        check(real["time_zone"] as? String == TimeZone.current.identifier, "default uses system timezone")
        print("PASS: \(checks) clock checks, including 1000 refreshes; no network or hardware")
    }
}
