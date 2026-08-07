//
//  VoiceInkTests.swift
//  VoiceInkTests
//
//  Created by Prakash Joshi on 15/10/2024.
//

import Testing
import Foundation
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
