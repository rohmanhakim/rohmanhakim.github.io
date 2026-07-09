---
title: "Go's Delve Suddenly Print `Building .`"
date: 2026-07-09
draft: false
tags:
    - go
    - debugging
categories: 
    - programming
summary: "A short note on why VS Code's Go debugger started printing 'Building .' after upgrading to Delve 1.27.0, and whether it can be disabled."
description: "After upgrading to Go 1.26 and Delve 1.27.0, VS Code's Go debugger began printing 'Building .' before program output. This post explains the cause and why it appears."
---

After upgrading from Go **1.24** to **1.26**, I noticed an extra line appearing every time I debugged a Go program in VS Code:

```text
Building .
Hello World
```

At first I assumed this came from Go itself, but it turns out it doesn't.

The culprit is Delve (`dlv`), the debugger used by the VS Code Go extension. Specifically, I was running Delve 1.27.0.

## What changed?

Interestingly, Delve didn't just *add* this message. It had already been emitting a build status internally. In v1.27.0, a [small change added](https://github.com/go-delve/delve/pull/4340/changes/fd90a48697af0acc4b8827adf868303c2a6a784b) a trailing newline to the message:

The patch essentially changed something like:

```go
fmt.Fprintf(..., "Building %s", program)
```

to

```go
fmt.Fprintf(..., "Building %s\n", program)
```

As a result, VS Code's Debug Console now reliably displays:

```bash
Building .
Hello World
```

instead of just:

```bash
Hello World
```

## Can it be disabled?

As far as I can tell, no.

I couldn't find any VS Code Go extension setting or Delve option to suppress only this message. The available logging options (`showLog`, `trace`, `logOutput`) don't affect it.

## Why I care

I sometimes use Go for studying data structures & algorithms and competitive programming. During debugging, I prefer the console output to contain only my program's output.

When you're repeatedly running tiny programs like:

```go
fmt.Println("Hello World")
```

or printing intermediate values while solving algorithm problems, even a harmless status message adds unnecessary noise.

It's a tiny change, but one that slightly detracts from the clean feedback loop I enjoy when practicing DSA and CP.

Maybe one day Delve will expose a setting to hide informational status messages like this. Until then, `Building .` will be tagging along with every debug session.
