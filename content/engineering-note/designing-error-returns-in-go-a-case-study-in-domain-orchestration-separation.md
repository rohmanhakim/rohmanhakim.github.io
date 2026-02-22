---
title: "Designing Error Returns in Go: A Case Study in Domain-Orchestration Separation"
date: 2026-02-08
draft: false
tags:
    - go
    - design-pattern
    - error-handling
    - logging
    - observability
summary: "Explore how to design error-returning functions in Go that separate domain logic from orchestration concerns. Learn why a custom RepairableResult type beats (bool, error) and error-only patterns when building observable, testable, and reusable validation logic in production systems."
---
I recently refactored a Go codebase where I had a checking function `isRepairable()` that returns a boolean. Inside, it has several sequential checks with an early return pattern to validate against business rules:

```go
func isRepairable(doc *html.Node) bool {
    // Check 1: Competing roots
    if hasCompetingDocumentRoots(docQuery) {
        return false  
    }
    
    // Check 2: No structural anchors
    if len(headings) == 0 && !hasStructuralAnchors(docQuery) {
        return false
    }
    
    // ... more checks ...
    
    // All checks passed - document is repairable
    return true
}
```

The caller checks the returned bool and returns an error if it's false:

```go
repairable := isRepairable(doc)
if !repairable {
    return SanitizedDoc{}, &SanitizationError{
        Cause: ErrCauseStructurallyIncorrect,
        ...
    }
}
```

The problem is every check always returns `ErrCauseStructurallyIncorrect`. It's not wrong, it's just very limiting. I wanted to make the error more granular for logging purposes, so the logging would be richer as I passed more context about the actual cause.

## The Observability Requirement

At the highest level of the sanitization pipeline, there is observability logging:

```go
func (s *Sanitizer) Sanitize(
    inputDoc *html.Node,
) (SanitizedDoc, failure.ClassifiedError) {
    sanitizedDoc, err := sanitize(inputDoc)
    if err != nil {
        var sanitizationError *SanitizationError
        errors.As(err, &sanitizationError)

        // Build contextual attributes based on the error cause
        attrs := buildErrorAttributes(sanitizationError)

        s.metadataRecorder.RecordError(
            time.Now(),
            "sanitizer",
            "Sanitizer.Sanitize",
            mapSanitizationErrorToMetadataCause(*sanitizationError),
            err.Error(),
            attrs,
        )
        return SanitizedDoc{}, sanitizationError
    }
    return sanitizedDoc, nil
}
```

The `sanitize()` function calls `isRepairable` and uses its result to gatekeep the downstream sanitization process. I need granular error causes because `RecordError()` uses these to build metrics, alerts, and debugging context. This requirement constrained the design.

## Design Alternatives Considered

There are several common patterns in Go for this type of function. Let me walk through what I considered and why I made the choices I did.

### Option 1: Return `(bool, error)`

```go
func isRepairable(doc *html.Node) (bool, error) {
    // Check 1: Competing roots
    if hasCompetingDocumentRoots(doc) {
        return false, &SanitizationError{
            Cause: ErrCauseCompetingRoots,
            ...
        }
    }
    
    // Check 2: No structural anchors
    if len(headings) == 0 && !hasStructuralAnchors(doc) {
        return false, &SanitizationError{
            Cause: ErrCauseNoStructuralAnchor,
            ...
        }
    }
    
    // ... more checks ...
    
    // All checks passed - document is repairable
    return true, nil
}
```

You might ask: 

> "What's the purpose of the bool if you can just infer it from whether error is nil?"

**Short answer:** In `(bool, error)`, the bool represents the domain truth of the predicate, while the error represents failure to evaluate or exceptional cause. They answer two different questions:

- `bool` -> "Is the condition true?"
- `error` -> "Was the check itself successful?"

This separation is intentional in Go API design.

**Long answer:** A checker with `(bool, error)` distinguishes:

