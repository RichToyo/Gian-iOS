import OSLog

/// Debug traces for layout and keyboard issues that need a device to
/// reproduce. Debug-level messages cost nothing unless someone streams them:
///
///     xcrun simctl spawn <device> log stream --level debug \
///       --predicate 'subsystem == "dev.gian.ios"'
enum GianLog {
    static let layout = Logger(subsystem: "dev.gian.ios", category: "layout")
    static let keyboard = Logger(subsystem: "dev.gian.ios", category: "keyboard")
}
