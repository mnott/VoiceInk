//
//  VoiceInkTests.swift
//  VoiceInkTests
//
//  Created by Prakash Joshi on 15/10/2024.
//

import Testing
import Foundation
import AppKit
import ApplicationServices
@testable import VoiceInk

struct VoiceInkTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

}

// MARK: - Pinned Destination: EnterRule defaults

struct PinnedDestinationEnterRuleDefaultsTests {
    @Test func noApplicationDefaultsToAppendingReturn() {
        // Terminals (iTerm2, Terminal.app) used to be silently special-cased to
        // default to true. That diverged from what the per-app list on screen showed,
        // so the implicit default is now unconditionally false - the list is the only
        // thing that turns Return submission on for any app, terminals included.
        #expect(!PinnedDestinationEnterRuleStore.defaultAppendReturn(forBundleIdentifier: "com.googlecode.iterm2"))
        #expect(!PinnedDestinationEnterRuleStore.defaultAppendReturn(forBundleIdentifier: "com.apple.Terminal"))
        #expect(!PinnedDestinationEnterRuleStore.defaultAppendReturn(forBundleIdentifier: "com.apple.TextEdit"))
        #expect(!PinnedDestinationEnterRuleStore.defaultAppendReturn(forBundleIdentifier: "com.apple.mail"))
        #expect(!PinnedDestinationEnterRuleStore.defaultAppendReturn(forBundleIdentifier: "com.apple.Notes"))
    }

    @Test func explicitRuleWinsRegardlessOfItsValue() {
        // iTerm2 must now be added to the list explicitly to get Return submission -
        // there is no built-in default anymore, for terminals or anything else.
        let rules = [
            PinnedDestinationEnterRule(bundleIdentifier: "com.googlecode.iterm2", appName: "iTerm2", appendReturn: true),
            PinnedDestinationEnterRule(bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit", appendReturn: false),
        ]

        #expect(
            PinnedDestinationEnterRuleStore.appendReturn(forBundleIdentifier: "com.googlecode.iterm2", rules: rules)
                == true)
        #expect(
            PinnedDestinationEnterRuleStore.appendReturn(forBundleIdentifier: "com.apple.TextEdit", rules: rules)
                == false)
    }

    @Test func bundleWithNoRuleFallsBackToTheUnconditionalDefault() {
        #expect(
            PinnedDestinationEnterRuleStore.appendReturn(forBundleIdentifier: "com.apple.Notes", rules: []) == false)
        // No more terminal special case: with no explicit rule, even iTerm2/Terminal
        // fall back to "insert only", same as any other app.
        #expect(
            PinnedDestinationEnterRuleStore.appendReturn(forBundleIdentifier: "com.apple.Terminal", rules: [])
                == false)
    }
}

// MARK: - Pinned Destination: EnterRule JSON round-trip

struct PinnedDestinationEnterRuleStoreRoundTripTests {
    @Test func rulesRoundTripThroughJSONEncodeDecode() throws {
        let rules = [
            PinnedDestinationEnterRule(bundleIdentifier: "com.googlecode.iterm2", appName: "iTerm2", appendReturn: true),
            PinnedDestinationEnterRule(bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit", appendReturn: false),
        ]

        let data = try #require(PinnedDestinationEnterRuleStore.encode(rules))
        let decoded = PinnedDestinationEnterRuleStore.decode(data)

        #expect(decoded == rules)
    }

    @Test func rulesRoundTripThroughUserDefaults() throws {
        let suiteName = "PinnedDestinationEnterRuleStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let rules = [
            PinnedDestinationEnterRule(bundleIdentifier: "com.apple.Terminal", appName: "Terminal", appendReturn: true)
        ]

        PinnedDestinationEnterRuleStore.saveRules(rules, to: defaults)
        let loaded = PinnedDestinationEnterRuleStore.loadRules(from: defaults)

        #expect(loaded == rules)
    }

    @Test func missingDataDecodesToEmptyRules() throws {
        let suiteName = "PinnedDestinationEnterRuleStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(PinnedDestinationEnterRuleStore.loadRules(from: defaults).isEmpty)
    }

    @Test func rulesRoundTripWithAllThreeFlagsPreserved() throws {
        // Settings export/import relies on this exact round-trip: it ships
        // `PinnedDestinationEnterRule` as structured JSON rather than an opaque blob, so
        // every one of its three independent flags - not just `appendReturn` - must survive
        // encode/decode unchanged.
        let rules = [
            PinnedDestinationEnterRule(
                bundleIdentifier: "com.googlecode.iterm2", appName: "iTerm2", appendReturn: true,
                sendInsertPrefix: true, appendSpace: false)
        ]

        let data = try #require(PinnedDestinationEnterRuleStore.encode(rules))
        let decoded = PinnedDestinationEnterRuleStore.decode(data)

        #expect(decoded == rules)
        #expect(decoded.first?.appendReturn == true)
        #expect(decoded.first?.sendInsertPrefix == true)
        #expect(decoded.first?.appendSpace == false)
    }
}

// MARK: - Pinned Destination: toggle state machine

struct PinnedDestinationToggleStateMachineTests {
    private let sessionA = PinnedTarget.iTermSession(id: "w0t0p0:AAAA", appName: "iTerm2", sessionName: "session A")
    private let sessionB = PinnedTarget.iTermSession(id: "w0t1p0:BBBB", appName: "iTerm2", sessionName: "session B")

    @Test func noPinAndNoFocusIsRefused() {
        let decision = PinnedDestinationManager.decideToggle(existingPin: nil, focusedCandidate: nil)
        #expect(decision == .refused)
    }

    @Test func noPinPinsTheFocusedDestination() {
        let decision = PinnedDestinationManager.decideToggle(existingPin: nil, focusedCandidate: sessionA)
        #expect(decision == .pin(sessionA))
    }

    @Test func toggleOnTheSamePinnedTargetUnpins() {
        let decision = PinnedDestinationManager.decideToggle(existingPin: sessionA, focusedCandidate: sessionA)
        #expect(decision == .unpin)
    }

    @Test func toggleOnADifferentTargetRePins() {
        let decision = PinnedDestinationManager.decideToggle(existingPin: sessionA, focusedCandidate: sessionB)
        #expect(decision == .rePin(sessionB))
    }

    @Test func existingPinWithNothingFocusedIsRefused() {
        let decision = PinnedDestinationManager.decideToggle(existingPin: sessionA, focusedCandidate: nil)
        #expect(decision == .refused)
    }

    @Test func identityIgnoresSessionNameSoATitleChangeIsStillTheSamePin() {
        // `sessionName` is display metadata only (see `PinnedTarget.displayLabel`) - a
        // pane's title changing must never look like toggling onto a different pin.
        let renamed = PinnedTarget.iTermSession(id: "w0t0p0:AAAA", appName: "iTerm2", sessionName: "renamed")
        #expect(sessionA == renamed)
        let decision = PinnedDestinationManager.decideToggle(existingPin: sessionA, focusedCandidate: renamed)
        #expect(decision == .unpin)
    }
}

// MARK: - Pinned Destination: display label

struct PinnedTargetDisplayLabelTests {
    @Test func iTermSessionWithNameShowsAppNameAndSessionName() {
        let target = PinnedTarget.iTermSession(id: "w0t0p0:AAAA", appName: "iTerm2", sessionName: "build")
        #expect(target.displayLabel == "iTerm2 – build")
    }

    @Test func iTermSessionWithNoNameFallsBackToAppNameOnly() {
        let target = PinnedTarget.iTermSession(id: "w0t0p0:AAAA", appName: "iTerm2", sessionName: nil)
        #expect(target.displayLabel == "iTerm2")
    }

    @Test func iTermSessionWithEmptyNameFallsBackToAppNameOnly() {
        // Never show an empty or placeholder-looking label - an empty captured name is
        // treated the same as no name at all.
        let target = PinnedTarget.iTermSession(id: "w0t0p0:AAAA", appName: "iTerm2", sessionName: "")
        #expect(target.displayLabel == "iTerm2")
    }

    @Test func veryLongSessionNameIsTruncated() {
        let longName = String(repeating: "x", count: 200)
        let target = PinnedTarget.iTermSession(id: "w0t0p0:AAAA", appName: "iTerm2", sessionName: longName)
        #expect(target.displayLabel.count < longName.count)
        #expect(target.displayLabel.hasPrefix("iTerm2 – "))
        #expect(target.displayLabel.hasSuffix("…"))
    }

    @Test func axElementWithWindowTitleShowsAppNameAndWindowTitle() {
        let axApp = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let target = PinnedTarget.axElement(
            element: axApp, appName: "Notes", bundleID: "com.apple.Notes", pid: 1, windowTitle: "Shopping List")
        #expect(target.displayLabel == "Notes – Shopping List")
    }

    @Test func axElementWithNoWindowTitleFallsBackToAppNameOnly() {
        let axApp = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let target = PinnedTarget.axElement(
            element: axApp, appName: "Notes", bundleID: "com.apple.Notes", pid: 1, windowTitle: nil)
        #expect(target.displayLabel == "Notes")
    }
}

// MARK: - Pinned Destination: iTerm2 session identity parsing

