import Testing

@testable import VoiceInk

private final class MockKeepAwakeAssertion: MeetingKeepAwakeAssertion {
    var acquireCount = 0
    var releaseCount = 0
    func acquire() { acquireCount += 1 }
    func release() { releaseCount += 1 }
}

struct MeetingKeepAwakeControllerTests {
    @Test func startAcquiresExactlyOnce() {
        let mock = MockKeepAwakeAssertion()
        var controller = MeetingKeepAwakeController(assertion: mock)
        controller.captureStarted()
        #expect(mock.acquireCount == 1)
        #expect(mock.releaseCount == 0)
        #expect(controller.isHeld)
    }

    @Test func stopReleasesAfterStart() {
        let mock = MockKeepAwakeAssertion()
        var controller = MeetingKeepAwakeController(assertion: mock)
        controller.captureStarted()
        controller.captureEndedOrFailed()
        #expect(mock.releaseCount == 1)
        #expect(!controller.isHeld)
    }

    @Test func releaseBeforeAnyStartIsANoOp() {
        let mock = MockKeepAwakeAssertion()
        var controller = MeetingKeepAwakeController(assertion: mock)
        controller.captureEndedOrFailed()
        #expect(mock.releaseCount == 0)
    }

    @Test func releaseIsIdempotentAcrossStopAndALaterFailureCallback() {
        // Mirrors `MeetingAudioCapture`: `stop()` releases, and a mic-failure path that also calls
        // `captureEndedOrFailed()` afterward must not double-release.
        let mock = MockKeepAwakeAssertion()
        var controller = MeetingKeepAwakeController(assertion: mock)
        controller.captureStarted()
        controller.captureEndedOrFailed()
        controller.captureEndedOrFailed()
        #expect(mock.releaseCount == 1)
    }

    @Test func aNewSessionAcquiresAgainAfterAPreviousOneEnded() {
        let mock = MockKeepAwakeAssertion()
        var controller = MeetingKeepAwakeController(assertion: mock)
        controller.captureStarted()
        controller.captureEndedOrFailed()
        controller.captureStarted()
        #expect(mock.acquireCount == 2)
        #expect(controller.isHeld)
    }
}
