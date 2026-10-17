public struct Job: Sendable, Equatable {
    public let id: String
    public let input: Int

    public init(id: String, input: Int) {
        self.id = id
        self.input = input
    }
}

public enum JobOutcome: Sendable, Equatable {
    case succeeded(Int)
    case failed
    case cancelled
}

public struct JobResult: Sendable, Equatable {
    public let id: String
    public let outcome: JobOutcome

    public init(id: String, outcome: JobOutcome) {
        self.id = id
        self.outcome = outcome
    }
}

public enum TaskProcessorError: Error, Equatable {
    case nonPositiveMaximumConcurrency
    case duplicateID(String)
}

public struct RetryPolicy: Sendable, Equatable {
    public let maximumAttempts: Int

    public init(maximumAttempts: Int) throws {
        guard maximumAttempts > 0 else {
            throw RetryPolicyError.nonPositiveMaximumAttempts
        }
        self.maximumAttempts = maximumAttempts
    }
}

public enum RetryPolicyError: Error, Equatable {
    case nonPositiveMaximumAttempts
}

public actor TaskProcessor {
    private let maximumConcurrency: Int

    public init(maximumConcurrency: Int) throws {
        guard maximumConcurrency > 0 else {
            throw TaskProcessorError.nonPositiveMaximumConcurrency
        }
        self.maximumConcurrency = maximumConcurrency
    }

    public func process(
        _ jobs: [Job],
        worker: @escaping @Sendable (Job) async throws -> Int
    ) async throws -> [JobResult] {
        guard !jobs.isEmpty else { return [] }
        try validateUniqueIDs(jobs)

        let outcomes = await runBounded(jobCount: jobs.count) { index in
            do {
                return .succeeded(try await worker(jobs[index]))
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failed
            }
        }

        return zip(jobs, outcomes).map { JobResult(id: $0.id, outcome: $1) }
    }

    private func validateUniqueIDs(_ jobs: [Job]) throws {
        var seenIDs: Set<String> = []
        for job in jobs where !seenIDs.insert(job.id).inserted {
            throw TaskProcessorError.duplicateID(job.id)
        }
    }

    private func runBounded(
        jobCount: Int,
        work: @escaping @Sendable (Int) async -> JobOutcome
    ) async -> [JobOutcome] {
        var outcomes = [JobOutcome?](repeating: nil, count: jobCount)
        var nextIndex = 0
        let limit = maximumConcurrency

        await withTaskGroup(of: (Int, JobOutcome).self) { group in
            var activeCount = 0

            while true {
                if !Task.isCancelled {
                    while activeCount < limit, nextIndex < jobCount {
                        let index = nextIndex
                        nextIndex += 1
                        activeCount += 1
                        group.addTask {
                            (index, await work(index))
                        }
                    }
                } else {
                    group.cancelAll()
                }

                guard activeCount > 0, let (index, outcome) = await group.next() else {
                    break
                }
                outcomes[index] = outcome
                activeCount -= 1
            }
        }

        return outcomes.map { $0 ?? .cancelled }
    }
}

public extension TaskProcessor {
    func process(
        _ jobs: [Job],
        retryPolicy: RetryPolicy,
        worker: @escaping @Sendable (Job, Int) async throws -> Int
    ) async throws -> [JobResult] {
        guard !jobs.isEmpty else { return [] }
        try validateUniqueIDs(jobs)

        let maximumAttempts = retryPolicy.maximumAttempts
        let outcomes = await runBounded(jobCount: jobs.count) { index in
            var attempt = 1
            while true {
                do {
                    return .succeeded(try await worker(jobs[index], attempt))
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    guard attempt < maximumAttempts else { return .failed }
                    attempt += 1
                }
            }
        }

        return zip(jobs, outcomes).map { JobResult(id: $0.id, outcome: $1) }
    }
}