struct PinnedDestinationSessionIdentityParsingTests {
    @Test func idAndNameAreSplitOnTheFirstLinefeed() {
        let identity = PinnedDestinationManager.splitSessionIdentity("w0t0p0:AAAA\nbuild")
        #expect(identity.id == "w0t0p0:AAAA")
        #expect(identity.name == "build")
    }

    @Test func emptyNameAfterTheSeparatorBecomesNilRatherThanAnEmptyString() {
        let identity = PinnedDestinationManager.splitSessionIdentity("w0t0p0:AAAA\n")
        #expect(identity.id == "w0t0p0:AAAA")
        #expect(identity.name == nil)
    }

    @Test func onlyTheFirstLinefeedIsTreatedAsTheSeparator() {
        // An (unlikely) embedded newline in the session's own name just becomes part
        // of the name, rather than corrupting the split.
        let identity = PinnedDestinationManager.splitSessionIdentity("w0t0p0:AAAA\nbuild\nlogs")
        #expect(identity.id == "w0t0p0:AAAA")
        #expect(identity.name == "build\nlogs")
    }

    @Test func missingSeparatorTreatsTheWholeStringAsTheId() {
        // Defensive fallback only - `captureITermSession`'s script always includes the
        // separator; this just avoids losing the id entirely if that ever changed.
        let identity = PinnedDestinationManager.splitSessionIdentity("w0t0p0:AAAA")
        #expect(identity.id == "w0t0p0:AAAA")
        #expect(identity.name == nil)
    }
}

// MARK: - Pinned Destination: AX delivery re-resolution decision

struct PinnedDestinationAXDeliveryResolutionTests {
    @Test func aliveCachedElementIsUsedDirectly() {
        // Even if the app or a fresh focus lookup would also succeed, the still-valid
        // cached element is cheaper, so it must win regardless of the other inputs.
        let decision = PinnedDestinationManager.decideAXDeliveryResolution(
            cachedElementAlive: true, appAlive: false, reResolvedElementPresent: false
        )
        #expect(decision == .useCachedElement)
    }

    @Test func deadElementWithDeadAppReportsGone() {
        // `.reportGone` only ever clears the (cosmetic) iTerm tint marking and copies
        // the text to the clipboard - never the pin itself. Only an explicit user
        // unpin does that; see `PinnedDestinationManager.reportGone`.
        let decision = PinnedDestinationManager.decideAXDeliveryResolution(
            cachedElementAlive: false, appAlive: false, reResolvedElementPresent: false
        )
        #expect(decision == .reportGone)
    }

    @Test func deadElementWithLiveAppAndResolvedElementUsesReResolvedElement() {
        let decision = PinnedDestinationManager.decideAXDeliveryResolution(
            cachedElementAlive: false, appAlive: true, reResolvedElementPresent: true
        )
        #expect(decision == .useReResolvedElement)
    }

    @Test func deadElementWithLiveAppAndNothingFocusedReportsNothingFocused() {
        let decision = PinnedDestinationManager.decideAXDeliveryResolution(
            cachedElementAlive: false, appAlive: true, reResolvedElementPresent: false
        )
        #expect(decision == .reportNothingFocused)
    }
}

// MARK: - Pinned Destination: AppleScript error classification

struct PinnedDestinationAppleScriptErrorClassificationTests {
    @Test func permissionDeniedCodesClassifyAsPermissionDenied() {
        // errAEEventNotPermitted and errAEEventWouldRequireUserConsent: Automation
        // access has not been granted. The pin must never be discarded for these.
        #expect(PinnedDestinationManager.classifyAppleScriptError(code: -1743) == .permissionDenied)
        #expect(PinnedDestinationManager.classifyAppleScriptError(code: -1744) == .permissionDenied)
    }

    @Test func procNotFoundClassifiesAsTargetNotRunningRatherThanPermissionDenied() {
        // -600 (procNotFound) means the target app is not running at all. This is
        // kept as its own case instead of being folded into `.permissionDenied`,
        // because the correct fix is different ("launch the app" vs. "grant
        // Automation access") - see the comment on `classifyAppleScriptError`.
        #expect(PinnedDestinationManager.classifyAppleScriptError(code: -600) == .targetNotRunning)
    }

    @Test func unrelatedErrorCodeClassifiesAsGenericFailure() {
        #expect(PinnedDestinationManager.classifyAppleScriptError(code: -1728) == .other)
    }

    @Test func nonErrorCodeIsNotMisclassifiedAsPermissionDenied() {
        // 0 (noErr) should never reach this function in practice - `runAppleScript`
        // only classifies once `executeAndReturnError` has actually produced an error
        // dictionary - but a benign/unexpected code must not be read as a permission
        // failure, which would wrongly leave a genuinely broken pin in place.
        #expect(PinnedDestinationManager.classifyAppleScriptError(code: 0) != .permissionDenied)
    }
}

// MARK: - Pinned Destination: transient-failure retry decision

struct PinnedDestinationRetryDecisionTests {
    @Test func retriesOnceWhenResultIsAFailureAndDestinationIsStillRunning() async {
        var attemptCount = 0
        let result = await PinnedDestinationManager.retryingIfStillRunning(
            result: "failed",
            isFailure: { $0 == "failed" },
            stillRunning: true,
            attempt: {
                attemptCount += 1
                return "ok"
            }
        )
        #expect(result == "ok")
        #expect(attemptCount == 1)
    }

    @Test func doesNotRetryWhenTheResultIsAlreadySuccessful() async {
        var attemptCount = 0
        let result = await PinnedDestinationManager.retryingIfStillRunning(
            result: "ok",
            isFailure: { $0 == "failed" },
            stillRunning: true,
            attempt: {
                attemptCount += 1
                return "ok"
            }
        )
        #expect(result == "ok")
        #expect(attemptCount == 0)
    }

    @Test func doesNotRetryWhenTheDestinationIsConfirmedNotRunning() async {
        // Retrying a destination that is verifiably gone would only delay reporting a
        // real failure - see `PinnedDestinationManager.retryingIfStillRunning`.
        var attemptCount = 0
        let result = await PinnedDestinationManager.retryingIfStillRunning(
            result: "failed",
            isFailure: { $0 == "failed" },
            stillRunning: false,
            attempt: {
                attemptCount += 1
                return "ok"
            }
        )
        #expect(result == "failed")
        #expect(attemptCount == 0)
    }

    @Test func retriedResultIsReturnedEvenIfItIsStillAFailure() async {
        let result = await PinnedDestinationManager.retryingIfStillRunning(
            result: "failed",
            isFailure: { $0 == "failed" },
            stillRunning: true,
            attempt: { "failed" }
        )
        #expect(result == "failed")
    }
}

// MARK: - AppleScript serial executor

struct AppleScriptSerialExecutorTests {
    // Not a fake/mock of NSAppleScript itself - AppleScript execution cannot be faked
    // without a live target (see `runAppleScript`'s own doc comment on why this app
    // must not launch/drive one to develop or test this). This instead proves the
    // property the serialization exists for: many overlapping callers of the shared
    // executor are never actually running at the same time, using a plain (racy if
    // ever actually concurrent) counter as the detector - if the queue were NOT
    // serial, this would very likely observe an overlap.
    @Test func concurrentCallsNeverOverlap() async {
        final class OverlapTracker: @unchecked Sendable {
            var isRunning = false
            var overlapDetected = false
            var completedCount = 0
        }
        let tracker = OverlapTracker()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    await AppleScriptSerialExecutor.run {
                        if tracker.isRunning {
                            tracker.overlapDetected = true
                        }
                        tracker.isRunning = true
                        usleep(1000)
                        tracker.isRunning = false
                        tracker.completedCount += 1
                    }
                }
            }
        }

        #expect(!tracker.overlapDetected)
        #expect(tracker.completedCount == 50)
    }
}

// MARK: - Pinned Destination: AppleScript text literal building

struct PinnedDestinationAppleScriptTextLiteralTests {
    private let quote = "\""
    private let backslash = "\\"

    @Test func plainTextBecomesASingleQuotedLiteral() {
        let result = PinnedDestinationManager.appleScriptTextLiteral(for: "hello")
        #expect(result == quote + "hello" + quote)
    }

    @Test func doubleQuotesAreEscaped() {
        let input = quote + "hi" + quote  // the text `"hi"`
        let result = PinnedDestinationManager.appleScriptTextLiteral(for: input)
        let expectedInner = backslash + quote + "hi" + backslash + quote
        #expect(result == quote + expectedInner + quote)
    }

    @Test func backslashesAreEscaped() {
        let input = "a" + backslash + "b"  // the text `a\b`
        let result = PinnedDestinationManager.appleScriptTextLiteral(for: input)
        let expectedInner = "a" + backslash + backslash + "b"
        #expect(result == quote + expectedInner + quote)
    }

    @Test func embeddedNewlineIsRejoinedWithTheLinefeedConstant() {
        // A raw newline cannot appear inside a single AppleScript string literal - it
        // would terminate the literal early and produce invalid AppleScript, which is
        // then misreported as an unrelated delivery failure. The generated expression
        // must stay on one line.
        let result = PinnedDestinationManager.appleScriptTextLiteral(for: "foo\nbar")
        #expect(result == quote + "foo" + quote + " & linefeed & " + quote + "bar" + quote)
    }
}

// MARK: - Pinned Destination: EnterRule sendInsertPrefix defaults