| Axis                  | Meaning        |
| --------------------- | -------------- |
| Evaluation succeeded? | `err == nil`   |
| Predicate is true?    | `bool == true` |

That gives three meaningful states:

| bool  | error   | Meaning                               |
| ----- | ------- | ------------------------------------- |
| true  | nil     | condition holds                       |
| false | nil     | condition does not hold (normal case) |
| false | non-nil | check could not be completed          |

This is impossible to encode with just error unless you overload error to also mean "false," which is often semantically wrong.

#### When `(bool, error)` is genuinely useful:

**1. False is a normal, non-error outcome**

Example: authorization check with infrastructure dependency.

```go
func IsAllowed(user User, resource string) (bool, error)
```

- User not allowed -> `(false, nil)` -> normal business result
- Policy service unreachable -> `(false, err)` -> operational failure

Caller:
```go
ok, err := IsAllowed(u, r)
if err != nil {
    return err // system problem
}
if !ok {
    return ErrForbidden // domain result
}
```

Without the bool, you'd be forced to treat "not allowed" as an error, which pollutes error semantics.

**2. To avoid using errors for control flow**

Go style discourages using errors to represent expected boolean outcomes. In Go, `error` is intended to signal abnormal or exceptional conditions, not ordinary branch outcomes. Using errors to encode expected boolean results conflates two semantic layers and degrades API clarity, performance, and composability.

Bad design:
```go
func CheckQuota(u User) error
```

Where:
- `nil` = allowed
- `ErrQuotaExceeded` = false

This is acceptable for validation, but not ideal if `false` is a frequent, expected branch in normal flow. Then `(bool, error)` is clearer.

### Option 2: Return only `error`

When false is the frequent case, it's good to omit the bool and return only `error`. If it's `nil`, the check passes.

```go
func validateRepairability(doc *html.Node) error {
    // Check 1: Competing roots
    if hasCompetingDocumentRoots(doc) {
        return &SanitizationError{
            Cause: ErrCauseCompetingRoots,
            ...
        }
    }
    
    // Check 2: No structural anchors
    if len(headings) == 0 && !hasStructuralAnchors(doc) {
        return &SanitizationError{
            Cause: ErrCauseNoStructuralAnchor,
            ...
        }
    }
    
    // ... more checks ...
    
    // All checks passed - document is repairable
    return nil
}
```

Caller:

```go
err := validateRepairability(doc)
if err != nil {
    return err
}
```

This is preferred when:
- Failure reasons matter more than true/false
- Check is gatekeeping
- Pattern matches `ValidateX`, `CheckX`, `EnsureX`

This is often more idiomatic than `(bool, error)` for validation/guard-style checks.

## Why I Chose Neither

### Reason 1: No `(false, nil)` state exists in my domain

In the `(bool, error)` pattern, there's this possibility:

```go
(false, nil) -> normal business result
```

This doesn't suit my case. I need the caller to be able to access the structured cause. I want the caller to know the cause of the business rule violation because the purpose is to enrich the logging at the topmost level. This branch of business flow won't happen. The cause when the document cannot be repaired must be known and enforced, as no operational error will happen downstream that would prevent me from determining *why* it's unrepairable.

### Reason 2: I want to keep domain logic separate from error infrastructure

The "return error" pattern was close to being chosen: `isRepairable` is a gatekeeper (in essence, a validator) and no further flow would be executed if it fails.

Had I chosen the "return error" pattern, `isRepairable` (or `validateRepairability`, in this case) would look like this:

```go
func validateRepairability(doc *html.Node) error {
    // Check 1: Competing roots
    if hasCompetingDocumentRoots(doc) {
        return &SanitizationError{
            Cause: ErrCauseCompetingRoots,
            Message: "competing document roots found",
            Retryable: false,
        }
    }
    
    // Check 2: No structural anchors
    if len(headings) == 0 && !hasStructuralAnchors(doc) {
        return &SanitizationError{
            Cause: ErrCauseNoStructuralAnchor,
            Message: "no structural anchors found",
            Retryable: false,
        }
    }
    
    // ... more checks ...
    
    return nil
}
```

