import AppKit
import CoreServices
public import Darwin
public import Foundation

/// Delivers a URL to one specific process as a GetURL Apple Event.
///
/// This is how macOS itself hands a URL to its handler app, so the receiver
/// treats it exactly like a clicked link. Addressing the event by process id
/// reaches one instance even when several copies of the same app run.
public enum ForeignWindowURLEvent {
    /// Sends `url` to `processIdentifier` without waiting for a reply.
    ///
    /// - Parameter url: The URL to open in the target process.
    /// - Parameter processIdentifier: The receiving process.
    /// - Throws: The Apple Event error when the event could not be sent.
    @MainActor
    public static func send(_ url: URL, to processIdentifier: pid_t) throws {
        let target = NSAppleEventDescriptor(processIdentifier: processIdentifier)
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kInternetEventClass),
            eventID: AEEventID(kAEGetURL),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(
            NSAppleEventDescriptor(string: url.absoluteString),
            forKeyword: AEKeyword(keyDirectObject)
        )
        _ = try event.sendEvent(options: [.noReply], timeout: 5)
    }
}
