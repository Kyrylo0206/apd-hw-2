import XCTest
@testable import TaskProcessor

private enum StudentWorkerError: Error {
    case transient
    case permanent
}

private actor WorkProbe {
    private(set) var startedIDs: [String] = []
    private(set) var finishedIDs: [String] = []
    private(set) var peakActiveCount = 0
    private var activeCount = 0
    private var releasedIDs: Set<String> = []
    private var heldWorkers: [String: CheckedContinuation<Void, Never>] = [:]
    private var startObservers: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var finishObservers: [String: [CheckedContinuation<Void, Never>]] = [:]

    func begin(_ id: String) {
        startedIDs.append(id)
        activeCount += 1
        peakActiveCount = max(peakActiveCount, activeCount)
        for observer in startObservers.removeValue(forKey: id) ?? [] {
            observer.resume()
        }
    }

    func hold(_ id: String) async {
        if releasedIDs.remove(id) != nil {
            return
        }
        await withCheckedContinuation { continuation in
            heldWorkers[id] = continuation
        }
    }

    func end(_ id: String) {
        activeCount -= 1
        finishedIDs.append(id)
        for observer in finishObservers.removeValue(forKey: id) ?? [] {
            observer.resume()
        }
    }

    func release(_ id: String) {
        if let worker = heldWorkers.removeValue(forKey: id) {
            worker.resume()
        } else {
            releasedIDs.insert(id)
        }
    }

    func waitUntilStarted(_ id: String) async {
        if startedIDs.contains(id) {
            return
        }
        await withCheckedContinuation { continuation in
            startObservers[id, default: []].append(continuation)
        }
    }

    func waitUntilFinished(_ id: String) async {
        if finishedIDs.contains(id) {
            return
        }
        await withCheckedContinuation { continuation in
            finishObservers[id, default: []].append(continuation)
        }
    }
}

@MainActor
final class TaskProcessorStudentTests: XCTestCase {
    func testNegativeMaximumConcurrencyIsRejected() {
        XCTAssertThrowsError(try TaskProcessor(maximumConcurrency: -3)) { error in
            XCTAssertEqual(error as? TaskProcessorError, .nonPositiveMaximumConcurrency)
        }
    }

    func testFirstRepeatedIDIsReportedBeforeAnyWorkerStarts() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let probe = WorkProbe()
        let jobs = [
            Job(id: "a", input: 1),
            Job(id: "b", input: 2),
            Job(id: "b", input: 3),
            Job(id: "a", input: 4)
        ]

        do {
            _ = try await processor.process(jobs) { job in
                await probe.begin(job.id)
                return job.input
            }
            XCTFail("Expected duplicate ID error")
        } catch {
            XCTAssertEqual(error as? TaskProcessorError, .duplicateID("b"))
        }

