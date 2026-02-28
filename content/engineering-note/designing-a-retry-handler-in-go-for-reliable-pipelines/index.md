---
title: "Designing a Retry Handler in Go for Reliable Pipelines"
date: 2026-02-27
draft: false
params:
  math: true
tags:
    - go
    - pipeline
    - error-handling
    - retry-handling
    - observability
---

![assembly-line](images/assembly-line.avif)

When working as a backend engineer, we'll inevitably end up building pipelines. Video transcoding, ETL jobs, file conversions, web scraping — pipelines are everywhere in backend systems. And one thing every pipeline has to deal with is retrying failed operations.

The common solution is simple: wrap the operation in a loop, sleep for a bit, and try again. For a lot of lightweight, single-worker scenarios, that's honestly fine. But once our pipeline is running dozens or hundreds of concurrent workers, that naive approach starts introducing subtle problems we won't notice until production.

This post walks through how I think about designing a retry handler in Go, and the decisions I made when building one. The code alone doesn't tell us what I considered and rejected along the way, that's what this post is for.

---

## What is a pipeline, really?

A pipeline is a sequence of operations or stages, where each stage takes an input, does something with it, and produces an output that feeds into the next stage. Think of it like an assembly line: raw material goes in one end, finished product comes out the other.

![three-stages-buckets](images/three-stages-buckets.avif)

Each stage is mostly stateless. It accepts an input, processes it, and returns an output without caring about what happened before or after. That said, a stage can be stateful, though that state is usually scoped to one end-to-end run of the pipeline rather than shared globally.

What makes pipelines interesting from a reliability standpoint is that each stage can either succeed or fail. When a stage fails, we have a choice: give up on the entire pipeline run, or retry that stage and try again. Most of the time, we want to retry, especially when the failure is transient, meaning it's not caused by bad input but by something external: a network blip, a temporarily overloaded service, a database that was briefly unavailable.

The simplest retry we can write looks something like this:

```go
var result Result
var err error

for attempts := 0; attempts < maxAttempts; attempts++ {
    result, err = runStage(input)
    if err == nil {
        break
    }
    time.Sleep(1 * time.Second)
}
```

Loop, try, sleep, repeat. It works. For a lot of cases it's genuinely fine. But this is where most of us stop, and it's also where the interesting problems start, which is what the rest of this post is about.

---

## Not all failures are the same

Before thinking about *how* to retry, it's worth thinking about *when* to retry. Because not all errors deserve the same treatment.

Some failures are clearly temporary. A network timeout, a 503 from an overloaded service, a database connection that dropped mid-query. All of these are good candidates for retry. The operation might succeed if we just try again in a moment.