It becomes polluted by high-level (sanitization, in this case) errors. `validateRepairability` would be exposed to any other sanitization errors not related to repairing. If you look at my `SanitizationError`:

```go
type SanitizationError struct {
    Message   string
    Retryable bool
    Cause     SanitizationErrorCause
}
```

It's an orchestration-level concern. The `Retryable` flag, the `Message` formatting, these are decisions made at the boundary between the sanitization pipeline and the rest of the system, not decisions inherent to the question "is this document repairable?"

More importantly, if I later need to check repairability in a different context, say, a CLI tool that validates document files, or a completely different service, I'd have to drag `SanitizationError` along with it. The domain logic would be coupled to infrastructure concerns.

## The Solution: Domain-Specific Result Type

I introduced a repairing-specific struct to wrap the predicate and the reason:

```go
// RepairableResult contains the outcome of the repairability check.
// If Repairable is false, Reason contains the specific violation type.
type RepairableResult struct {
    Repairable bool
    Reason     UnrepairabilityReason // empty when Repairable is true
}
```

And the reason enums:

```go
type UnrepairabilityReason string

const (
    // ReasonCompetingRoots: Multiple article/main elements at same level (S3 invariant violation)
    ReasonCompetingRoots UnrepairabilityReason = "competing_roots"

    // ReasonNoStructuralAnchor: No headings and no structural anchors like article/main (H3 invariant violation)
    ReasonNoStructuralAnchor UnrepairabilityReason = "no_structural_anchor"

    // ... more reason enums ...
)
```

The function now looks like this:

```go
func isRepairable(doc *html.Node) RepairableResult {
    // Check 1: Competing roots
    if hasCompetingDocumentRoots(docQuery) {
        return RepairableResult{Repairable: false, Reason: ReasonCompetingRoots}
    }
    
    // Check 2: No structural anchors
    if len(headings) == 0 && !hasStructuralAnchors(docQuery) {
        return RepairableResult{Repairable: false, Reason: ReasonNoStructuralAnchor}
    }
    
    // ... more checks ...
    
    // All checks passed - document is repairable
    return RepairableResult{Repairable: true, Reason: ""}
}
```

Then I created a mapper function to translate domain reasons to orchestration-level error causes:

```go
// mapReasonToErrorCause maps UnrepairabilityReason to SanitizationErrorCause.
// This translation occurs at the sanitize() level to keep isRepairable() independent
// of error cause types.
func mapReasonToErrorCause(reason UnrepairabilityReason) SanitizationErrorCause {
    switch reason {
    case ReasonCompetingRoots:
        return ErrCauseCompetingRoots
    case ReasonNoStructuralAnchor:
        return ErrCauseNoStructuralAnchor
    
    // ... more mappings ...
    
    default:
        return ""
    }
}
```

The caller becomes:

```go
// ...

if !isParseable(doc) {
    return SanitizedDoc{}, &SanitizationError{
        Message:   "input document cannot be parsed: nil node or no content",
        Retryable: false,
        Cause:     ErrCauseUnparseableDoc,
    }
}

result := isRepairable(doc)
if !result.Repairable {
    cause := mapReasonToErrorCause(result.Reason)
    return SanitizedDoc{}, &SanitizationError{
        Message:   fmt.Sprintf("document is not repairable: %s", result.Reason),
        Retryable: false,
        Cause:     cause,
    }
}

// ...
```

## Why This Design Works

### 1. Clear Separation of Concerns

`isRepairable()` answers a pure domain question: "Can this document be repaired?" It knows nothing about:
- How errors are structured in the sanitization pipeline
- Whether failures are retryable
- How messages should be formatted
- What observability system I'm using

This means I can:
- Test `isRepairable()` without mocking `SanitizationError`
- Reuse it in other contexts (CLI tools, different services)
- Change error handling without touching domain logic

