import Foundation

/// Cancels a known reference signal's acoustic echo out of a captured signal, using the
/// vendored SpeexDSP MDF canceller (`SpeexEcho/mdf.c`) only - deliberately not its preprocessor's
/// residual-echo suppression (`speex_preprocess_run`/`SPEEX_PREPROCESS_SET_ECHO_STATE`). Measured
/// with real speech (macOS `say`, not synthetic tones) via an offline harness linking these same
/// vendored sources (echo path: 0.5x@40ms + 0.25x@65ms + 0.15x@90ms of the far end mixed into a
/// second, near-end voice for double-talk):
///
///   config                          echo reduction  near-end delta  near-end correlation
///   MDF only                        16.7 dB         0.0 dB          0.96
///   MDF + preprocess (defaults)     44.4 dB         1.2 dB          -0.13
///   MDF + preprocess (-20/-6)       16.7 dB         1.0 dB          -0.13
///   MDF + preprocess (-12/-3)       16.7 dB         1.0 dB          -0.13
///
/// The preprocessor's per-frame spectral gain mask is computed from the echo estimate whenever
/// an echo state is attached to it, essentially regardless of the ECHO_SUPPRESS/ECHO_SUPPRESS_
/// ACTIVE floor (MDF's residual is already below where that floor binds) or of denoise/AGC - so
/// on synthetic single-tone signals it looks harmless (the near-end and far-end occupy separate,
/// easily separated frequency bands), but on real overlapping speech it collapses the near-end's
/// waveform correlation with the clean reference to near zero in every configuration tried, even
/// though the average energy loss (`near-end delta`) looks small. That average-energy metric is
/// exactly what the original, since-fixed bug looked like from a user's side: the near-end voice
/// reads as "missing" from the transcript despite not being obviously quiet, because the
/// preprocessor's mask was mangling its waveform, not just its level, whenever the far end played.
/// MDF alone has no such stage to do that, and already clears a comfortable echo margin.
///
/// One instance covers a whole meeting-capture session: the adaptive filter's convergence must
/// carry across `cut()` calls, so callers create it once in `start()` and destroy it in `stop()`
/// rather than making a fresh one per cut.
///
/// Residual risk not addressed here: the mic (USB device) and system-tap (built-in output) are
/// separate Core Audio clock domains, not one aggregate device, so their sample counts can drift
/// apart by a few ppm over a long session; `cancelEcho`'s remainder carries that drift without
/// corrupting alignment (see below), but if it ever grows enough to walk the true echo delay
/// outside the 250 ms filter tail, cancellation would degrade over the course of a call. No
/// evidence of this in the reduction figures measured so far - add periodic cross-correlation
/// resync only if a long session is shown to need it.
final class EchoCanceller {
    static let frameSize: Int32 = 320 // 20 ms at 16 kHz - matches speex_echo_cancellation's per-call size
    static let filterLength: Int32 = 4000 // 250 ms echo tail at 16 kHz
    static let sampleRate: Int32 = 16000

    private let echoState: OpaquePointer

    // Samples carried over from the previous call because they didn't fill a whole frame yet;
    // prefixed onto the next call's input rather than dropped or zero-padded, so the canceller
    // never sees synthetic silence mid-stream and no captured audio goes missing.
    private var micRemainder: [Int16] = []
    private var referenceRemainder: [Int16] = []

    init(
        frameSize: Int32 = EchoCanceller.frameSize, filterLength: Int32 = EchoCanceller.filterLength,
        sampleRate: Int32 = EchoCanceller.sampleRate
    ) {
        echoState = speex_echo_state_init(frameSize, filterLength)
        var rate = sampleRate
        speex_echo_ctl(echoState, SPEEX_ECHO_SET_SAMPLING_RATE, &rate)
    }

    deinit {
        speex_echo_state_destroy(echoState)
    }

    /// Removes `reference`'s acoustic echo from `mic`. `reference` must be causally ahead of its
    /// echo in `mic` - true of a Core Audio process tap, which sees audio before the speaker plays
    /// it - which is the order the canceller's filter delay expects. `mic` and `reference` need
    /// not be the same length on any given call - their hardware callbacks fire independently, so
    /// a per-tick mismatch is normal - the shorter combined stream caps how many frames are
    /// processed and the excess of either stays in that channel's own remainder for the next call,
    /// same as a trailing partial frame; nothing is ever dropped or zero-padded mid-stream, so the
    /// reference is never shifted relative to the mic. Returns the cleaned mic samples together
    /// with the reference samples for that exact same span, always equal length even when the
    /// inputs weren't.
    func cancelEcho(mic: [Int16], reference: [Int16]) -> (mic: [Int16], reference: [Int16]) {
        let combinedMic = micRemainder + mic
        let combinedReference = referenceRemainder + reference
        let frameSize = Int(Self.frameSize)
        let frameCount = min(combinedMic.count, combinedReference.count) / frameSize
        let consumed = frameCount * frameSize

        var cleanedMic = [Int16](repeating: 0, count: consumed)
        var frame = [Int16](repeating: 0, count: frameSize)
        combinedMic.withUnsafeBufferPointer { micPtr in
            combinedReference.withUnsafeBufferPointer { refPtr in
                cleanedMic.withUnsafeMutableBufferPointer { cleanedPtr in
                    frame.withUnsafeMutableBufferPointer { framePtr in
                        for i in 0..<frameCount {
                            let offset = i * frameSize
                            speex_echo_cancellation(
                                echoState, micPtr.baseAddress! + offset, refPtr.baseAddress! + offset,
                                framePtr.baseAddress!)
                            (cleanedPtr.baseAddress! + offset).update(from: framePtr.baseAddress!, count: frameSize)
                        }
                    }
                }
            }
        }

        micRemainder = Array(combinedMic[consumed...])
        referenceRemainder = Array(combinedReference[consumed...])
        let referenceForOutput = Array(combinedReference[0..<consumed])
        return (cleanedMic, referenceForOutput)
    }

    /// Cancels and returns whatever partial audio `cancelEcho` is still holding back, by
    /// zero-padding each remainder up to one full frame (they may now differ in length - see
    /// `cancelEcho` - so each is padded from its own tail rather than assuming they match). Call
    /// once, after the last `cancelEcho` call of a session, so the last fraction of a second of
    /// audio is never silently dropped when a session ends.
    func flush() -> (mic: [Int16], reference: [Int16]) {
        guard !micRemainder.isEmpty || !referenceRemainder.isEmpty else { return ([], []) }
        let frameSize = Int(Self.frameSize)
        let micTail = Array(micRemainder.suffix(frameSize))
        let referenceTail = Array(referenceRemainder.suffix(frameSize))
        let validCount = max(micTail.count, referenceTail.count)

        var micFrame = micTail + [Int16](repeating: 0, count: frameSize - micTail.count)
        var referenceFrame = referenceTail + [Int16](repeating: 0, count: frameSize - referenceTail.count)
        var cleaned = [Int16](repeating: 0, count: frameSize)
        micFrame.withUnsafeMutableBufferPointer { micPtr in
            referenceFrame.withUnsafeMutableBufferPointer { refPtr in
                cleaned.withUnsafeMutableBufferPointer { cleanedPtr in
                    speex_echo_cancellation(echoState, micPtr.baseAddress!, refPtr.baseAddress!, cleanedPtr.baseAddress!)
                }
            }
        }

        micRemainder = []
        referenceRemainder = []
        return (Array(cleaned[0..<validCount]), Array(referenceFrame[0..<validCount]))
    }
}