Other failures are permanent. An authentication error means the credentials are wrong (retrying won't fix that). Invalid input means the request itself is malformed, it will produce the same result every time. Retrying these is just burning resources for no reason.

And then there's a middle ground: failures where we might want to retry, but only under specific conditions, or only after a human has intervened. Maybe a payment failed because of a soft decline, and we want to allow a manual retry but not an automatic one.

So a well-designed retry handler needs to know which category an error falls into. I think about it in three buckets: **auto-retry** (try again automatically), **manual retry** (don't auto-retry, but allow it if someone explicitly triggers it), and **never retry** (permanent failure, give up). We'll see how this maps to an actual implementation later.

![three-retry-buckets](images/three-retry-buckets.avif)

---

## What is backoff, and why does it matter?

Retrying immediately after a failure sounds like the right instinct, but it's usually the wrong move.

Think about what happens when a downstream service is struggling. It's slow, overloaded, or intermittently dropping connections. If out worker fails and immediately retries, we're sending another request to a service that's already overwhelmed. Multiply that by every concurrent worker doing the same thing, and we're not helping the situation, we're making it worse.

Backoff is the practice of waiting before retrying, and increasing that wait time with each subsequent failure. The idea is to give the downstream system room to recover, while still eventually trying again. It's sometimes called "being polite" to external services: we're not hammering them while they're down.

This is especially relevant when our pipeline involves external entities: REST APIs, third-party services, databases. These systems have their own capacity limits, and a well-behaved client respects that by backing off when things go wrong rather than piling on.

The most common form is **exponential backoff**, where the wait time doubles (or multiplies by some factor) on each attempt. We'll get to that in a moment.

![a timeline showing retry attempts spaced with increasing gaps — attempt 1 at t=0, attempt 2 at t=1s, attempt 3 at t=3s, attempt 4 at t=7s — to visually show exponential growth in wait time](images/exponential-backoff.avif)

---

## Context: knowing when to stop

One concept worth explaining before we get into the implementation, especially for readers coming from outside Go: **context**.

In most backend systems, operations don't run in isolation. They're part of a larger request or job that has a lifetime: a deadline, a timeout, or a cancellation signal. "Context" is the mechanism for carrying that lifetime information alongside an operation. When a request times out, or when a caller decides to cancel, the context is the thing that communicates that signal downstream to everything running on its behalf.

This matters a lot for retry handlers. Imagine a worker that's retrying a failing operation, sleeping between attempts. Without context awareness, if the parent job is cancelled or times out halfway through, the worker keeps sleeping and retrying, completely unaware that nobody cares about the result anymore. In a concurrent system with many workers, that's a lot of wasted work and leaked resources.

A well-designed retry handler needs to listen to this cancellation signal and stop immediately when it fires, even mid-sleep. The retry loop should only continue while the context is still alive.

This isn't Go-specific. The same idea exists in other ecosystems under different names. Cancellation tokens in C#, `AbortSignal` in JavaScript, or simply passing a "done" channel manually. The principle is the same: 

> an operation should know when its work is no longer needed and stop gracefully.

---

## Observability: knowing what's happening inside

A retry handler running silently is a black box. In production, sometimes (or often) we want to know when retries are happening, how many attempts were needed, what errors were encountered, and how long the backoff delays were. Without this, debugging a flaky pipeline is guesswork.

This is the observability problem and it's worth thinking about as a first-class concern when designing our retry handler, not an afterthought.

The minimal thing we need is a way to hook into the retry lifecycle. At key moments: an attempt failed, a backoff started, the operation finally succeeded, all attempts exhausted. Our handler should be able to emit some kind of signal. What we do with that signal is up to the caller: write to a structured logger, increment a metric counter, emit a trace span, or do nothing at all.

The "do nothing" case matters. We don't want logging overhead when it's disabled. In my implementation, I designed a `DebugLogger` interface that the caller provides:

```go
type DebugLogger interface {
    Enabled() bool
    LogRetry(ctx context.Context, attempt int, maxAttempts int, backoff time.Duration, err error)
}
```

Two methods. `Enabled()` is checked before any logging work happens, if it returns false, `LogRetry` is never called. This means when we pass a `NoOpLogger`, there's literally zero overhead from the logging path. No string formatting, no allocations.

```go
type NoOpLogger struct{}

func (n *NoOpLogger) Enabled() bool { return false }
func (n *NoOpLogger) LogRetry(_ context.Context, _ int, _ int, _ time.Duration, _ error) {}
```

When logging is enabled, each retry attempt emits the attempt number, the max attempts configured, the backoff delay being applied, and the error that triggered the retry. On success, backoff is 0 and error is nil. On exhaustion, the last error is included.

This gives the caller everything they need to wire up to whatever observability stack they're using: [slog](https://pkg.go.dev/log/slog), [zap](https://github.com/uber-go/zap), Prometheus, OpenTelemetry, whatever. The retry handler doesn't care. It just calls `LogRetry` at the right moments and lets the caller decide what to do with it.

![a flow showing the retry handler in the middle, with an arrow going into a "Logger" box on the side at each attempt. The logger box branches into three outputs: "structured log", "metrics counter", "trace span" — showing that the same interface can feed different observability backends](images/retry-logging.avif)

---

## What a retry handler actually needs

Before getting into the decisions, it's worth being precise about what we even want. A retry handler should:

- **Retry a failed operation** up to some maximum number of attempts
- **Wait between attempts** so we don't hammer a failing service
- **Increase the wait time** exponentially as attempts accumulate
- **Add randomness** to the wait time to avoid synchronized retries across workers
- **Stop when the context is cancelled** so retries don't outlive the operation's lifetime
- **Distinguish retryable from non-retryable errors** so we don't retry something that will never succeed

Each of these requirements sounds straightforward on its own, but they interact in ways that force us to make real design decisions. Let me walk through the ones that mattered most.

---

## Exponential backoff: the baseline

The first thing most people reach for is exponential backoff. Instead of a fixed sleep between retries, we increase the wait time exponentially on each attempt.

The formula looks roughly like this:

\[delay = initialDuration × (multiplier^{attempt-1})\]

So if our initial duration is 1 second and our multiplier is 2:
- Attempt 1: 1s
- Attempt 2: 2s
- Attempt 3: 4s
- Attempt 4: 8s

We also cap it at some maximum so it doesn't grow forever. In practice this looks like:

```go
func exponentialBackoffDelay(attempt int, backoff backoffConfig) time.Duration {
    exponent := float64(attempt - 1)
    delay := float64(backoff.initialDuration) * math.Pow(backoff.multiplier, exponent)
    if delay > float64(backoff.maxDuration) {
        delay = float64(backoff.maxDuration)
    }
    return time.Duration(delay)
}
```

This is table stakes. Where things get more interesting is jitter.

---

## Deterministic vs. indeterministic jitter

Exponential backoff solves the "don't hammer a struggling service" problem. But it introduces a subtler one.

Imagine we have 50 concurrent workers. They all hit the same downstream API. The API goes down at 14:00:00. All 50 workers fail at almost the same moment, and they all start their backoff timers at almost the same moment. With a 1s initial delay and a multiplier of 2, they'll all retry at 14:00:01. They all fail again. They all sleep for 2 seconds. They all retry at 14:00:03. And so on.

This is the **thundering herd problem**. Instead of spreading retries out across time, our workers stay perfectly synchronized, attacking the recovering service in waves. Each wave can knock it back down just as it's starting to recover. The backoff didn't help; it just added rhythm to the problem.

![two timelines side by side. Top: "Without jitter" — 50 worker dots all retrying at the same timestamps, shown as vertical spikes. Bottom: "With jitter" — the same 50 workers retrying spread across a wider window, shown as scattered dots. Label on the top is "thundering herd" and the bottom is "distributed load"](images/with-without-jitter-comparisons.avif)

The fix is **jitter**: adding a random offset to each delay so that workers spread out their retries naturally.

```go
func computeJitter(max time.Duration) time.Duration {
    if max <= 0 {
        return 0
    }
    return time.Duration(rand.Int63n(int64(max)))
}
```

With jitter, worker A might retry at 14:00:01.3, worker B at 14:00:01.7, worker C at 14:00:01.1. The load distributes. The recovering service gets a chance to breathe.

Simple enough. But here's the design question I had to answer: **should jitter be deterministic or indeterministic?**

The **deterministic approach** means exposing a seed parameter. The caller provides a seed, we initialize a local random generator with it, and jitter becomes reproducible. This is appealing for testing: we can write tests that assert exact retry timings. It also gives the caller more control, which feels flexible.

The **indeterministic approach** means relying on a randomly seeded global random generator. Jitter becomes unpredictable. We lose reproducibility.

Personally, I would choose indeterministic, because **deterministic seeding breaks the whole point of jitter in concurrent scenarios**:

Imagine we have 50 workers, each running a retry loop. If the caller is responsible for passing a seed, there's a real chance they'll pass the same seed to all of them. Or, derive seeds from something predictable like an index. Now all 50 workers produce identical jitter sequences. We've worked hard to add jitter, but our workers are still synchronized.

With indeterministic seeding, the global random generator is shared across all workers, and each call pulls from an independently progressing state. We're guaranteed different jitter values across concurrent callers, which is exactly what jitter is for.

Yes, this makes testing harder. We can't assert exact timings. But in my experience, the correctness guarantee under concurrency is worth more than the testing convenience. In this case we have two testing strategies:

### Indeterministic Jitter Testing Strategy 1: Range-Based Assertions

The most straightforward way to test jitter is to stop checking for **equality** and start checking for **bounds**. Instead of asserting that a delay is exactly 1250ms, we assert that it falls within the mathematically valid window.

The delay should always satisfy:

$$\text{baseDelay} \le \text{actualDelay} \le \text{baseDelay} + \text{jitterMax}$$

* **How it works**: We calculate the deterministic portion of the backoff (the "base") and then verify the actual result isn't smaller than that base or larger than the base plus our maximum allowed jitter.
* **The Verdict**: This is language-agnostic and requires zero changes to the API. It tests the code exactly as it runs in production, though it can feel "loose" because we aren't verifying the specific distribution of the randomness.

```go
func TestExponentialBackoffDelay(t *testing.T) {
    jitterMax := 50 * time.Millisecond
    
    for i := 1; i <= 5; i++ {
        delay := retryHandler.ExponentialBackoffDelay(i, jitterMax)
        
        // Calculate the base (deterministic) backoff without jitter
        baseDelay := calculateBaseBackoff(i, param)
        
        // Assert the delay is within the valid jitter window
        if delay < baseDelay || delay > baseDelay+jitterMax {
            t.Errorf("Attempt %d: expected delay between %v and %v, got %v", 
                i, baseDelay, baseDelay+jitterMax, delay)
        }
    }
}
```

### Indeterministic Jitter Testing Strategy 2: Dependency Injection (The "Pluggable" PRNG)

If we need 100% reproducibility, we have to control the source of randomness. In architectural terms, this is **Dependency Injection**. Instead of the handler reaching for a global random number generator, we can allow users to inject a predetermined pseudorandom number generator (PRNG), but keep it hidden from the primary struct:

```go
type RetryOptions struct {
    randSource rand.Source // Default uses safe runtime PRNG
    maxAttempts int
    // ...
}

type RetryOption func(*RetryOptions)

// WithRand is purely used for testability
func WithRand(src rand.Source) RetryOption {
    return func(o *RetryOptions) {
        o.randSource = src
    }
}
```

When we write tests, we can inject a fixed-seed PRNG locally. Go's Functional Options pattern make this looks elegant:

```go
// In a test:
fixedPRNG := rand.NewSource(42)
retryHandler.Retry(ctx, fn, retryHandler.WithRand(fixedPRNG))

// In production:
retryHandler.Retry(ctx, fn) // Safely uses default, non-seeded PRNG
```

* **In Production**: Use a cryptographically secure or properly seeded global generator to ensure workers stay desynchronized.
* **In Testing**: Use a fixed seed (e.g., `42`). Now, our "random" jitter is perfectly predictable, allowing us to assert exact millisecond values in our test suite.

This approach satisfies the "clean code" itch: the production environment gets the safety of indeterministic jitter, while the CI/CD pipeline gets the stability of deterministic tests.

---

## Multiple return values vs. a result struct

Go's canonical error handling is the multi-value return:

```go
value, err := doSomething()
if err != nil {
    // handle it
}
```

Every Go developer knows this pattern. It's explicit, readable, and idiomatic. The obvious API for a retry handler would be:

```go
value, err := retry(operation)
```

But I ran into a problem: a retry handler naturally produces more than just a value and an error. It also produces **attempt count** (how many times did we actually try before succeeding or giving up?). That's useful information. We might want to log it, emit it as a metric, or use it to decide how to respond upstream.

Suddenly the signature becomes:

```go
value, attempts, err := retry(operation)
```

That's three return values. It works, but it starts to feel unwieldy, especially when we want to pass the result around or make decisions on it before consuming it.

The alternative is to wrap everything in a result struct:

```go
type Result struct {
    Value    interface{}
    Attempts int
    Err      error
}
```

This pattern is actually well-established in other languages. [Rust](https://doc.rust-lang.org/rust-by-example/error/result.html)'s `Result<T, E>` type is the canonical example: it wraps either a success value or an error into a single type, and we pattern-match on it to handle both cases. Functional languages like [Haskell](https://hackage-content.haskell.org/package/base-4.22.0.0/docs/Data-Either.html) and [Scala](https://www.scala-lang.org/api/current/scala/util/Try.html) have similar constructs (`Either`, `Try`). The idea is to make the success and failure paths explicit and composable, rather than relying on a side-channel like a second return value.

Go doesn't have pattern matching, but the same grouping instinct applies. A result struct lets we pass the outcome around as a first-class value, inspect it, or chain behavior on it before unpacking:

```go
result := retry(operation)
if result.Err == nil {
    log.Printf("succeeded after %d attempts", result.Attempts)
    process(result.Value)
}
```

The tradeoff is that this feels less idiomatic to developers used to the classic multi-value pattern. Returning a struct and accessing fields on it is a different mental model.

So we can did both: We can return a result struct, but also provided a `Decompose()` method that unpacks it back into multiple return values:

```go
value, attempts, err := retry(operation).Decompose()
if err != nil {
    // classic Go error handling, business as usual
}
```

The goal was to bridge the gap: developers who prefer method-style access get a result struct with methods on it, developers who want `if err != nil` can call `Decompose()` and pretend the struct never existed. Neither style feels like a second-class citizen.

### Generic Result
In one of my specific implementations, I also made the struct generic. Meaning the `Value` field carries a proper type rather than a plain `interface{}`, so I don't need to type-assert when using it. 

That's an additional decision on top of this one, and it's specific to Go's type system. If you're building your own retry handler, the core idea of wrapping the result holds regardless of whether you go that route.

More about this on later section.

---

## Retryable vs. non-retryable errors: putting the policy into practice

Earlier I mentioned that errors fall into three buckets: auto-retry, manual retry, and never retry. Now let's talk about how that actually gets implemented.

The naive approach is to let the retry handler decide: check the HTTP status code, pattern-match the error message, make a guess. This sounds convenient but it's fragile. The retry handler has no idea about our domain. It doesn't know that a 422 from our particular API means "bad input, don't bother" while a 422 from a different API means something retryable.

A cleaner approach is to let the error itself carry the policy. When an operation fails, it returns an error. That error knows what it is: our code created it. So the right place to classify it is at the point where the error is constructed, not inside the retry handler.

In practice this means defining a contract: if our error type declares its retry policy, the handler will respect it. If it doesn't declare anything, the handler falls back to a sensible default (in my case, auto-retry, because most transient errors in a pipeline context should be retried).

```go
type RetryableError interface {
    error
    RetryPolicy() RetryPolicy // returns Auto, Manual, or Never
}
```

Our domain errors implement this interface when they need to communicate a specific policy:

```go
type AuthError struct{ msg string }

func (e *AuthError) Error() string            { return e.msg }
func (e *AuthError) RetryPolicy() RetryPolicy { return RetryPolicyNever }
```

Now when the retry handler receives an `AuthError`, it knows to stop immediately without any special casing. The handler stays dumb and general; the errors carry the intelligence.

I wrote other post about [designing error domain](../designing-error-returns-in-go-a-case-study-in-domain-orchestration-separation.md). 

---

## Putting it together: context cancellation in the loop

Earlier I explained what context is conceptually. Here's what it looks like in the retry loop itself.

After each failed attempt, before sleeping for the backoff duration, the handler checks whether the context is still alive. If it's been cancelled or timed out, the handler stops. Regardless of how many attempts remain:

```go
select {
case <-ctx.Done():
    // context cancelled or timed out, stop retrying
    return failureResult(ctx.Err(), attempts)
case <-time.After(delay):
    // backoff elapsed normally, proceed to next attempt
}
```

The `select` here is key. It means the handler isn't just checking the context at the start of each iteration. It's listening to it during the sleep itself. If cancellation fires at second 1.5 of a 2-second backoff wait, the handler wakes up immediately and stops. It doesn't wait out the remaining 0.5 seconds.

This is a small detail that matters a lot at scale. In a system with hundreds of concurrent workers, prompt response to cancellation is the difference between a clean shutdown and a process that lingers for minutes doing work nobody needs.

---

## Making the retry handler general: the case for generics

If you've built a few pipeline stages, you'll start noticing a pattern. Each stage does something slightly different. One fetches from an API, another transforms a record, another writes to a database. But, the retry logic around them is identical: Wait, retry, backoff, check the context, handle the error policy, etc. Same structure every time.

The natural instinct is to generalize. Write one retry handler, use it everywhere.

The problem is that each stage produces a different type of result. A stage that fetches user data returns a `User`. A stage that computes a price returns a `float64`. A stage that writes to storage might return nothing at all. If your retry handler is hardcoded to a specific return type, you're back to writing one handler per stage, which defeats the point.

The fundamental insight is that a pipeline stage is just a **function**: it takes no arguments (it closes over its inputs) and returns either a result or an error.

```
operation = func() -> (Result, Error)
```

That's it. The retry handler doesn't care what `Result` is. It just calls the function, checks if there was an error, and decides whether to retry. The type of the result is irrelevant to the retry logic itself.

This is exactly the problem that **generics** solve. Generics let us write code that is parameterized over a type. The type becomes a variable, filled in at the call site. In Go, it looks like this:

```go
func Retry[T any](ctx context.Context, logger DebugLogger, fn func() (T, error), opts ...RetryOption) Result[T] {
    // retry logic here. Completely unaware of what T actually is
}
```

The `[T any]` declares a type parameter. `T` can be anything. When we call `Retry`, Go infers `T` from the function we pass in:

```go
// T is inferred as User
result := Retry(ctx, logger, func() (User, error) {
    return fetchUser(userID)
})

// T is inferred as float64
result := Retry(ctx, logger, func() (float64, error) {
    return computePrice(itemID)
})
```

Both calls go through the exact same retry handler. The type changes at the call site, not inside the handler. The result carries the right type automatically, without casting, without `interface{}`, and without loss of type safety.

![a single "Retry Handler" box in the center, with three arrows coming in from the left labeled "func() (User, error)", "func() (float64, error)", "func() ([]byte, error)", and three arrows going out to the right labeled "Result[User]", "Result[float64]", "Result[[]byte]" — showing that the same handler works for any type](images/generic-retry-handler.avif)

The `Result[T]` struct follows the same pattern:

```go
type Result[T any] struct {
    value    T
    attempts int
    err      error
}
```

`value` holds a `T`: whatever type the operation produced. The rest of the struct is the same regardless. This is what makes `Decompose()` work cleanly too:

```go
func (r Result[T]) Decompose() (T, int, error) {
    return r.value, r.attempts, r.err
}
```

The return type of `Decompose()` is `T`. It adapts to whatever the original operation returned.

Generics aren't unique to Go. The same concept exists across many languages, just with different syntax: `<T>` in Java, C#, Kotlin, and Swift; `template<typename T>` in C++; type parameters in TypeScript. If you're building a retry handler in any of these, the same design applies. The operation is a function parameterized over its return type, the result wraps that type, and the handler stays completely general.

The payoff is that we write the retry logic once: with all the backoff, jitter, context cancellation, and error policy logic, and it works for every stage in our pipeline, regardless of what each stage produces.

---

## Closing thoughts

Retry logic is one of those things that looks trivial but actually isn't (for most systems). 

A `for` loop with `time.Sleep` gets us 80% of the way there, but the remaining 20% is where production systems get hurt: thundering herds from unsynchronized jitter, retrying errors that will never succeed, loops that outlive their contexts, and handler code duplicated across every stage because nobody thought to generalize it.

The decisions I documented here aren't the only reasonable ones. Someone could make a strong argument for deterministic jitter in certain testing-heavy environments. Someone could reasonably prefer plain multiple return values over a result struct for a simpler API surface. These are tradeoffs, not truths.

But that's exactly the point. When we build something for real use, we have to pick a side. I've tried to be honest here about which side I picked and why. The decisions themselves are in Go, but the problems they solve: backoff politeness, thundering herds, error classification, context lifetime, type-safe generalization, show up in any language and any pipeline system.

I actually implemented all of this in **retrier**, a small Go package for retry handling. You can find it at [github.com/rohmanhakim/retrier](https://github.com/rohmanhakim/retrier) 

Feel free to poke around the code and see how these decisions landed in practice.

Anyway, thanks for reading, and happy retrying!
