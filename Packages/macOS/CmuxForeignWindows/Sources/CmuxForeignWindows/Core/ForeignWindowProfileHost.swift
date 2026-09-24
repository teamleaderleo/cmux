/// A host that can show a profile's foreign window.
///
/// ``ForeignWindowHostView`` is the production conformance. The registry
/// tells a host whether it currently presents the window so it can show a
/// placeholder otherwise.
@MainActor
public protocol ForeignWindowProfileHost: AnyObject {
    /// Called when this host starts or stops presenting its profile's window.
    ///
    /// - Parameter isPresenting: `true` when the window now sits over this host.
    func foreignWindowProfileHostDidChangePresenting(_ isPresenting: Bool)
}