struct PinnedDestinationSendInsertPrefixDefaultsTests {
    @Test func noApplicationDefaultsToNotSendingInsertPrefix() {
        // Same "no implicit per-app default" reasoning as appendReturn: only an
        // explicit rule in the list turns this on, terminals included.
        #expect(!PinnedDestinationEnterRuleStore.defaultSendInsertPrefix(forBundleIdentifier: "com.googlecode.iterm2"))
        #expect(!PinnedDestinationEnterRuleStore.defaultSendInsertPrefix(forBundleIdentifier: "com.apple.Terminal"))
    }

    @Test func explicitRuleWinsRegardlessOfItsValue() {
        let rules = [
            PinnedDestinationEnterRule(
                bundleIdentifier: "com.googlecode.iterm2", appName: "iTerm2", appendReturn: false,
                sendInsertPrefix: true)
        ]
        #expect(
            PinnedDestinationEnterRuleStore.sendInsertPrefix(forBundleIdentifier: "com.googlecode.iterm2", rules: rules)
                == true)
    }

    @Test func bundleWithNoRuleFallsBackToTheUnconditionalDefault() {
        #expect(
            PinnedDestinationEnterRuleStore.sendInsertPrefix(forBundleIdentifier: "com.googlecode.iterm2", rules: [])
                == false)
    }
}

// MARK: - Pinned Destination: EnterRule backward-compatible decoding

struct PinnedDestinationEnterRuleBackwardCompatibilityTests {
    @Test func oldFormatRuleWithoutTheFlagDecodesWithItFalse() throws {
        // This is the exact shape of rules persisted before `sendInsertPrefix` existed:
        // no key for it at all, not even `false`. A previously stored rule list must
        // keep decoding cleanly - `PinnedDestinationEnterRuleStore.decode` silently
        // drops the whole array on any decode failure, so a missing-key throw here
        // would look like "the user's saved rules just vanished."
        let oldFormatJSON = """
            [
                {
                    "bundleIdentifier": "com.googlecode.iterm2",
                    "appName": "iTerm2",
                    "appendReturn": true
                }
            ]
            """
        let data = try #require(oldFormatJSON.data(using: .utf8))
        let decoded = PinnedDestinationEnterRuleStore.decode(data)

        #expect(decoded.count == 1)
        #expect(decoded.first?.bundleIdentifier == "com.googlecode.iterm2")
        #expect(decoded.first?.appendReturn == true)
        #expect(decoded.first?.sendInsertPrefix == false)
    }

    @Test func newFormatRoundTripsBothFlagsCorrectly() throws {
        let rules = [
            PinnedDestinationEnterRule(
                bundleIdentifier: "com.googlecode.iterm2", appName: "iTerm2", appendReturn: true,
                sendInsertPrefix: true),
            PinnedDestinationEnterRule(
                bundleIdentifier: "com.apple.Terminal", appName: "Terminal", appendReturn: false,
                sendInsertPrefix: true),
            PinnedDestinationEnterRule(
                bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit", appendReturn: true,
                sendInsertPrefix: false),
        ]

        let data = try #require(PinnedDestinationEnterRuleStore.encode(rules))
        let decoded = PinnedDestinationEnterRuleStore.decode(data)

        #expect(decoded == rules)
        #expect(decoded.map(\.appendReturn) == [true, false, true])
        #expect(decoded.map(\.sendInsertPrefix) == [true, true, false])
    }

    @Test func theTwoFlagsAreIndependentThroughTheAccessor() {
        // Every combination must resolve independently via the accessor the delivery
        // path actually calls - neither flag may leak into or gate the other.
        let bundleIdentifier = "com.example.app"
        let combinations: [(appendReturn: Bool, sendInsertPrefix: Bool)] = [
            (false, false), (true, false), (false, true), (true, true),
        ]

        for combination in combinations {
            let rules = [
                PinnedDestinationEnterRule(
                    bundleIdentifier: bundleIdentifier, appName: "Example", appendReturn: combination.appendReturn,
                    sendInsertPrefix: combination.sendInsertPrefix)
            ]

            #expect(
                PinnedDestinationEnterRuleStore.appendReturn(forBundleIdentifier: bundleIdentifier, rules: rules)
                    == combination.appendReturn)
            #expect(
                PinnedDestinationEnterRuleStore.sendInsertPrefix(forBundleIdentifier: bundleIdentifier, rules: rules)
                    == combination.sendInsertPrefix)
        }
    }
}

// MARK: - Normal (unpinned) delivery: per-app rule precedence

struct NormalDeliveryPrecedenceTests {
    @Test func ruleWithAppendReturnSubmitsAndAddsNoSpace() {
        // The operator's original complaint in reverse: an explicit rule that wants Return
        // must actually submit, even though the app-wide preferences below are never
        // consulted once a rule exists.
        let rule = PinnedDestinationEnterRule(
            bundleIdentifier: "com.apple.Terminal", appName: "Terminal", appendReturn: true)
        let decision = PinnedDestinationEnterRuleStore.deliveryDecision(
            forRule: rule,
            modeAutoSendKeyIsNone: true,
            globalAutoEnterAfterTranscription: false,
            globalAppendTrailingSpace: false
        )
        #expect(decision.submit == true)
        #expect(decision.appendSpace == false)
    }

    @Test func ruleWithAppendReturnFalseAndAppendSpaceTrueContinuesRatherThanSubmitting() {
        // This is the exact regression: a per-app rule configured for "insert and add a
        // space" must not submit just because the global "Auto Enter after transcription"
        // preference happens to be on - the rule is the most specific scope and wins.
        let rule = PinnedDestinationEnterRule(
            bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit", appendReturn: false,
            appendSpace: true)
        let decision = PinnedDestinationEnterRuleStore.deliveryDecision(
            forRule: rule,
            modeAutoSendKeyIsNone: true,
            globalAutoEnterAfterTranscription: true,
            globalAppendTrailingSpace: false
        )
        #expect(decision.submit == false)
        #expect(decision.appendSpace == true)
    }

    @Test func noRuleWithGlobalAutoEnterOnSubmits() {
        // With nothing configured for this app, behavior must stay exactly as it was
        // before per-app rules reached this path: the global toggle alone decides.
        let decision = PinnedDestinationEnterRuleStore.deliveryDecision(
            forRule: nil,
            modeAutoSendKeyIsNone: true,
            globalAutoEnterAfterTranscription: true,
            globalAppendTrailingSpace: false
        )
        #expect(decision.submit == true)
    }

    @Test func noRuleWithGlobalAutoEnterOffAndAppendSpaceOnAddsSpaceWithoutSubmitting() {
        let decision = PinnedDestinationEnterRuleStore.deliveryDecision(
            forRule: nil,
            modeAutoSendKeyIsNone: true,
            globalAutoEnterAfterTranscription: false,
            globalAppendTrailingSpace: true
        )
        #expect(decision.submit == false)
        #expect(decision.appendSpace == true)
    }

    @Test func noRuleWithAModeAutoSendKeyAlreadyChosenSubmitsRegardlessOfTheGlobalToggle() {
        // The mode's own choice is itself an app-wide (not per-app) preference, so with no
        // rule present it still wins over the global fallback exactly as before.
        let decision = PinnedDestinationEnterRuleStore.deliveryDecision(
            forRule: nil,
            modeAutoSendKeyIsNone: false,
            globalAutoEnterAfterTranscription: false,
            globalAppendTrailingSpace: false
        )
        #expect(decision.submit == true)
    }

    @Test func ruleSendInsertPrefixIsCarriedThroughRegardlessOfAppendReturn() {
        for appendReturn in [false, true] {
            let rule = PinnedDestinationEnterRule(
                bundleIdentifier: "com.googlecode.iterm2", appName: "iTerm2", appendReturn: appendReturn,
                sendInsertPrefix: true)
            let decision = PinnedDestinationEnterRuleStore.deliveryDecision(
                forRule: rule,
                modeAutoSendKeyIsNone: true,
                globalAutoEnterAfterTranscription: false,
                globalAppendTrailingSpace: false
            )
            #expect(decision.sendInsertPrefix == true)
        }
    }

    @Test func noRuleNeverSendsAnInsertPrefix() {
        // There is no per-app list entry to source this flag from once no rule applies -
        // an insert-mode prefix is meaningless without a specific app to reason about.
        let decision = PinnedDestinationEnterRuleStore.deliveryDecision(
            forRule: nil,
            modeAutoSendKeyIsNone: true,
            globalAutoEnterAfterTranscription: true,
            globalAppendTrailingSpace: true
        )
        #expect(decision.sendInsertPrefix == false)
    }
}

// MARK: - Normal (unpinned) delivery: per-app rule lookup

struct NormalDeliveryRuleLookupTests {
    @Test func lookupReturnsTheMatchingRule() {
        let rule = PinnedDestinationEnterRule(
            bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit", appendReturn: true)
        let found = PinnedDestinationEnterRuleStore.rule(
            forBundleIdentifier: "com.apple.TextEdit", rules: [rule])
        #expect(found == rule)
    }

    @Test func lookupReturnsNilRatherThanAFabricatedDefaultWhenNoRuleExists() {
        // Distinct from `appendReturn`/`sendInsertPrefix`/`appendSpace`, which each return a
        // default value with no rule present - this lookup must expose the absence itself so
        // `deliveryDecision` can tell "no rule" apart from "a rule with every flag off".
        let found = PinnedDestinationEnterRuleStore.rule(
            forBundleIdentifier: "com.apple.TextEdit", rules: [])
        #expect(found == nil)
    }
}

// MARK: - Pinned Destination: iTerm2 delivery step sequencing

struct PinnedDestinationITermDeliveryStepsTests {
    private let textLiteral = "\"hello\""

