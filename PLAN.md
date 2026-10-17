# Implementation Plan

Complete this before implementation and update it when the plan changes.

## Approach

- `TaskProcessor` is an actor that stores the validated `maximumConcurrency`.
  `init` throws `.nonPositiveMaximumConcurrency` for values `<= 0`.
- `process` returns `[]` for empty input, then runs a left-to-right preflight
  over a `Set<String>` and throws `.duplicateID` for the first ID already seen,
  before any worker is invoked.
- Bounded scheduling lives in one private actor method, `runBounded`, shared by
  the base and retry APIs. It uses `withTaskGroup`, a `nextIndex` cursor into
  the input, and an `activeCount`. At every scheduling decision (the initial
  fill and after each completed child) it starts jobs from left to right while
  `activeCount < maximumConcurrency`.
- Indexed result storage: each child task returns `(index, outcome)` and the
  actor writes it into a `[JobOutcome?]` sized to the input, so the returned
  `[JobResult]` is in input order regardless of completion order.
- Outcome mapping happens inside each child: returned value → `.succeeded`,
  `CancellationError` → `.cancelled`, any other error → `.failed`. Children
  never throw, so one failure does not affect other jobs.
- Cancellation: each scheduling decision checks `Task.isCancelled`. Once it is
  observed, the processor calls `group.cancelAll()`, starts no new worker, and
  keeps draining the already started children so their real outcomes are kept
  (cooperative workers report `.cancelled`). Never-started slots stay `nil` and
  are reported as `.cancelled`.
- Retry extension: `RetryPolicy` validates `maximumAttempts > 0`. The retry
  `process` reuses the same preflight and `runBounded`; its per-job work is a
  sequential attempt loop inside one child task, so retries never take an
  extra concurrency slot. Ordinary errors retry until the final attempt
  (`.failed`), `CancellationError` returns `.cancelled` immediately, and there
  is no delay or backoff.

## Milestones

- [x] Validate configuration and all job IDs before starting work.
- [x] Schedule jobs within the concurrency limit and preserve input order.
- [x] Map success, ordinary errors, and cancellation outcomes.
- [x] Handle caller cancellation and never-started jobs.
- [x] Add at least six distinct student-authored tests and run `swift test`.
- [x] Optional: deterministic retry policy extension.

## Risks and checks

| Risk | Check |
| --- | --- |
| Worker runs before duplicate detection | `testFirstRepeatedIDIsReportedBeforeAnyWorkerStarts`, `testRetryRejectsDuplicateIDsAndHandlesEmptyInput` assert no worker started. |
| Active count exceeds limit or freed slot is not reused | `testActiveWorkersNeverExceedLimitAndFreedSlotStartsNextJob` holds workers in a gate, checks peak active count and that the next job starts only after a release. |
| Results follow completion order | `testReverseCompletionWithMixedOutcomesKeepsInputOrder` forces reverse completion with mixed outcomes. |
| A failure or worker-thrown `CancellationError` stops other work | `testEachOutcomeIsMappedAndProcessingContinuesAfterFailures`. |
| Queued jobs start after caller cancellation, or finished results are overwritten | `testCallerCancellationKeepsCompletedResultsAndCancelsTheRest`, `testAlreadyCancelledCallerStartsNoWorker`. |
| Retry uses wrong attempt numbers, retries cancellation, or takes an extra slot | `testRetryRecoversBeforeLimitWithExactAttemptNumbers`, `testRetryFailsAfterFinalAllowedAttempt`, `testRetryNeverRepeatsCancellationError`, `testRetryStaysInsideOneConcurrencySlot`, `testNonPositiveRetryAttemptsAreRejected`. |
| Flaky timing-based tests | All tests synchronize via an actor gate and start/finish observers; no sleeps or elapsed-time assertions. The suite was run repeatedly with no failures. |

Assumption: a worker that ignores cancellation is awaited and keeps whatever
outcome it produces, as the contract does not guarantee its completion as
cancelled.
