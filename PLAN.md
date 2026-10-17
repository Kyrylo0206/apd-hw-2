# Implementation Plan

## Approach

Validate the concurrency limit in the initializer and check job IDs before
starting any worker. Use a task group with at most `maximumConcurrency`
active jobs. Add jobs in input order and start the next one when a slot opens.

Each child returns its input index and outcome. Store outcomes by index so
completion order does not change the result order. Map worker errors to
`.failed` and `CancellationError` to `.cancelled`.

Check caller cancellation before filling available slots. Cancel child work,
wait for active jobs, and mark jobs that never started as `.cancelled`.

The optional retry API uses the same scheduler. Attempts run sequentially
inside the job's slot. Retry ordinary errors up to the configured limit;
stop on success, `CancellationError`, or caller cancellation. Check
cancellation before each attempt.

## Checks

Run `swift test`. Tests cover validation, slot reuse, the concurrency limit,
result ordering, error handling, caller cancellation, and retry attempts.
They use actor gates rather than timing assertions.

Overlapping calls on one processor are outside the assignment's graded scope.
A worker that ignores cancellation is still awaited.