    @Test func plainDeliveryIsJustTheTextWrite() {
        let steps = PinnedDestinationManager.iTermDeliverySteps(
            textLiteral: textLiteral, sendInsertPrefix: false)
        #expect(steps.count == 1)
        #expect(steps[0].statement == "write text \(textLiteral) newline no")
        #expect(steps[0].role == .text)
        #expect(steps[0].settleDelaySeconds == 0)
    }

    @Test func writeStepsNeverContainACarriageReturn() {
        // Submission is NOT a write step: pty CR bytes are interpreted
        // nondeterministically by paste-coalescing TUIs (observed live: the same build
        // submitted, inserted a newline, and did nothing across three consecutive
        // dictations), so the submitting Return is delivered as its own mechanism at
        // submit time - see `decideITermSubmitPlan`. The builder must therefore never
        // emit a CR regardless of options.
        for sendInsertPrefix in [false, true] {
            let steps = PinnedDestinationManager.iTermDeliverySteps(
                textLiteral: textLiteral, sendInsertPrefix: sendInsertPrefix)
            #expect(!steps.contains { $0.statement.contains("return") })
            #expect(!steps.contains { $0.role == .submit })
        }
    }

    @Test func insertPrefixProducesItsOwnStepBeforeText() {
        let steps = PinnedDestinationManager.iTermDeliverySteps(
            textLiteral: textLiteral, sendInsertPrefix: true)
        #expect(steps.count == 2)
        // `i` followed by DEL, so the pair is self-cancelling whichever mode the target
        // started in - see `insertModePrefixStatement`.
        #expect(steps[0].statement == "write text (\"i\" & (character id 127)) newline no")
        #expect(steps[0].role == .insertModePrefix)
        #expect(steps[0].settleDelaySeconds > 0)
        #expect(steps[1].statement == "write text \(textLiteral) newline no")
        #expect(steps[1].role == .text)
        #expect(steps[1].settleDelaySeconds == 0)
    }
}


// MARK: - Pinned Destination: trailing space

struct PinnedDestinationTrailingSpaceTests {
    @Test func aSpaceIsAddedWhenTheTextIsNotSubmitted() {
        let text = PinnedDestinationEnterRuleStore.deliveredText("hello", appendReturn: false, appendSpace: true)
        #expect(text == "hello ")
    }

    @Test func noSpaceIsAddedWhenTheTextIsSubmitted() {
        // After a Return the field is gone, so a trailing space would either vanish or
        // end up in front of whatever the user types next.
        let text = PinnedDestinationEnterRuleStore.deliveredText("hello", appendReturn: true, appendSpace: true)
        #expect(text == "hello")
    }

    @Test func noSpaceWhenTurnedOff() {
        #expect(PinnedDestinationEnterRuleStore.deliveredText("hello", appendReturn: false, appendSpace: false) == "hello")
    }

    @Test func rulesPersistedBeforeThisOptionExistedDefaultToAddingASpace() throws {
        // Decoding must not throw on the missing key - the synthesized Decodable would,
        // and a throw here silently drops the user's entire stored rule list.
        let legacy = Data(
            #"[{"bundleIdentifier":"com.example.app","appName":"Example","appendReturn":true}]"#.utf8)
        let rules = PinnedDestinationEnterRuleStore.decode(legacy)
        #expect(rules.count == 1)
        #expect(rules.first?.appendSpace == true)
        #expect(rules.first?.sendInsertPrefix == false)
    }
}

// MARK: - Pinned Destination: iTerm2 background color parsing

struct PinnedDestinationITermColorTests {
    @Test func parsesThreeComponents() {
        let color = PinnedDestinationManager.parseITermColor("11999,3999,4000")
        #expect(color == PinnedDestinationManager.ITermColor(red: 11999, green: 3999, blue: 4000))
    }

    @Test func parsesAllZeroesWithoutCollapsingThem() {
        // The reason the script formats and joins the components itself: AppleScript
        // coerces the color list {0, 0, 0} to the string "000", which cannot be split
        // back into three components. A black background is extremely common, so this
        // is the case that would silently break restoring a real user's color.
        let color = PinnedDestinationManager.parseITermColor("0,0,0")
        #expect(color == PinnedDestinationManager.ITermColor(red: 0, green: 0, blue: 0))
    }

    @Test func toleratesSurroundingWhitespace() {
        let color = PinnedDestinationManager.parseITermColor(" 100 , 200 , 300 ")
        #expect(color == PinnedDestinationManager.ITermColor(red: 100, green: 200, blue: 300))
    }

    @Test func rejectsAnythingUnparseable() {
        // Every one of these must fail rather than guess: without a trustworthy original
        // color the caller skips tinting entirely, which is far better than applying a
        // tint it could never undo.
        #expect(PinnedDestinationManager.parseITermColor(nil) == nil)
        #expect(PinnedDestinationManager.parseITermColor("") == nil)
        #expect(PinnedDestinationManager.parseITermColor("000") == nil)
        #expect(PinnedDestinationManager.parseITermColor("1,2") == nil)
        #expect(PinnedDestinationManager.parseITermColor("1,2,3,4") == nil)
        #expect(PinnedDestinationManager.parseITermColor("red,green,blue") == nil)
    }

    @Test func buildsASettableAppleScriptStatement() {
        let statement = PinnedDestinationManager.setBackgroundColorStatement(
            PinnedDestinationManager.ITermColor(red: 1, green: 2, blue: 3))
        #expect(statement == "set background color to {1, 2, 3}")
    }
}

// MARK: - Pinned Destination: hex <-> ITermColor conversion (user-chosen tint color)

struct PinnedDestinationITermTintHexConversionTests {
    @Test func blackHexParsesToAllZeroComponents() {
        let tint = PinnedDestinationManager.itermColor(fromHexString: "000000")
        #expect(
            tint
                == PinnedDestinationManager.ITermTintColor(
                    color: PinnedDestinationManager.ITermColor(red: 0, green: 0, blue: 0), alpha: 1.0))
    }

    @Test func whiteHexParsesToFullScaleComponents() {
        // The case that catches the classic off-by-a-bit trap: 0xFF must scale to 65535 (the
        // true top of iTerm2's 16-bit range) via *257, not to 65280 (0xFF00) via *256/<<8 -
        // that shift-based version is never obviously wrong, it just quietly desaturates every
        // color pulled through it.
        let tint = PinnedDestinationManager.itermColor(fromHexString: "FFFFFF")
        #expect(
            tint
                == PinnedDestinationManager.ITermTintColor(
                    color: PinnedDestinationManager.ITermColor(red: 65535, green: 65535, blue: 65535), alpha: 1.0))
    }

    @Test func acceptsALeadingHash() {
        let tint = PinnedDestinationManager.itermColor(fromHexString: "#000000")
        #expect(
            tint
                == PinnedDestinationManager.ITermTintColor(
                    color: PinnedDestinationManager.ITermColor(red: 0, green: 0, blue: 0), alpha: 1.0))
    }

    @Test func sixDigitHexStillParsesAsFullyOpaque() {
        // Backward compatibility: every hex string stored before opacity existed as a setting
        // (and the registered built-in default before this change) is 6 digits, and must keep
        // parsing exactly as before - as fully opaque - rather than becoming unparseable.
        let tint = PinnedDestinationManager.itermColor(fromHexString: "062312")
        #expect(tint?.alpha == 1.0)
        #expect(
            tint?.color
                == PinnedDestinationManager.ITermColor(
                    red: 6 * 257, green: 0x23 * 257, blue: 0x12 * 257))
    }

    @Test func eightDigitHexParsesColorAndAlpha() {
        // 0x80 / 255 is the mid-opacity case a user actually picks from the color well.
        let tint = PinnedDestinationManager.itermColor(fromHexString: "FF000080")
        #expect(
            tint?.color == PinnedDestinationManager.ITermColor(red: 65535, green: 0, blue: 0))
        #expect(tint.map { abs($0.alpha - (128.0 / 255.0)) < 0.0001 } == true)
    }

    @Test func rejectsMalformedInput() {
        // Every one of these must fail rather than guess: an unparseable stored preference is
        // exactly the case `pinnedTintColor()` handles by falling back to the built-in default,
        // never by applying a garbage color derived from whatever partial parse happened.
        #expect(PinnedDestinationManager.itermColor(fromHexString: "") == nil)
        #expect(PinnedDestinationManager.itermColor(fromHexString: "GGGGGG") == nil)
        #expect(PinnedDestinationManager.itermColor(fromHexString: "FFF") == nil)
        #expect(PinnedDestinationManager.itermColor(fromHexString: "FFFFFFF") == nil)
        #expect(PinnedDestinationManager.itermColor(fromHexString: "FFFFFFFFF") == nil)
    }

    @Test func roundTripsThroughHex() {
        // Components chosen as exact multiples of 257 (10 * 257, 200 * 257, 255 * 257) so the
        // ITermColor -> hex -> ITermColor round trip lands back on the exact original value,
        // not merely an equivalent-looking one - any off-by-one in the scale/round pairing would
        // show up here as a component that's off by exactly 257.
        let original = PinnedDestinationManager.ITermColor(red: 2570, green: 51400, blue: 65535)
        let hex = PinnedDestinationManager.hexString(fromITermColor: original, alpha: 0.5)
        let tint = PinnedDestinationManager.itermColor(fromHexString: hex)
        #expect(tint?.color == original)
        #expect(tint.map { abs($0.alpha - 0.5) < 0.01 } == true)
    }
}

