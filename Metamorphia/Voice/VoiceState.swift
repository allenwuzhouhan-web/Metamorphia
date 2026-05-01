import Foundation

/// Finite-state machine for Metamorphia's voice subsystem. Ported verbatim
/// from Executer's `VoiceState`. Shape must not change — `VoiceService` and
/// `VoiceGlowWindow` both switch on every case.
enum VoiceState: Equatable {
    /// Mic off, waiting for hotkey or for background wake-word mode to start.
    case idle
    /// Mic on, passively monitoring audio level for a wake word.
    case backgroundListening
    /// Hotkey pressed (or wake word detected); glow appearing, about to listen.
    case activated
    /// Mic on, capturing command speech with live partial transcripts.
    case listening
    /// Command finalized and dispatched to the agent; mic off.
    case dispatched
    /// Recoverable fault — UI layer decides what to do (usually show alert).
    case error(String)
}
