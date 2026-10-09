import Foundation
import Testing
@testable import SetmioCore

@Suite("RestTimerState")
struct RestTimerStateTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("a fresh timer counts down on the wall clock and finishes at zero")
    func countdown() {
        let timer = RestTimerState(startingAt: t0, seconds: 90)
        #expect(timer.remaining(at: t0) == 90)
        #expect(timer.remaining(at: t0.addingTimeInterval(30)) == 60)
        #expect(!timer.isFinished(at: t0.addingTimeInterval(89)))
        #expect(timer.isFinished(at: t0.addingTimeInterval(90)))
        #expect(timer.remaining(at: t0.addingTimeInterval(500)) == 0)
    }

    @Test("pause freezes the remainder; resume continues from it, however long the pause was")
    func pauseResume() {
        let running = RestTimerState(startingAt: t0, seconds: 120)
        let paused = running.paused(at: t0.addingTimeInterval(45))
        #expect(paused.isPaused)
        #expect(paused.remaining(at: t0.addingTimeInterval(45)) == 75)
        #expect(paused.remaining(at: t0.addingTimeInterval(600)) == 75, "frozen while paused")
        #expect(!paused.isFinished(at: t0.addingTimeInterval(600)))

        let resumedAt = t0.addingTimeInterval(600)
        let resumed = paused.resumed(at: resumedAt)
        #expect(!resumed.isPaused)
        #expect(resumed.remaining(at: resumedAt) == 75)
        #expect(resumed.endDate == resumedAt.addingTimeInterval(75))
    }

    @Test("pause and resume are idempotent; pausing a finished timer is a no-op")
    func idempotent() {
        let running = RestTimerState(startingAt: t0, seconds: 60)
        let paused = running.paused(at: t0.addingTimeInterval(10))
        #expect(paused.paused(at: t0.addingTimeInterval(20)) == paused)
        #expect(running.resumed(at: t0.addingTimeInterval(5)) == running)
        let finishedAt = t0.addingTimeInterval(61)
        #expect(running.paused(at: finishedAt) == running)
    }

    @Test("+30 s extends a running, a paused and a finished timer")
    func extend() {
        let running = RestTimerState(startingAt: t0, seconds: 60)
        let more = running.extended(by: 30, at: t0.addingTimeInterval(10))
        #expect(more.remaining(at: t0.addingTimeInterval(10)) == 80)
        #expect(more.totalSeconds == 90)

        let paused = running.paused(at: t0.addingTimeInterval(20)).extended(by: 30, at: t0.addingTimeInterval(25))
        #expect(paused.isPaused)
        #expect(paused.remaining(at: t0.addingTimeInterval(25)) == 70)

        let late = t0.addingTimeInterval(100)
        #expect(running.extended(by: 30, at: late).remaining(at: late) == 30)
    }

    @Test("both sides applying the same command sequence agree to the second")
    func watchAndPhoneAgree() {
        // The watch started the rest at t0; the phone mirrors it from the same endDate and receives the taps later.
        let watch0 = RestTimerState(startingAt: t0, seconds: 180)
        let phone0 = watch0
        let pauseAt = t0.addingTimeInterval(40), resumeAt = t0.addingTimeInterval(100)
        let watch = watch0.paused(at: pauseAt).resumed(at: resumeAt).extended(by: 30, at: resumeAt.addingTimeInterval(5))
        let phone = phone0.paused(at: pauseAt).resumed(at: resumeAt).extended(by: 30, at: resumeAt.addingTimeInterval(5))
        #expect(watch == phone)
        #expect(watch.remaining(at: resumeAt.addingTimeInterval(5)) == 165)   // 140 left at the pause − 5 s running + 30
    }
}