// MARK: - Pinned Destination: alpha-blending the tint over the pane's original background

struct PinnedDestinationITermTintBlendTests {
    private static let tint = PinnedDestinationManager.ITermColor(red: 65535, green: 0, blue: 0)
    private static let background = PinnedDestinationManager.ITermColor(red: 0, green: 0, blue: 65535)

    @Test func alphaOneReturnsTintUnchanged() {
        let blended = PinnedDestinationManager.blended(tint: Self.tint, alpha: 1.0, over: Self.background)
        #expect(blended == Self.tint)
    }

    @Test func alphaZeroReturnsBackgroundUnchanged() {
        let blended = PinnedDestinationManager.blended(tint: Self.tint, alpha: 0.0, over: Self.background)
        #expect(blended == Self.background)
    }

    @Test func alphaHalfOverBlackGivesHalfTheTintsComponents() {
        let black = PinnedDestinationManager.ITermColor(red: 0, green: 0, blue: 0)
        let tint = PinnedDestinationManager.ITermColor(red: 65535, green: 30000, blue: 1000)
        let blended = PinnedDestinationManager.blended(tint: tint, alpha: 0.5, over: black)
        // 65535 * 0.5 = 32767.5 -> rounds to 32768; 30000 * 0.5 = 15000; 1000 * 0.5 = 500.
        #expect(blended == PinnedDestinationManager.ITermColor(red: 32768, green: 15000, blue: 500))
    }

    @Test func alphaIsClampedToValidRange() {
        let tooLow = PinnedDestinationManager.blended(tint: Self.tint, alpha: -1, over: Self.background)
        #expect(tooLow == Self.background)

        let tooHigh = PinnedDestinationManager.blended(tint: Self.tint, alpha: 2, over: Self.background)
        #expect(tooHigh == Self.tint)
    }
}

// MARK: - Pinned Destination: menu bar icon foreground legibility

struct PinnedDestinationMenuBarIconForegroundTests {
    @Test func builtInDarkGreenChoosesLightForeground() {
        // The built-in default backdrop (see `PinnedDestinationManager.defaultPinnedBackgroundColor`)
        // is a deliberately DARK green, chosen so light text/icon stays legible on it - this
        // is the case the icon was hard-coded white for before it followed the user's tint.
        let foreground = PinnedDestinationManager.menuBarIconForeground(
            onBackdrop: PinnedDestinationManager.defaultPinnedBackgroundColor)
        #expect(foreground == .light)
    }

    @Test func pureBlackChoosesLightForeground() {
        let foreground = PinnedDestinationManager.menuBarIconForeground(
            onBackdrop: PinnedDestinationManager.ITermColor(red: 0, green: 0, blue: 0))
        #expect(foreground == .light)
    }

    @Test func pureWhiteChoosesDarkForeground() {
        let foreground = PinnedDestinationManager.menuBarIconForeground(
            onBackdrop: PinnedDestinationManager.ITermColor(red: 65535, green: 65535, blue: 65535))
        #expect(foreground == .dark)
    }

    @Test func paleYellowChoosesDarkForeground() {
        // A bright, low-saturation backdrop a user might plausibly pick from the color well -
        // covers the case the old hard-coded-white icon would have gotten wrong (invisible on
        // a pale tint), which is the entire reason the foreground now has to be decided rather
        // than assumed.
        let paleYellow = PinnedDestinationManager.ITermColor(red: 65535, green: 65535, blue: 51400)
        let foreground = PinnedDestinationManager.menuBarIconForeground(onBackdrop: paleYellow)
        #expect(foreground == .dark)
    }

    @Test func midGreyLandsOnTheDarkSideOfTheThreshold() {
        // 32768 is just over half of the 0...65535 range (65535 / 2 = 32767.5), so this grey's
        // luma comes out to ~0.500008 - a hair above the 0.5 threshold. Asserting the actual
        // computed side (`.dark`) rather than assuming which way a "mid" grey should fall,
        // per `menuBarIconForeground`'s own `>` (not `>=`) threshold.
        let midGrey = PinnedDestinationManager.ITermColor(red: 32768, green: 32768, blue: 32768)
        let foreground = PinnedDestinationManager.menuBarIconForeground(onBackdrop: midGrey)
        #expect(foreground == .dark)
    }
}

// MARK: - Pinned Destination: iTerm2 write result classification

struct PinnedDestinationITermWriteResultTests {
    @Test func successOkClassifiesAsOk() {
        #expect(PinnedDestinationManager.classifyITermWriteOutcome(.success("ok")) == .ok)
    }

    @Test func successGoneClassifiesAsGone() {
        #expect(PinnedDestinationManager.classifyITermWriteOutcome(.success("gone")) == .gone)
    }

    @Test func successErrorClassifiesAsGone() {
        // The script's own `try`/`on error` handler returning "error" and the
        // enumeration falling through without a match ("gone") are both treated the
        // same way a single-write delivery already treated them.
        #expect(PinnedDestinationManager.classifyITermWriteOutcome(.success("error")) == .gone)
    }

    @Test func permissionDeniedClassifiesAsPermissionDenied() {
        #expect(PinnedDestinationManager.classifyITermWriteOutcome(.permissionDenied) == .permissionDenied)
    }

    @Test func failedClassifiesAsFailed() {
        #expect(PinnedDestinationManager.classifyITermWriteOutcome(.failed) == .failed)
    }
}

// MARK: - Pinned Destination: iTerm2 delivery outcome reduction

struct PinnedDestinationITermDeliveryOutcomeTests {
    @Test func textOnlySuccessIsDelivered() {
        let outcome = PinnedDestinationManager.decideITermDeliveryOutcome(stepResults: [(.text, .ok)])
        #expect(outcome == .delivered)
    }

    @Test func textFailingAbortsWithThatFailuresKind() {
        #expect(
            PinnedDestinationManager.decideITermDeliveryOutcome(stepResults: [(.text, .gone)]) == .gone)
        #expect(
            PinnedDestinationManager.decideITermDeliveryOutcome(stepResults: [(.text, .permissionDenied)])
                == .permissionDenied)
        #expect(
            PinnedDestinationManager.decideITermDeliveryOutcome(stepResults: [(.text, .failed)]) == .failed)
    }

    @Test func insertPrefixFailingAbortsBeforeTextIsEvenAttempted() {
        let outcome = PinnedDestinationManager.decideITermDeliveryOutcome(
            stepResults: [(.insertModePrefix, .gone)])
        #expect(outcome == .gone)
    }

    @Test func textThenSuccessfulSubmitIsDelivered() {
        let outcome = PinnedDestinationManager.decideITermDeliveryOutcome(
            stepResults: [(.text, .ok), (.submit, .ok)])
        #expect(outcome == .delivered)
    }

    @Test func textSucceedingButSubmitFailingIsDeliveredWithoutSubmissionNotAFailure() {
        // The core correctness property of splitting the CR into its own step: once the
        // transcript itself has landed, a later submit failure (the session vanishing
        // between the two separate writes, in particular) must not be reported as
        // "nothing was delivered".
        for submitResult: PinnedDestinationManager.ITermWriteResult in [.gone, .permissionDenied, .failed] {
            let outcome = PinnedDestinationManager.decideITermDeliveryOutcome(
                stepResults: [(.text, .ok), (.submit, submitResult)])
            #expect(outcome == .deliveredWithoutSubmission)
        }
    }

    @Test func fullSequenceWithInsertPrefixAndSubmitAllSucceedingIsDelivered() {
        let outcome = PinnedDestinationManager.decideITermDeliveryOutcome(
            stepResults: [(.insertModePrefix, .ok), (.text, .ok), (.submit, .ok)])
        #expect(outcome == .delivered)
    }
}

// MARK: - Pinned Destination: AX submission decision

struct PinnedDestinationAXSubmissionDecisionTests {
    @Test func confirmActionSuccessWinsRegardlessOfKeyEventState() {
        // If the element's own accessibility action worked, that is authoritative and
        // final - the caller never even attempts the key-event fallback in that case
        // (see `submitAXElement`), but the decision table must still be correct if it
        // were asked to consider both.
        #expect(
            PinnedDestinationManager.decideAXSubmission(confirmActionSucceeded: true, keyEventPostSucceeded: true)
                == .submittedViaConfirmAction)
        #expect(
            PinnedDestinationManager.decideAXSubmission(confirmActionSucceeded: true, keyEventPostSucceeded: false)
                == .submittedViaConfirmAction)
    }

    @Test func keyEventIsTheFallbackWhenConfirmActionDidNotSucceed() {
        // Covers both "not advertised" and "advertised but performing it failed" -
        // both collapse to `confirmActionSucceeded: false` by the time this is called.
        let decision = PinnedDestinationManager.decideAXSubmission(
            confirmActionSucceeded: false, keyEventPostSucceeded: true)
        #expect(decision == .submittedViaKeyEvent)
    }

    @Test func neitherMechanismWorkingReportsNotSubmittedRatherThanFailing() {
        // This must not be conflated with a write failure: the text itself was already
        // delivered by the time submission is attempted, so "not submitted" is its own
        // honest outcome, not a total failure - see `reportDeliveredWithoutSubmission`.
        let decision = PinnedDestinationManager.decideAXSubmission(
            confirmActionSucceeded: false, keyEventPostSucceeded: false)
        #expect(decision == .notSubmitted)
    }
}

