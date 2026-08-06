---
title: "Fixing PATH issue in VS Code Terminal"
date: 2026-08-06
draft: false
tags:
    - vscode
    - terminal
    - path
    - linux
    - troubleshooting
    - shell
    - bash
categories:
    - tech
    - tutorial
summary: "Quick fix for when a CLI tool works in your regular terminal but fails with 'command not found' in VS Code's integrated terminal. The issue is bash's early return for non-interactive shells, and the fix is moving PATH exports before that return."
description: "VS Code's integrated terminal runs a non-interactive login shell, which hits bash's early return before your PATH exports run. Move PATH exports to the top of .bashrc, before the 'case $- in ... return;; esac' block."
---

I ran into this recently. A CLI tool (`bun` in my case) works fine in my regular terminal. Open VS Code, run it in the integrated terminal, and:

```
bun: command not found
```

Seems like a PATH issue, but the fix isn't what I expected.

---

## What's actually happening

VS Code's integrated terminal runs `bash -l -c '...'` — a **non-interactive login shell**.

Your `.bashrc` probably looks like this (standard Ubuntu/Debian default):

```bash
# ~/.bashrc

# If not running interactively, don't do anything
case $- in
    *i*) ;;
      *) return;;
esac

# ... 100+ lines of aliases, functions, etc ...

# Tool PATH exports at the bottom
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"
export PATH="$HOME/.local/bin:$PATH"
# ... etc ...
```

The `case $- in ... return;; esac` block at the top exits early for **non-interactive shells**. Your PATH exports at the bottom never run. VS Code's terminal is non-interactive, so it gets none of them.

---

## The fix: move PATH exports before the early return

Edit `~/.bashrc` and move **all PATH exports you need everywhere** to the **top**, before the interactive check:

```bash
# ~/.bashrc

# PATH exports FIRST — runs for ALL shells (interactive and non-interactive)
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"
export PATH="$HOME/.local/bin:$PATH"
export PATH="$HOME/go/bin:$PATH"
# ... any other PATH additions ...

# If not running interactively, don't do anything
case $- in
    *i*) ;;
      *) return;;
esac

# ... rest of your .bashrc (aliases, prompt, etc.) ...
```

That's it. Now when VS Code runs `bash -l -c '...'`, it :

1. sources `.bash_profile` 
2. sources `.bashrc` 
3. sets PATH 
4. hits early return. 

Everything works.

---

## Clean up `.bash_profile` 

If your `.bash_profile` has duplicate PATH exports, remove them. It only needs to source `.bashrc`:

```bash
# ~/.bash_profile
# Source .bashrc to get aliases and functions (includes PATH exports)
if [ -f ~/.bashrc ]; then
    . ~/.bashrc
fi
```

So it has single source of truth.

---

## Why does this early return exist?

That `case $- in ... return;; esac` block isn't something you added. It comes from the **default Debian/Ubuntu skeleton `.bashrc`** (in `/etc/skel/.bashrc`), copied to your home directory when your user account was created.

Its purpose: performance.

When bash runs non-interactively (scripts, `bash -c`, SSH commands, VS Code terminal), it still sources `.bashrc`. The early return skips all the interactive-only stuff:

- Prompt configuration (`PS1`, colors, terminal titles)
- Aliases (`ls --color=auto`, etc.)
- Completion setup (`bash-completion`)
- Key bindings
- History settings

These are useless (or broken) in non-interactive shells. Skipping them makes script startup faster.

**The mismatch:** The skeleton assumes PATH setup happens in `.profile` or `.bash_profile` (login shells), not `.bashrc`. But modern tools (`nvm`, `mise`, `bun`, `pyenv`, etc.) tell you to add to `.bashrc`, and users just append them at the end, after the early return.

This is a decades-old convention that predates modern version managers and per-user tool installations.

---

## Why this confuses a lot of people

| Shell type | Sources `.bashrc`? | Hits early return? | Gets PATH exports? |
|------------|-------------------|-------------------|-------------------|
| Regular terminal (interactive) | Yes | No (has `i` in `$-`) | Yes (bottom exports run) |
| VS Code terminal (`bash -l -c`) | Yes (via `.bash_profile`) | Yes (no `i` in `$-`) | No (bottom exports skipped) |
| Scripts (`#!/bin/bash`) | No | N/A | No |

The issue comes from interactive shells skipping the early return. Non-interactive shells (VS Code, CI, scripts) hit it every time.

---

## Verification

```bash
# Test non-interactive login shell (what VS Code uses)
bash -l -c 'which your-tool && your-tool --version'

# Should output the tool path and version
```

If that works, VS Code's terminal will work too. Restart VS Code to pick up the change.

---

## This applies to any tool

Not just one specific tool. **Any PATH export that needs to work in VS Code terminal, CI, or scripts** should go before the early return in `.bashrc`, or in `.bash_profile`/`.profile` directly.

Common examples:

- Language version managers: `mise`, `rtx`, `nvm`, `fnm`, `volta`, `pyenv`, `rbenv`, `sdkman`
- Language toolchains: Go (`$HOME/go/bin`), Rust (`$HOME/.cargo/bin`), Bun (`$HOME/.bun/bin`)
- Package managers: `pipx` (`$HOME/.local/bin`), `cargo`, `npm` global bins
- Custom bins: `$HOME/bin`, `$HOME/.local/bin`
- Kubernetes: `kubectl` plugins, `krew` (`$HOME/.krew/bin`)
- Cloud CLIs: `aws`, `gcloud`, `az` completions and plugins

Put them at the top of `.bashrc`, or in `.bash_profile` if you want them only for login shells.

---

## TL;DR

```bash
# ~/.bashrc — put PATH exports HERE (before the early return)
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"
export PATH="$HOME/.local/bin:$PATH"
export PATH="$HOME/go/bin:$PATH"
# ... etc ...

# If not running interactively, don't do anything
case $- in
    *i*) ;;
      *) return;;
esac
# ... rest of file ...
```

```bash
# ~/.bash_profile — just source .bashrc
if [ -f ~/.bashrc ]; then . ~/.bashrc; fi
```

Restart VS Code. Done.

---

Thanks for reading!
