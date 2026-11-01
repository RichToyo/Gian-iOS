import Foundation

/// The app/store coordinator owns one events consumer and one diagnostics
/// consumer for the lifetime of the service, never one consumer per View.
/// Event buffering is finite (512 newest). Overflow closes the connection,
/// drops mutation readiness and enqueues an explicit snapshot-required event.
/// Diagnostics are finite latest-status data (32 newest), not an event log.
/// Callers must resynchronize before treating a replacement connection as ready.
extension LiveGianClientService: GianClientEventSource {
    public var eventEpoch: Int { epoch }
}