// MARK: - Settings backup: pinned-destination fields and backward compatibility

struct SettingsBackupPinnedDestinationFieldsTests {
    @Test func generalBackupOmittingTheSixNewFieldsDecodesWithNilRatherThanThrowing() throws {
        // The exact shape of a `GeneralBackup` payload written before pinned-destination
        // settings, `AutoEnterAfterTranscription`, and `AppendTrailingSpace` were added to
        // the export - none of the six new keys are present, not even as `null`. Every
        // added property is Optional precisely so this throws nothing: a `keyNotFound`
        // here would reject the user's whole settings backup, not just the new fields.
        let oldFormatJSON = """
            {
                "isMiddleClickToggleEnabled": false,
                "middleClickActivationDelay": 200,
                "launchAtLoginEnabled": false,
                "isMenuBarOnly": false,
                "recorderType": "mini",
                "appAppearancePreference": "system",
                "appLanguagePreference": "system",
                "isTranscriptionCleanupEnabled": false,
                "transcriptionRetentionMinutes": 1440,
                "isAudioCleanupEnabled": false,
                "audioRetentionPeriod": 7,
                "isSystemMuteEnabled": true,
                "isPauseMediaEnabled": false,
                "audioResumptionDelay": 0,
                "isTextFormattingEnabled": true,
                "isExperimentalFeaturesEnabled": false,
                "restoreClipboardAfterPaste": true,
                "clipboardRestoreDelay": 2
            }
            """
        let data = try #require(oldFormatJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode(GeneralBackup.self, from: data)

        #expect(decoded.autoEnterAfterTranscription == nil)
        #expect(decoded.appendTrailingSpace == nil)
        #expect(decoded.pinDestinationShortcut == nil)
        #expect(decoded.pinnedDestinationEnterRules == nil)
        #expect(decoded.highlightPinnedITermSession == nil)
        #expect(decoded.pinnedITermTintColorHex == nil)
        #expect(decoded.meetingCaptureShortcut == nil)
        #expect(decoded.meetingChunkShortcut == nil)
        #expect(decoded.meetingCaptureShortcuts == nil)
        #expect(decoded.meetingChunkShortcuts == nil)
        #expect(decoded.sendMeetingChunksAutomatically == nil)
    }

    @Test func newFieldsRoundTripThroughEncodeDecode() throws {
        let rules = [
            PinnedDestinationEnterRule(
                bundleIdentifier: "com.googlecode.iterm2", appName: "iTerm2", appendReturn: true,
                sendInsertPrefix: true, appendSpace: false)
        ]
        let general = GeneralBackup(
            primaryRecordingShortcut: nil, secondaryRecordingShortcut: nil, pasteLastTranscriptionShortcut: nil,
            pasteLastEnhancementShortcut: nil, retryLastTranscriptionShortcut: nil, cancelRecorderShortcut: nil,
            openHistoryWindowShortcut: nil, quickAddToDictionaryShortcut: nil,
            primaryRecordingShortcutRawValue: nil, secondaryRecordingShortcutRawValue: nil,
            primaryRecordingShortcutModeRawValue: nil, secondaryRecordingShortcutModeRawValue: nil,
            isMiddleClickToggleEnabled: nil, middleClickActivationDelay: nil, launchAtLoginEnabled: nil,
            isMenuBarOnly: nil, recorderType: nil, appAppearancePreference: nil, appLanguagePreference: nil,
            isTranscriptionCleanupEnabled: nil, transcriptionRetentionMinutes: nil, isAudioCleanupEnabled: nil,
            audioRetentionPeriod: nil, isSystemMuteEnabled: nil, isPauseMediaEnabled: nil,
            audioResumptionDelay: nil, isTextFormattingEnabled: nil, autoEnterAfterTranscription: true,
            appendTrailingSpace: false, isExperimentalFeaturesEnabled: nil, restoreClipboardAfterPaste: nil,
            clipboardRestoreDelay: nil, pinDestinationShortcut: nil, pinnedDestinationEnterRules: rules,
            highlightPinnedITermSession: true, pinnedITermTintColorHex: "112233FF",
            meetingCaptureShortcut: nil, meetingChunkShortcut: nil,
            meetingCaptureShortcuts: nil, meetingChunkShortcuts: nil, sendMeetingChunksAutomatically: nil
        )

        let data = try JSONEncoder().encode(general)
        let decoded = try JSONDecoder().decode(GeneralBackup.self, from: data)

        #expect(decoded.autoEnterAfterTranscription == true)
        #expect(decoded.appendTrailingSpace == false)
        #expect(decoded.highlightPinnedITermSession == true)
        #expect(decoded.pinnedITermTintColorHex == "112233FF")
        #expect(decoded.pinnedDestinationEnterRules == rules)
    }
}

// MARK: - Meeting Capture: automatic chunk send trigger (pure policy)

struct MeetingAutoSendPolicyTests {
    @Test func doesNotSendBeforeTheMinimumSpeechAccumulatesAndTheShortPauseHasNotHappenedEither() {
        #expect(
            MeetingAutoSendPolicy.shouldSend(
                speechSecondsSinceLastChunk: 3, currentSilenceDuration: 2, secondsSinceLastChunk: 5) == false)
    }

    @Test func doesNotSendOnEnoughSpeechWithoutATrailingPauseYet() {
        #expect(
            MeetingAutoSendPolicy.shouldSend(
                speechSecondsSinceLastChunk: 25, currentSilenceDuration: 0.5, secondsSinceLastChunk: 26) == false)
    }

    @Test func sendsOnceEnoughSpeechIsFollowedByTheRequiredPause() {
        #expect(
            MeetingAutoSendPolicy.shouldSend(
                speechSecondsSinceLastChunk: 25, currentSilenceDuration: 1.0, secondsSinceLastChunk: 27) == true)
    }

    @Test func forcesASendAtTheMaximumWaitEvenWithoutAPause() {
        #expect(
            MeetingAutoSendPolicy.shouldSend(
                speechSecondsSinceLastChunk: 45, currentSilenceDuration: 0, secondsSinceLastChunk: 60) == true)
    }

    @Test func doesNotSendJustBelowEitherThreshold() {
        #expect(
            MeetingAutoSendPolicy.shouldSend(
                speechSecondsSinceLastChunk: 4.9, currentSilenceDuration: 2, secondsSinceLastChunk: 5) == false)
        #expect(
            MeetingAutoSendPolicy.shouldSend(
                speechSecondsSinceLastChunk: 25, currentSilenceDuration: 0.99, secondsSinceLastChunk: 59.9) == false)
    }

    // A single short sentence (~3 s) followed by a long pause used to never send until the 60 s
    // cap - see `shortUtteranceTrailingSilenceSeconds`.
    @Test func sendsAShortUtteranceOnceTheLongerPauseThresholdIsReached() {
        #expect(
            MeetingAutoSendPolicy.shouldSend(
                speechSecondsSinceLastChunk: 3, currentSilenceDuration: 3, secondsSinceLastChunk: 6) == true)
        #expect(
            MeetingAutoSendPolicy.shouldSend(
                speechSecondsSinceLastChunk: 3, currentSilenceDuration: 1.5, secondsSinceLastChunk: 4.5) == false)
    }
}

struct MeetingAutoSendTrackerTests {
    @Test func recordTickAccumulatesElapsedAndSpeechSeparately() {
        var tracker = MeetingAutoSendTracker()
        tracker.recordTick(duration: 2, speechSeconds: 2, silenceDuration: 0)
        tracker.recordTick(duration: 1, speechSeconds: 0, silenceDuration: 1)

        #expect(tracker.secondsSinceLastChunk == 3)
        #expect(tracker.speechSecondsSinceLastChunk == 2)
        #expect(tracker.currentSilenceDuration == 1)
    }

    @Test func currentSilenceDurationIsSetToTheCallersMeasurementNotAccumulatedFromDurations() {
        // The caller (MeetingAutoSendEvaluator.step) recomputes silence duration from VAD frame
        // state each tick rather than summing tick durations, so the tracker must just store
        // whatever value it's given, not add to a running total of its own - this is what lets
        // silence be measured at frame resolution instead of whole 1 s ticks.
        var tracker = MeetingAutoSendTracker()
        tracker.recordTick(duration: 1, speechSeconds: 0, silenceDuration: 1)
        tracker.recordTick(duration: 1, speechSeconds: 0, silenceDuration: 2.4)

        #expect(tracker.currentSilenceDuration == 2.4)
        #expect(tracker.speechSecondsSinceLastChunk == 0)
        #expect(tracker.secondsSinceLastChunk == 2)
    }

