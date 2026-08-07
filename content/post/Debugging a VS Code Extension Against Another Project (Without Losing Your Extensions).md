---
title: "Debugging a VS Code Extension Against Another Project (Without Losing Your Extensions)"
date: 2026-08-07
draft: false
tags:
    - vscode
    - setup
categories:
    - tech
    - tutorial
summary: "Learn how to debug a VS Code extension against a real project while keeping only the extensions you want available in the Extension Development Host."
description: "Use VS Code profiles and launch arguments to run your extension in a clean debugging environment against another repository, without inheriting unnecessary extensions."
---

When developing a VS Code extension, the normal workflow is straightforward enough: open your extension project, press `F5`, and VS Code launches a second window called the **Extension Development Host**. That second window runs your extension in a clean environment so you can debug it.

The problem is that by default, it opens the extension project itself.

That's not very useful if your extension is supposed to work on another project.

My first thought was to simply open another folder after the Extension Development Host launched. That works, but I quickly ran into another problem: **none of my installed extensions were available**. Testing my extension in that environment wasn't representative of how it would actually be used.

Fortunately, VS Code already has a clean solution for this.

---

## Step 1: Create a dedicated profile

For example I only want to enable Go VS Code Extension. 

Create a new VS Code Profile from **Empty Profile**.

Named it something like:

```text
Go Dev
```

Starting from an empty profile is intentional. I only wanted the extensions relevant for testing my extension.

---

## Step 2: Point the Extension Development Host to your project

Inside your extension project's `.vscode/launch.json`, update the launch arguments:

```json
{
    "type": "extensionHost",
    "request": "launch",
    "name": "Run Extension",
    "args": [
        "/home/myuser/Projects/my-intended-repo-for-the-extension-debugging",
        "--profile",
        "Go Dev"
    ]
}
```

The first argument is the project you actually want to work on.

The second tells VS Code which profile the Extension Development Host should use.

---

## Step 3: Populate the profile

Launch a normal VS Code window.

Switch to the **Go Dev** profile.

Install only the extensions you want available while debugging. In my case, that was simply the Go extension.

Close the window once you're done.

You only need to do this once.

---

## Step 4: Debug normally

Go back to your extension project.

Press `F5`.

Now the Extension Development Host launches:

* your target project instead of the extension source
* your extension under development
* only the extensions installed in the **Go Dev** profile

Exactly what I wanted.  

Instead of maintaining a long list of command-line arguments, I can simply create one profile for each environment and switch between them by changing a single argument in `launch.json`.

Each profile can also have its own extensions, settings, themes, keyboard shortcuts etc.

making it easy to reproduce different user environments.

---

## Final Result

My workflow now looks like this:

**Instance 1:**

```text
VS Code #1
└── Extension source
    ├── Edit code
    ├── Set breakpoints
    └── Press F5
```
**Instance 2:**

```text
VS Code #2 (Extension Development Host)
└── Target Go project
    ├── My extension (debug build)
    ├── Go extension
    └── Nothing else
```

It's a small quality-of-life improvement, but if you're spending a lot of time developing VS Code extensions, it makes the debugging experience much closer to a real-world setup.

---

## Recap

1. Create an empty VS Code Profile.
2. Install only the extensions you need into that profile.
3. Add your target project path and `--profile <profile-name>` to `launch.json`.
4. Debug your extension with `F5`.

You'll get an Extension Development Host running against your actual project with exactly the extensions you want enabled.

Thanks for reading!
