import Testing
import Foundation
@testable import VoiceInk

// MARK: - Meeting Capture: typing guard for chunk delivery (pure decision table)

struct MeetingChunkDeliveryGuardTests {
    private static let referenceTime = Date(timeIntervalSince1970: 1_000_000)

    @Test func typingInPinnedITermFrontmostHolds() {
        #expect(
            MeetingChunkDeliveryGuard.shouldHold(
                secondsSinceLastKeyDown: 1,
                now: Self.referenceTime,
                frontmostBundleID: PinnedTarget.iTermBundleIdentifier,
                targetKind: .iTermSession,
                lastHotkeyPressTime: nil
            ) == true)
    }

    @Test func typingInAnotherAppWithAnITermTargetDelivers() {
        // The iTerm2 session is addressed by id via AppleScript, not by focus - typing in some
        // other frontmost app cannot interleave with it.
        #expect(
            MeetingChunkDeliveryGuard.shouldHold(
                secondsSinceLastKeyDown: 1,
                now: Self.referenceTime,
                frontmostBundleID: "com.apple.Terminal",
                targetKind: .iTermSession,
                lastHotkeyPressTime: nil
            ) == false)
    }

    @Test func typingAnywhereWithAKeyboardDrivenTargetHolds() {
        // AX value write, AX keystroke injection, and the unpinned cursor-paste fallback all go
        // through the keyboard/focus, so frontmost app doesn't matter - only recency does.
        #expect(
            MeetingChunkDeliveryGuard.shouldHold(
                secondsSinceLastKeyDown: 1,
                now: Self.referenceTime,
                frontmostBundleID: "com.some.other.app",
                targetKind: .keyboardDriven,
                lastHotkeyPressTime: nil
            ) == true)
    }

    @Test func idleForThreeSecondsDelivers() {
        #expect(
            MeetingChunkDeliveryGuard.shouldHold(
                secondsSinceLastKeyDown: 3,
                now: Self.referenceTime,
                frontmostBundleID: PinnedTarget.iTermBundleIdentifier,
                targetKind: .iTermSession,
                lastHotkeyPressTime: nil
            ) == false)
        #expect(
            MeetingChunkDeliveryGuard.shouldHold(
                secondsSinceLastKeyDown: 10,
                now: Self.referenceTime,
                frontmostBundleID: "anything",
                targetKind: .keyboardDriven,
                lastHotkeyPressTime: nil
            ) == false)
    }

    @Test func justBelowTheIdleThresholdStillHolds() {
        #expect(
            MeetingChunkDeliveryGuard.shouldHold(
                secondsSinceLastKeyDown: 2.99,
                now: Self.referenceTime,
                frontmostBundleID: "anything",
                targetKind: .keyboardDriven,
                lastHotkeyPressTime: nil
            ) == true)
    }

    @Test func hotkeyKeyDownAloneIsNotTyping() {
        // The chunk hotkey's own physical keyDown, with no other typing since - the last
        // keyDown CGEventSource reports IS the hotkey press, so it must not hold delivery.
        let hotkeyPressTime = Self.referenceTime.addingTimeInterval(-0.5)
        #expect(
            MeetingChunkDeliveryGuard.shouldHold(
                secondsSinceLastKeyDown: 0.5,
                now: Self.referenceTime,
                frontmostBundleID: "anything",
                targetKind: .keyboardDriven,
                lastHotkeyPressTime: hotkeyPressTime
            ) == false)
    }

    @Test func realTypingShortlyAfterTheHotkeyStillHolds() {
        // A keyDown clearly newer than the hotkey press (outside the echo window) is genuine
        // typing, even though a hotkey was pressed recently too.
        let hotkeyPressTime = Self.referenceTime.addingTimeInterval(-2)
        #expect(
            MeetingChunkDeliveryGuard.shouldHold(
                secondsSinceLastKeyDown: 0.1,
                now: Self.referenceTime,
                frontmostBundleID: "anything",
                targetKind: .keyboardDriven,
                lastHotkeyPressTime: hotkeyPressTime
            ) == true)
    }

    @Test func targetKindMapsPinnedDestinationsCorrectly() {
        #expect(MeetingChunkDeliveryGuard.targetKind(for: nil) == .keyboardDriven)
        #expect(
            MeetingChunkDeliveryGuard.targetKind(for: .iTermSession(id: "w0t0p0", appName: "iTerm2", sessionName: nil))
                == .iTermSession)
    }
}

// MARK: - Meeting Capture: pending-chunk merge queue

struct MeetingPendingChunkQueueTests {
    @Test func mergesQueuedTextsInArrivalOrder() {
        var queue = MeetingPendingChunkQueue<Int>()
        queue.append(text: "Me: first", payload: 1)
        queue.append(text: "Others: second", payload: 2)
        queue.append(text: "Me: third", payload: 3)

        let merged = queue.merged
        #expect(merged?.text == "Me: first\n\nOthers: second\n\nMe: third")
    }

    @Test func keepsOnlyTheMostRecentPayloadAndReportsTheRestAsStale() {
        var queue = MeetingPendingChunkQueue<Int>()
        queue.append(text: "a", payload: 1)
        queue.append(text: "b", payload: 2)
        queue.append(text: "c", payload: 3)

        let merged = queue.merged
        #expect(merged?.payload == 3)
        #expect(merged?.stalePayloads == [1, 2])
    }

    @Test func emptyQueueMergesToNil() {
        let queue = MeetingPendingChunkQueue<Int>()
        #expect(queue.merged == nil)
    }

    @Test func removeAllClearsEverythingSoNothingIsDeliveredTwice() {
        var queue = MeetingPendingChunkQueue<Int>()
        queue.append(text: "a", payload: 1)
        queue.removeAll()

        #expect(queue.isEmpty)
        #expect(queue.merged == nil)
    }

    @Test func noChunkIsLostAcrossASequenceOfAppendsAndOneMerge() {
        var queue = MeetingPendingChunkQueue<Int>()
        let texts = (0..<5).map { "chunk \($0)" }
        for (index, text) in texts.enumerated() {
            queue.append(text: text, payload: index)
        }

        let merged = queue.merged
        for text in texts {
            #expect(merged?.text.contains(text) == true)
        }
        #expect(merged?.stalePayloads.count == texts.count - 1)
    }
}