    @Test func resetAfterChunkSentClearsAllThreeCounters() {
        var tracker = MeetingAutoSendTracker()
        tracker.recordTick(duration: 5, speechSeconds: 5, silenceDuration: 0)
        tracker.resetAfterChunkSent()

        #expect(tracker.speechSecondsSinceLastChunk == 0)
        #expect(tracker.currentSilenceDuration == 0)
        #expect(tracker.secondsSinceLastChunk == 0)
    }
}

// MARK: - Meeting Capture: automatic chunk send trigger at VAD frame resolution (bug: a pause was
// only ever seen as ~1 s of silence because it was accounted in whole 1 s drain ticks)

struct MeetingAutoSendEvaluatorFrameResolutionTests {
    private static let sampleRate = MeetingVAD.sampleRate

    private static func silence(seconds: Double) -> [Int16] {
        [Int16](repeating: 0, count: Int(seconds * sampleRate))
    }

    private static func tone(seconds: Double, amplitude: Int16 = 6000, frequency: Double = 400) -> [Int16] {
        let count = Int(seconds * sampleRate)
        return (0..<count).map { i in
            let t = Double(i) / sampleRate
            return Int16(clamping: Int((Double(amplitude) * sin(2 * Double.pi * frequency * t)).rounded()))
        }
    }

    /// Feeds `micStream` through `MeetingAutoSendEvaluator.step` in `tickSeconds` ticks - 1 s by
    /// default, matching the granularity used to prove silence is measured at frame resolution
    /// regardless of tick size; 0.5 s matches `MeetingAudioCapture`'s actual drain timer - against
    /// a silent system channel. Returns the elapsed stream time (seconds) at which the first tick
    /// triggered, or nil if none did.
    private static func firstTriggerTime(_ micStream: [Int16], tickSeconds: Double = 1) -> TimeInterval? {
        let tickSamples = Int(tickSeconds * sampleRate)
        var micState = MeetingVAD.State.initial
        var systemState = MeetingVAD.State.initial
        var tracker = MeetingAutoSendTracker()
        var offset = 0
        while offset < micStream.count {
            let end = min(offset + tickSamples, micStream.count)
            let micTick = Array(micStream[offset..<end])
            let systemTick = [Int16](repeating: 0, count: micTick.count)
            let result = MeetingAutoSendEvaluator.step(
                mic: micTick, system: systemTick, sampleRate: sampleRate, autoSendEnabled: true,
                micVADState: micState, systemVADState: systemState, tracker: tracker)
            micState = result.micVADState
            systemState = result.systemVADState
            tracker = result.tracker
            offset = end
            if result.shouldTrigger { return Double(offset) / sampleRate }
        }
        return nil
    }

    @Test func fiveSecondsOfSpeechFollowedByTheRequiredPauseTriggers() {
        // 5 s of speech - right at the floor - followed by a pause past the 1.0 s requirement
        // must trigger, and well before the 60 s cap.
        let stream = Self.tone(seconds: 5) + Self.silence(seconds: 2.5)

        guard let time = Self.firstTriggerTime(stream) else {
            Issue.record("expected a trigger during the pause, got none")
            return
        }
        #expect(time > 5, "must not fire before 5 s of speech has accumulated")
        #expect(time < 10, "must fire during the pause, not wait for the 60 s cap (fired at \(time)s)")
    }

    @Test func belowTheMinimumSpeechTriggersEarlyViaTheShortPauseRuleRatherThanWaitingForTheCap() {
        // 3 s of speech - below the 5 s floor for the old rule - followed by a long pause: the
        // short-pause rule (see `MeetingAutoSendPolicy.shortUtteranceTrailingSilenceSeconds`) now
        // fires once silence reaches 3 s, well before the 60 s cap.
        let stream = Self.tone(seconds: 3) + Self.silence(seconds: 65)

        guard let time = Self.firstTriggerTime(stream) else {
            Issue.record("expected a trigger during the pause, got none")
            return
        }
        #expect(time >= 6, "must not fire before 3 s speech + 3 s trailing silence")
        #expect(time < 60, "must fire via the short-pause rule, not wait for the 60 s cap (fired at \(time)s)")
    }

    @Test func eightHundredMsGapsBetweenBurstsNeverTriggerAtHalfSecondTicks() {
        // 25 cycles of 1 s speech + 0.8 s silence, ticked at the real 0.5 s drain interval: 25 s
        // of speech accumulates (past the 5 s floor) but no single intra-sentence gap ever
        // reaches the 1.0 s trailing-silence requirement, and the whole stream stays under the
        // 60 s cap - so this must never trigger.
        var stream: [Int16] = []
        for _ in 0..<25 {
            stream += Self.tone(seconds: 1) + Self.silence(seconds: 0.8)
        }
        #expect(stream.count < Int(60 * Self.sampleRate))

        #expect(Self.firstTriggerTime(stream, tickSeconds: 0.5) == nil)
    }

    @Test func triggerLandsOneToOnePointFiveSecondsAfterSpeechEndAtHalfSecondTicks() {
        // 5 s of speech (past the 5 s floor) followed by a long pause, ticked at the real 0.5 s
        // drain interval: the 1.0 s trailing-silence requirement must fire on the first tick
        // whose accumulated silence reaches it - between 1.0 s (the requirement itself) and
        // 1.5 s (one 0.5 s tick of slack) after speech ends, never later and never via the 60 s cap.
        let stream = Self.tone(seconds: 5) + Self.silence(seconds: 3)

        guard let time = Self.firstTriggerTime(stream, tickSeconds: 0.5) else {
            Issue.record("expected a trigger during the pause, got none")
            return
        }
        #expect(time >= 6.0, "must not fire before 1.0 s of trailing silence (5 s speech + 1.0 s)")
        #expect(time <= 6.5, "must fire within one 0.5 s tick of the 1.0 s requirement (fired at \(time)s)")
    }
}

// MARK: - Shortcuts: multiple bindings per action, storage round trip and backward compatibility

struct ShortcutStoreMultipleBindingsTests {
    // A fresh UUID-parameterized `.mode` action per test is scratch storage that no real code
    // path (or `ShortcutValidator`'s conflict scan, which only walks known actions) ever looks
    // at, so tests need no shared fixture - just their own cleanup.
    private func scratchAction() -> ShortcutAction { .mode(UUID()) }

    @Test func aFreshActionHasNoBindings() {
        let action = scratchAction()
        defer { ShortcutStore.removeShortcutStorage(for: action) }

        #expect(ShortcutStore.shortcuts(for: action).isEmpty)
    }

    @Test func setShortcutsStoresAllBindingsAndEachIndexReadsBack() {
        let action = scratchAction()
        defer { ShortcutStore.removeShortcutStorage(for: action) }

        let first = Shortcut.key(keyCode: 210, modifierFlags: [.control, .shift])
        let second = Shortcut.key(keyCode: 211, modifierFlags: [.control, .shift])
        ShortcutStore.setShortcuts([first, second], for: action)

        #expect(ShortcutStore.shortcuts(for: action) == [first, second])
        #expect(ShortcutStore.shortcut(for: action, at: 0) == first)
        #expect(ShortcutStore.shortcut(for: action, at: 1) == second)
        #expect(ShortcutStore.shortcut(for: action, at: 2) == nil)
    }

    @Test func setShortcutAtAnIndexOnePastTheEndAppendsRatherThanBeingDropped() {
        let action = scratchAction()
        defer { ShortcutStore.removeShortcutStorage(for: action) }

        let first = Shortcut.key(keyCode: 210, modifierFlags: [.control, .shift])
        ShortcutStore.setShortcut(first, for: action, at: 0)
        let second = Shortcut.key(keyCode: 211, modifierFlags: [.control, .shift])
        ShortcutStore.setShortcut(second, for: action, at: 1)

        #expect(ShortcutStore.shortcuts(for: action) == [first, second])
    }

    @Test func removeShortcutDropsOnlyThatIndexAndShiftsTheRestDown() {
        let action = scratchAction()
        defer { ShortcutStore.removeShortcutStorage(for: action) }

        let first = Shortcut.key(keyCode: 210, modifierFlags: [.control, .shift])
        let second = Shortcut.key(keyCode: 211, modifierFlags: [.control, .shift])
        let third = Shortcut.key(keyCode: 212, modifierFlags: [.control, .shift])
        ShortcutStore.setShortcuts([first, second, third], for: action)

        ShortcutStore.removeShortcut(at: 1, for: action)

        #expect(ShortcutStore.shortcuts(for: action) == [first, third])
    }

    @Test func oldSingleShortcutStorageFormatReadsBackAsAOneElementList() throws {
        // Storage written before an action could have more than one binding is a single
        // `Shortcut` JSON object, not an array - reading it must not lose that binding.
        let action = scratchAction()
        defer { ShortcutStore.removeShortcutStorage(for: action) }

        let legacy = Shortcut.key(keyCode: 213, modifierFlags: [.control, .shift])
        let data = try JSONEncoder().encode(legacy)
        UserDefaults.standard.set(data, forKey: action.userDefaultsKey)

        #expect(ShortcutStore.shortcuts(for: action) == [legacy])
    }

