import Testing
import Foundation
@testable import VoiceInk

/// Offline proof against a real captured Meeting Capture session
/// (`/tmp/vi-test/headset-1020.wav`, stereo 16 kHz Int16, left = mic, right = system, 136 s,
/// recorded on an AirPods Max headset mic with loud, steady train noise in the background).
/// Skipped (print + return) whenever the fixture isn't present.
struct MeetingVADFixtureTests {
    static let fixturePath = "/tmp/vi-test/headset-1020.wav"
    static let sampleRate = MeetingVAD.sampleRate

    /// 90th percentile of 20 ms frame energies - the "This Is Silence" calibration level
    /// (short blips can't drag it up). Kept local so the fixture proof is self-contained.
    static func pauseLevel(_ samples: [Int16]) -> Double {
        var energies: [Double] = []
        let frame = MeetingVAD.frameSamples
        var i = 0
        while i + frame <= samples.count {
            energies.append(MeetingVAD.rms(samples[i..<i + frame]))
            i += frame
        }
        guard !energies.isEmpty else { return 0 }
        energies.sort()
        return energies[Int(0.9 * Double(energies.count - 1))]
    }

    /// Runs `samples` through the persistent VAD in 0.5 s ticks (like the real drain timer) and
    /// returns the closed regions plus the longest confirmed-silence run seen.
    static func runVAD(_ samples: [Int16], state: MeetingVAD.State) -> (regions: [MeetingVAD.Region], maxConfirmedSilenceFrames: Int, state: MeetingVAD.State) {
        var state = state
        var regions: [MeetingVAD.Region] = []
        var maxSilence = 0
        let tick = Int(0.5 * Self.sampleRate)
        var i = 0
        while i < samples.count {
            let end = min(i + tick, samples.count)
            let (r, _, s) = MeetingVAD.process(Array(samples[i..<end]), state: state)
            regions += r
            state = s
            maxSilence = max(maxSilence, s.confirmedSilenceRunFrames)
            i = end
        }
        regions += MeetingVAD.finish(state: state)
        return (regions, maxSilence, state)
    }

    static func seconds(_ samples: Int) -> Double { Double(samples) / Self.sampleRate }

    /// `print` output isn't retrievable from the xcresult in CLI runs - mirror diagnostics to a
    /// file so the measurement is readable.
    static func emit(_ line: String) {
        print(line)
        let path = "/tmp/vi-fixture-diagnostic.txt"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write((line + "\n").data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? line.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Step 1 measurement: the UNCALIBRATED live condition. The mic's ambient level (~-31 dBFS
    /// RMS, steady train noise) sits far above the threshold the floor can converge to
    /// (absoluteFloor 150 + additive margin 200 = 350), so every pause keeps reading as speech -
    /// this is what produced "auto-send triggered: speechS=60.02 silenceS=0.00". Printed for the
    /// report; the speech-forever behaviour is asserted (it must hold until calibrated).
    @Test func fixtureUncalibratedVADReadsTheWholeSessionAsSpeech() {
        guard FileManager.default.fileExists(atPath: Self.fixturePath),
            let (mic, _) = try? MeetingRecordingWriter.readChannels(from: URL(fileURLWithPath: Self.fixturePath)),
            mic.count > Int(10 * Self.sampleRate)
        else {
        Self.emit("MeetingVADFixtureTests: fixture not present, skipping")
            return
        }

        let (regions, maxSilence, state) = Self.runVAD(mic, state: .initial)
        let s = Self.seconds
        Self.emit("UNCALIBRATED: regions=\(regions.count) inSpeechAtEnd=\(state.inSpeech) maxConfirmedSilenceS=\(String(format: "%.2f", Double(maxSilence) * 0.02)) noiseFloor=\(Int(state.noiseFloor))")
        for r in regions.prefix(20) {
        Self.emit("  region \(s(r.start))..\(s(r.end))s")
        }

        #expect(state.inSpeech, "uncalibrated, the loud steady floor keeps the channel in speech")
        #expect(maxSilence < MeetingVAD.confirmedSilenceFrames, "no 1s confirmed silence is ever recognized")
    }

    /// Step 3 regression: with the fixture's pause level calibrated into the floor, the speaker's
    /// pauses must read as silence (confirmed ~1 s silence runs) and the session must split into
    /// multiple regions instead of one 60 s+ span - while still detecting the speech itself.
    /// Fails before the relative-margin/pinned-floor fix: the seeded floor decays back toward
    /// `absoluteFloor` during the misread "speech" (stuck-speech nudge), the threshold collapses
    /// to ~350, and every pause reads as speech again.
    @Test func fixturePausesReadAsSilenceOnceThePauseLevelIsCalibrated() {
        guard FileManager.default.fileExists(atPath: Self.fixturePath),
            let (mic, _) = try? MeetingRecordingWriter.readChannels(from: URL(fileURLWithPath: Self.fixturePath)),
            mic.count > Int(10 * Self.sampleRate)
        else {
        Self.emit("MeetingVADFixtureTests: fixture not present, skipping")
            return
        }

        // Calibrate on a known-quiet stretch of the fixture (93.5s-95.5s, steady train noise
        // between sentences).
        let windowStart = Int(93.5 * Self.sampleRate)
        let windowEnd = Int(95.5 * Self.sampleRate)
        let floor = Self.pauseLevel(Array(mic[windowStart..<windowEnd]))
        Self.emit("CALIBRATED: pauseLevel=\(Int(floor)) from 93.5..95.5s")

        var seed = MeetingVAD.State(noiseFloor: floor)
        seed.pinnedNoiseFloor = floor
        let (regions, maxSilence, _) = Self.runVAD(mic, state: seed)
        let s = Self.seconds
        let longest = regions.map { $0.end - $0.start }.max() ?? 0
        let speechSamples = regions.reduce(0) { $0 + ($1.end - $1.start) }
        Self.emit("CALIBRATED RUN: regions=\(regions.count) longest=\(s(longest))s speechS=\(s(speechSamples)) maxConfirmedSilenceS=\(String(format: "%.2f", Double(maxSilence) * 0.02))")
        for r in regions.prefix(40) {
        Self.emit("  region \(s(r.start))..\(s(r.end))s")
        }

        #expect(maxSilence >= MeetingVAD.confirmedSilenceFrames, "pauses must register as confirmed (~1s) silence")
        #expect(regions.count >= 5, "the session must split into multiple regions, not one 60s+ span")
        #expect(longest <= Int(45 * Self.sampleRate), "no single region may span 45s+")
        #expect(speechSamples >= Int(30 * Self.sampleRate), "speech itself must still be detected")
    }
}
