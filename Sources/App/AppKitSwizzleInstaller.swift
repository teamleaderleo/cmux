import AppKit
import ObjectiveC.runtime

/// Installs cmux's AppKit interception points exactly once.
///
/// The swizzled implementations remain next to the AppKit extensions that
/// implement the behavior. This type owns only the process-wide installation
/// policy so `AppDelegate` stays focused on composition and lifecycle.
enum AppKitSwizzleInstaller {
    private static let installation: Void = {
        exchange(
            on: NSWindow.self,
            original: #selector(NSWindow.performKeyEquivalent(with:)),
            swizzled: NSSelectorFromString("cmux_performKeyEquivalentWithEvent:")
        )
        exchange(
            on: NSWindow.self,
            original: #selector(NSWindow.makeFirstResponder(_:)),
            swizzled: NSSelectorFromString("cmux_makeFirstResponder:")
        )
        exchange(
            on: NSWindow.self,
            original: #selector(NSWindow.sendEvent(_:)),
            swizzled: NSSelectorFromString("cmux_sendEvent:")
        )
        exchange(
            on: NSApplication.self,
            original: #selector(NSApplication.sendEvent(_:)),
            swizzled: NSSelectorFromString("cmux_applicationSendEvent:")
        )
        exchange(
            on: NSApplication.self,
            original: #selector(NSApplication.sendAction(_:to:from:)),
            swizzled: NSSelectorFromString("cmux_sendAction:to:from:")
        )
        exchange(
            on: NSApplication.self,
            original: #selector(NSApplication.accessibilityAttributeValue(_:)),
            swizzled: NSSelectorFromString("cmux_accessibilityAttributeValue:")
        )
    }()

    static func install() {
        _ = installation
    }

    private static func exchange(on targetClass: AnyClass, original: Selector, swizzled: Selector) {
        guard let originalMethod = class_getInstanceMethod(targetClass, original),
              let swizzledMethod = class_getInstanceMethod(targetClass, swizzled) else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }
}