    @Test func settingAnEmptyListClearsStorageSoTheActionReadsAsFullyUnbound() {
        let action = scratchAction()
        defer { ShortcutStore.removeShortcutStorage(for: action) }

        ShortcutStore.setShortcut(Shortcut.key(keyCode: 210, modifierFlags: [.control, .shift]), for: action)
        ShortcutStore.setShortcuts([], for: action)

        #expect(ShortcutStore.shortcuts(for: action).isEmpty)
        #expect(ShortcutStore.isShortcutCleared(for: action))
    }
}

// MARK: - Shortcuts: ShortcutRecorderModel cancel-notification contract

struct ShortcutRecorderModelCancelNotificationTests {
    // `.mode(UUID())` is scratch storage - see `ShortcutStoreMultipleBindingsTests.scratchAction()`.
    // `ShortcutRecorderModel` never touches the store here (no key event is ever fed to it), so
    // cleanup is defensive only.
    private func scratchAction() -> ShortcutAction { .mode(UUID()) }

    @Test func cancellingAnActiveRecordingInvokesOnCancelOnceAndNeverOnCapture() {
        let action = scratchAction()
        defer { ShortcutStore.removeShortcutStorage(for: action) }
        let model = ShortcutRecorderModel()
        var cancelCount = 0
        var captureCount = 0

        model.start(
            action: action, index: 0,
            onCapture: { _ in captureCount += 1 },
            onCancel: { cancelCount += 1 }
        )
        model.cancel()

        #expect(cancelCount == 1)
        #expect(captureCount == 0)
    }

    @Test func cancellingAnIdleModelDoesNotInvokeOnCancel() {
        let model = ShortcutRecorderModel()

        // Never started - nothing to cancel out of.
        model.cancel()

        #expect(!model.isRecording)
    }

    @Test func startingASecondRecordingCancelsTheFirstOnesOnCancelNotTheSeconds() {
        let firstAction = scratchAction()
        let secondAction = scratchAction()
        defer {
            ShortcutStore.removeShortcutStorage(for: firstAction)
            ShortcutStore.removeShortcutStorage(for: secondAction)
        }
        let model = ShortcutRecorderModel()
        var firstCancelCount = 0
        var secondCancelCount = 0

        model.start(action: firstAction, index: 0, onCapture: { _ in }, onCancel: { firstCancelCount += 1 })
        model.start(action: secondAction, index: 0, onCapture: { _ in }, onCancel: { secondCancelCount += 1 })

        #expect(firstCancelCount == 1)
        #expect(secondCancelCount == 0)
    }
}

// MARK: - Shortcuts: any-of-several-bindings resolution (pure part of ShortcutMonitor)

struct ShortcutMonitorTransitionResolutionTests {
    @Test func aKeyBindingTransitionsToKeyDownOnAMatchingPressWhenNotAlreadyDown() {
        let shortcut = Shortcut.key(keyCode: 10, modifierFlags: [.command])
        let transition = ShortcutMonitor.transitionForKeyShortcut(
            shortcut, isDown: false, kind: .keyDown, keyCode: 10, modifierFlags: [.command])
        #expect(transition == .keyDown)
    }

    @Test func aKeyBindingTransitionsToKeyUpOnAMatchingRelease() {
        let shortcut = Shortcut.key(keyCode: 10, modifierFlags: [.command])
        let transition = ShortcutMonitor.transitionForKeyShortcut(
            shortcut, isDown: true, kind: .keyUp, keyCode: 10, modifierFlags: [.command])
        #expect(transition == .keyUp)
    }

    @Test func aNonMatchingKeyEventIsIgnored() {
        let shortcut = Shortcut.key(keyCode: 10, modifierFlags: [.command])
        let transition = ShortcutMonitor.transitionForKeyShortcut(
            shortcut, isDown: false, kind: .keyDown, keyCode: 11, modifierFlags: [.command])
        #expect(transition == .none)
    }

    @Test func anyOneOfSeveralBindingsMatchingIsEnoughToTriggerTheAction() {
        // Mirrors the monitor's per-binding loop: an action bound to both a keyboard combo and
        // a modifier-only (mouse-friendly) combo only needs ONE of them to match an incoming
        // event for the action to fire.
        let keyboardBinding = Shortcut.key(keyCode: 10, modifierFlags: [.command])
        let modifierBinding = Shortcut.modifierOnly(keyCode: nil, modifierFlags: [.control, .option])

        // The incoming event only matches the modifier-only binding.
        let keyboardTransition = ShortcutMonitor.transitionForKeyShortcut(
            keyboardBinding, isDown: false, kind: .flagsChanged, keyCode: 0, modifierFlags: [.control, .option])
        let modifierTransition = ShortcutMonitor.transitionForModifierOnlyShortcut(
            modifierBinding, isDown: false, kind: .flagsChanged, keyCode: 0, modifierFlags: [.control, .option])

        #expect(keyboardTransition == .none)
        #expect(modifierTransition == .keyDown)
        #expect([keyboardTransition, modifierTransition].contains(.keyDown))
    }

    @Test func modifierOnlyBindingReleasesWhenAHeldModifierIsDropped() {
        let binding = Shortcut.modifierOnly(keyCode: nil, modifierFlags: [.control, .option])
        let transition = ShortcutMonitor.transitionForModifierOnlyShortcut(
            binding, isDown: true, kind: .flagsChanged, keyCode: 0, modifierFlags: [.control])
        #expect(transition == .keyUp)
    }
}

// MARK: - Settings backup: meeting-capture shortcuts (multiple bindings) and old-format fallback

struct SettingsBackupMeetingShortcutFieldsTests {
    private static func generalBackup(
        meetingCaptureShortcut: ShortcutBackup? = nil,
        meetingCaptureShortcuts: [ShortcutBackup]? = nil,
        sendMeetingChunksAutomatically: Bool? = nil
    ) -> GeneralBackup {
        GeneralBackup(
            primaryRecordingShortcut: nil, secondaryRecordingShortcut: nil, pasteLastTranscriptionShortcut: nil,
            pasteLastEnhancementShortcut: nil, retryLastTranscriptionShortcut: nil, cancelRecorderShortcut: nil,
            openHistoryWindowShortcut: nil, quickAddToDictionaryShortcut: nil,
            primaryRecordingShortcutRawValue: nil, secondaryRecordingShortcutRawValue: nil,
            primaryRecordingShortcutModeRawValue: nil, secondaryRecordingShortcutModeRawValue: nil,
            isMiddleClickToggleEnabled: nil, middleClickActivationDelay: nil, launchAtLoginEnabled: nil,
            isMenuBarOnly: nil, recorderType: nil, appAppearancePreference: nil, appLanguagePreference: nil,
            isTranscriptionCleanupEnabled: nil, transcriptionRetentionMinutes: nil, isAudioCleanupEnabled: nil,
            audioRetentionPeriod: nil, isSystemMuteEnabled: nil, isPauseMediaEnabled: nil,
            audioResumptionDelay: nil, isTextFormattingEnabled: nil, autoEnterAfterTranscription: nil,
            appendTrailingSpace: nil, isExperimentalFeaturesEnabled: nil, restoreClipboardAfterPaste: nil,
            clipboardRestoreDelay: nil, pinDestinationShortcut: nil, pinnedDestinationEnterRules: nil,
            highlightPinnedITermSession: nil, pinnedITermTintColorHex: nil,
            meetingCaptureShortcut: meetingCaptureShortcut, meetingChunkShortcut: nil,
            meetingCaptureShortcuts: meetingCaptureShortcuts, meetingChunkShortcuts: nil,
            sendMeetingChunksAutomatically: sendMeetingChunksAutomatically
        )
    }

    @Test func multipleBindingsAndTheAutoSendToggleRoundTripThroughEncodeDecode() throws {
        let first = Shortcut.key(keyCode: 210, modifierFlags: [.control, .shift])
        let second = Shortcut.modifierOnly(keyCode: nil, modifierFlags: [.control, .option])
        let general = Self.generalBackup(
            meetingCaptureShortcut: ShortcutBackup(first),
            meetingCaptureShortcuts: [ShortcutBackup(first), ShortcutBackup(second)],
            sendMeetingChunksAutomatically: true
        )

        let data = try JSONEncoder().encode(general)
        let decoded = try JSONDecoder().decode(GeneralBackup.self, from: data)

        #expect(decoded.meetingCaptureShortcuts?.map(\.shortcut) == [first, second])
        #expect(decoded.sendMeetingChunksAutomatically == true)
    }

    @Test func oldFormatBackupMissingThePluralFieldStillCarriesTheSingleBinding() throws {
        // A backup written before an action could have more than one shortcut has only the
        // singular field - the plural one is absent entirely, not `null`. `BackupImporter`
        // falls back to the singular field in that case, so it must still decode.
        let legacy = Shortcut.key(keyCode: 214, modifierFlags: [.control, .shift])
        let shortcutJSON = try #require(String(data: JSONEncoder().encode(legacy), encoding: .utf8))
        let oldFormatJSON = "{ \"meetingCaptureShortcut\": \(shortcutJSON) }"

        let data = try #require(oldFormatJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode(GeneralBackup.self, from: data)

        #expect(decoded.meetingCaptureShortcuts == nil)
        #expect(decoded.meetingCaptureShortcut?.shortcut == legacy)
    }
}