### 2. Explicit Translation Layer

The `mapReasonToErrorCause()` function is intentional indirection. It enforces that domain reasons and error causes evolve independently. If someone adds a new `UnrepairabilityReason`, the compiler forces them to update the mapper. This prevents the common bug where you add a new failure case but forget to handle it in error logging.

### 3. Type Safety and Self-Documentation

```go
result := isRepairable(doc)
if !result.Repairable {
    // result.Reason is available here, can't be forgotten
    cause := mapReasonToErrorCause(result.Reason)
    // ...
}
```

You can't forget to check the reason: it's right there in the struct. Compare this to returning just a boolean, where the caller has to "remember" what might have gone wrong.

### 4. Observability-Friendly

Because I translate `UnrepairabilityReason` to `SanitizationErrorCause` at the orchestration boundary, the observability layer gets structured, queryable data:

```go
h.metadataRecorder.RecordError(
    time.Now(),
    "sanitizer",
    "Sanitizer.Sanitize",
    mapSanitizationErrorToMetadataCause(*sanitizationError), // <- Uses structured Cause
    err.Error(),
    attrs, // <- buildErrorAttributes can branch on Cause for rich context
)
```

If all failures were just `ErrCauseStructurallyIncorrect`, I'd lose the ability to:
- Build dashboards showing which validation rules fail most often
- Set different alert thresholds for different failure types
- Debug production issues by filtering logs by specific causes

## Addressing Potential Concerns

### "Isn't the boolean in RepairableResult redundant?"

Technically, yes. You could infer it from `Reason == ""`. But keeping it explicit has ergonomic value:

```go
if !result.Repairable {
    // immediately clear what's happening
}
```

versus:

```go
if result.Reason != "" {
    // requires knowing the convention
}
```

The redundancy is a feature, not a bug. It makes the code read more naturally.

### "Why not just use sentinel errors?"

You could define:

```go
var (
    ErrCompetingRoots = errors.New("competing_roots")
    ErrNoStructuralAnchor = errors.New("no_structural_anchor")
)
```

And return these directly. The problem is you lose the boolean answer to "is it repairable?" You'd have to use `errors.Is()` checks at the call site, which is more awkward:

```go
err := validateRepairability(doc)
if errors.Is(err, ErrCompetingRoots) {
    // handle competing roots
} else if errors.Is(err, ErrNoStructuralAnchor) {
    // handle no anchor
}
```

versus:

```go
result := isRepairable(doc)
if !result.Repairable {
    switch result.Reason {
    case ReasonCompetingRoots:
        // handle competing roots
    case ReasonNoStructuralAnchor:
        // handle no anchor
    }
}
```

The latter is clearer and easier to extend.

### "This seems like a lot of ceremony for a simple check"

It would be, if this were just a simple check. But it's not, it's a critical validation point that:
- Gates the entire sanitization pipeline
- Feeds production observability metrics
- Needs to be testable independently
- May be reused in other contexts

The "ceremony" is buying me maintainability, testability, and clear separation between domain logic and infrastructure concerns. In a small script, this would be overkill. In a production service with observability requirements, it's appropriate engineering.

## Lessons Learned

1. **Consider the full context**: What seemed like a simple boolean check was actually feeding a sophisticated observability system. The design needed to account for that.

2. **Domain-orchestration separation matters**: Keeping `isRepairable()` independent of `SanitizationError` made the code more testable and reusable.

3. **Explicit is better than clever**: The mapper function and result struct add lines of code, but they make the system's behavior explicit and type-safe.

4. **Error design is about more than error handling**: Good error design supports debugging, observability, and maintenance, not just reporting failures.

When you're choosing between `(bool, error)`, `error`-only, or a custom result type, think about:
- What downstream systems consume this information?
- Will this logic be reused in different contexts?
- What happens when you need to add a new failure case?
- How will this be tested?

The answers to these questions should guide your design more than following a pattern because it's "idiomatic."
