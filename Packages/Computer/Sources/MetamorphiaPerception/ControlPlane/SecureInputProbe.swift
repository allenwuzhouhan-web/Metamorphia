import Foundation

/// Shared probe for macOS's Secure Event Input Mode.
///
/// `IsSecureEventInputEnabled` lives in Carbon/HIToolbox and isn't exposed via
/// the Swift overlay. Two call sites used to duplicate the `dlsym` lookup
/// (`PrivacyFirewall` and `SemanticExecutor`); consolidating here gives one
/// source of truth — if Apple renames the symbol in a future macOS, there's
/// a single place to adapt.
///
/// The probe is cheap (one function call, ~ns), so there's no caching here.
/// Each caller pays a single dlsym once at module load via the lazy `let`.
public enum SecureInputProbe {

    /// `RTLD_DEFAULT` == `(void*) -2` on macOS. The Swift overlay doesn't
    /// expose the constant so we spell it out.
    private static let sym: (() -> Bool)? = {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let ptr = dlsym(rtldDefault, "IsSecureEventInputEnabled") else {
            return nil
        }
        return unsafeBitCast(ptr, to: (@convention(c) () -> Bool).self)
    }()

    /// True when Secure Event Input Mode is currently active. macOS enables
    /// this when password fields, sudo prompts, 1Password, or a secure
    /// terminal has focus — synthetic keystrokes (via CGEvent) are silently
    /// dropped while this is on. Callers that would synthesize keystrokes
    /// should probe first and refuse with a user-visible error.
    public static func isActive() -> Bool {
        sym?() ?? false
    }
}