        let started = await probe.startedIDs
        XCTAssertEqual(started, [])
    }

    func testActiveWorkersNeverExceedLimitAndFreedSlotStartsNextJob() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let probe = WorkProbe()
        let jobs = (1...5).map { Job(id: "j\($0)", input: $0) }

        let processing = Task {
            try await processor.process(jobs) { job in
                await probe.begin(job.id)
                await probe.hold(job.id)
                await probe.end(job.id)
                return job.input * 100
            }
        }

        await probe.waitUntilStarted("j1")
        await probe.waitUntilStarted("j2")
        let initiallyStarted = await probe.startedIDs
        XCTAssertEqual(Set(initiallyStarted), ["j1", "j2"])
        XCTAssertEqual(initiallyStarted.count, 2)

        await probe.release("j2")
        await probe.waitUntilStarted("j3")
        let afterFirstRelease = await probe.startedIDs
        XCTAssertEqual(afterFirstRelease.count, 3)
        XCTAssertEqual(afterFirstRelease.last, "j3")

        await probe.release("j1")
        await probe.waitUntilStarted("j4")
        await probe.release("j3")
        await probe.waitUntilStarted("j5")
        await probe.release("j4")
        await probe.release("j5")

        let results = try await processing.value
        let peak = await probe.peakActiveCount
        XCTAssertEqual(peak, 2)
        XCTAssertEqual(
            results,
            jobs.map { JobResult(id: $0.id, outcome: .succeeded($0.input * 100)) }
        )
    }

    func testReverseCompletionWithMixedOutcomesKeepsInputOrder() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 3)
        let probe = WorkProbe()
        let jobs = [
            Job(id: "a", input: 1),
            Job(id: "b", input: 2),
            Job(id: "c", input: 3)
        ]

        let processing = Task {
            try await processor.process(jobs) { job in
                await probe.begin(job.id)
                await probe.hold(job.id)
                await probe.end(job.id)
                if job.id == "b" {
                    throw StudentWorkerError.permanent
                }
                return job.input + 10
            }
        }

        await probe.waitUntilStarted("a")
        await probe.waitUntilStarted("b")
        await probe.waitUntilStarted("c")
        await probe.release("c")
        await probe.waitUntilFinished("c")
        await probe.release("b")
        await probe.waitUntilFinished("b")
        await probe.release("a")

        let results = try await processing.value
        let finished = await probe.finishedIDs
        XCTAssertEqual(finished, ["c", "b", "a"])
        XCTAssertEqual(
            results,
            [
                JobResult(id: "a", outcome: .succeeded(11)),
                JobResult(id: "b", outcome: .failed),
                JobResult(id: "c", outcome: .succeeded(13))
            ]
        )
    }

    func testEachOutcomeIsMappedAndProcessingContinuesAfterFailures() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let probe = WorkProbe()
        let jobs = [
            Job(id: "ok", input: 4),
            Job(id: "error", input: 5),
            Job(id: "cancel", input: 6),
            Job(id: "after", input: 7)
        ]

        let results = try await processor.process(jobs) { job in
            await probe.begin(job.id)
            await probe.end(job.id)
            switch job.id {
            case "error":
                throw StudentWorkerError.permanent
            case "cancel":
                throw CancellationError()
            default:
                return job.input * 3
            }
        }

        let started = await probe.startedIDs
        XCTAssertEqual(started, ["ok", "error", "cancel", "after"])
        XCTAssertEqual(
            results,
            [
                JobResult(id: "ok", outcome: .succeeded(12)),
                JobResult(id: "error", outcome: .failed),
                JobResult(id: "cancel", outcome: .cancelled),
                JobResult(id: "after", outcome: .succeeded(21))
            ]
        )
    }

    func testCallerCancellationKeepsCompletedResultsAndCancelsTheRest() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let probe = WorkProbe()
        let jobs = ["a", "b", "c", "d"].enumerated().map { Job(id: $1, input: $0) }

        let processing = Task {
            try await processor.process(jobs) { job in
                await probe.begin(job.id)
                await probe.hold(job.id)
                await probe.end(job.id)
                try Task.checkCancellation()
                return job.input + 1
            }
        }

        await probe.waitUntilStarted("a")
        await probe.waitUntilStarted("b")
        await probe.release("a")
        await probe.waitUntilStarted("c")

        processing.cancel()
        await probe.release("b")
        await probe.release("c")

        let results = try await processing.value
        let started = await probe.startedIDs
        XCTAssertEqual(Set(started), ["a", "b", "c"])
        XCTAssertEqual(started.count, 3)
        XCTAssertEqual(
            results,
            [
                JobResult(id: "a", outcome: .succeeded(1)),
                JobResult(id: "b", outcome: .cancelled),
                JobResult(id: "c", outcome: .cancelled),
                JobResult(id: "d", outcome: .cancelled)
            ]
        )
    }

    func testAlreadyCancelledCallerStartsNoWorker() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 3)
        let probe = WorkProbe()
        let jobs = [Job(id: "x", input: 1), Job(id: "y", input: 2)]

        let processing = Task {
            try await processor.process(jobs) { job in
                await probe.begin(job.id)
                return job.input
            }
        }
        processing.cancel()

        let results = try await processing.value
        let started = await probe.startedIDs
        XCTAssertEqual(started, [])
        XCTAssertEqual(
            results,
            [
                JobResult(id: "x", outcome: .cancelled),
                JobResult(id: "y", outcome: .cancelled)
            ]
        )
    }

    func testNonPositiveRetryAttemptsAreRejected() {
        for attempts in [0, -1] {
            XCTAssertThrowsError(try RetryPolicy(maximumAttempts: attempts)) { error in
                XCTAssertEqual(error as? RetryPolicyError, .nonPositiveMaximumAttempts)
            }
        }
        XCTAssertEqual(try RetryPolicy(maximumAttempts: 2).maximumAttempts, 2)
    }

    func testRetryRecoversBeforeLimitWithExactAttemptNumbers() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let probe = WorkProbe()
        let policy = try RetryPolicy(maximumAttempts: 4)

        let results = try await processor.process(
            [Job(id: "flaky", input: 5)],
            retryPolicy: policy
        ) { job, attempt in
            await probe.begin("\(job.id):\(attempt)")
            await probe.end("\(job.id):\(attempt)")
            if attempt < 3 {
                throw StudentWorkerError.transient
            }
            return job.input * attempt
        }

        let attempts = await probe.startedIDs
        XCTAssertEqual(attempts, ["flaky:1", "flaky:2", "flaky:3"])
        XCTAssertEqual(results, [JobResult(id: "flaky", outcome: .succeeded(15))])
    }

    func testRetryFailsAfterFinalAllowedAttempt() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let probe = WorkProbe()
        let policy = try RetryPolicy(maximumAttempts: 3)

        let results = try await processor.process(
            [Job(id: "broken", input: 1)],
            retryPolicy: policy
        ) { job, attempt in
            await probe.begin("\(job.id):\(attempt)")
            await probe.end("\(job.id):\(attempt)")
            throw StudentWorkerError.permanent
        }

        let attempts = await probe.startedIDs
        XCTAssertEqual(attempts, ["broken:1", "broken:2", "broken:3"])
        XCTAssertEqual(results, [JobResult(id: "broken", outcome: .failed)])
    }

    func testRetryNeverRepeatsCancellationError() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let probe = WorkProbe()
        let policy = try RetryPolicy(maximumAttempts: 5)
        let jobs = [Job(id: "stop", input: 1), Job(id: "go", input: 2)]

        let results = try await processor.process(jobs, retryPolicy: policy) { job, attempt in
            await probe.begin("\(job.id):\(attempt)")
            await probe.end("\(job.id):\(attempt)")
            if job.id == "stop" {
                throw CancellationError()
            }
            return job.input
        }

        let attempts = await probe.startedIDs
        XCTAssertEqual(attempts, ["stop:1", "go:1"])
        XCTAssertEqual(
            results,
            [
                JobResult(id: "stop", outcome: .cancelled),
                JobResult(id: "go", outcome: .succeeded(2))
            ]
        )
    }

    func testRetryStaysInsideOneConcurrencySlot() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let probe = WorkProbe()
        let policy = try RetryPolicy(maximumAttempts: 3)
        let jobs = [Job(id: "a", input: 1), Job(id: "b", input: 2)]

        let processing = Task {
            try await processor.process(jobs, retryPolicy: policy) { job, attempt in
                let key = "\(job.id):\(attempt)"
                await probe.begin(key)
                await probe.hold(key)
                await probe.end(key)
                if job.id == "a", attempt == 1 {
                    throw StudentWorkerError.transient
                }
                return job.input * 10 + attempt
            }
        }

        await probe.release("a:1")
        await probe.waitUntilStarted("a:2")
        let whileRetrying = await probe.startedIDs
        XCTAssertEqual(whileRetrying, ["a:1", "a:2"])

        await probe.release("a:2")
        await probe.release("b:1")

        let results = try await processing.value
        let attempts = await probe.startedIDs
        let peak = await probe.peakActiveCount
        XCTAssertEqual(attempts, ["a:1", "a:2", "b:1"])
        XCTAssertEqual(peak, 1)
        XCTAssertEqual(
            results,
            [
                JobResult(id: "a", outcome: .succeeded(12)),
                JobResult(id: "b", outcome: .succeeded(21))
            ]
        )
    }

    func testCallerCancellationStopsRetryAfterOrdinaryError() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let probe = WorkProbe()
        let policy = try RetryPolicy(maximumAttempts: 3)
        let jobs = [Job(id: "a", input: 1), Job(id: "b", input: 2)]

        let processing = Task {
            try await processor.process(jobs, retryPolicy: policy) { job, attempt in
                let key = "\(job.id):\(attempt)"
                await probe.begin(key)
                await probe.hold(key)
                await probe.end(key)
                throw StudentWorkerError.transient
            }
        }

        await probe.waitUntilStarted("a:1")
        processing.cancel()
        await probe.release("a:1")

        let results = try await processing.value
        let attempts = await probe.startedIDs
        XCTAssertEqual(attempts, ["a:1"])
        XCTAssertEqual(results, jobs.map { JobResult(id: $0.id, outcome: .cancelled) })
    }

    func testRetryRejectsDuplicateIDsAndHandlesEmptyInput() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let probe = WorkProbe()
        let policy = try RetryPolicy(maximumAttempts: 2)

        let empty = try await processor.process([], retryPolicy: policy) { job, _ in
            await probe.begin(job.id)
            return 0
        }
        XCTAssertEqual(empty, [])

        do {
            _ = try await processor.process(
                [Job(id: "x", input: 1), Job(id: "x", input: 2)],
                retryPolicy: policy
            ) { job, _ in
                await probe.begin(job.id)
                return job.input
            }
            XCTFail("Expected duplicate ID error")
        } catch {
            XCTAssertEqual(error as? TaskProcessorError, .duplicateID("x"))
        }

        let started = await probe.startedIDs
        XCTAssertEqual(started, [])
    }
}
