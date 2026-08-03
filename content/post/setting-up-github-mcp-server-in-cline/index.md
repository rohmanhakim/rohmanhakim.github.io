---
title: "Setting Up GitHub MCP Server in Cline"
date: 2026-08-03
draft: false
tags:
    - ai
    - cline
    - mcp
    - github
    - docker
    - agentic-coding
    - vscode
    - setup
categories:
    - tech
    - tutorial
summary: "Step-by-step guide to setting up the GitHub MCP server in Cline, giving your AI coding agent direct access to read and analyze GitHub repositories."
description: "Learn how to connect the GitHub MCP server to Cline in VS Code using Docker or remote OAuth, so your AI coding agent can read dependency source code directly from GitHub."
---

If you've been following along with agentic coding in Cline (I wrote about [setting up a free Cline + OpenRouter workflow](/post/running-agentic-coding-for-free-my-openrouter-plus-cline-setup/) earlier), you've probably hit this limitation by now: Cline only knows what's in your local project files. It can read your code, write new code, run tests etc. all great, but the moment you need it to understand something about a *dependency* (a library your project imports or a framework you're building on top of) it's stuck. It either guesses from what's available locally, or making you guide it by posting the information retrieved from the dependency's girhub repo, or you end up copying snippets into your project just so the model can see them.

I ran into this while working on a Go project that depends on a few libraries hosted on GitHub. When debugging a weird interaction between my code and a dependency's internals, I wanted Cline to just... go read the dependency's source. Trace a function, check how it handles edge cases, understand the data flow. Without me manually copy-pasting files around.

That's what the GitHub MCP server solves. It connects Cline directly to GitHub's platform, so the model can read repositories, browse code files, search across repos, and more using natural language. This post walks through exactly how to set it up.

> There are many other things the GitHub MCP server enables like managing issues, creating pull requests, monitoring GitHub Actions, analyzing security alerts etc. but this post focuses on the setup and my specific use case: reading and analyzing dependency source code. The other capabilities are there once you have it running.

---

## What is MCP?

**MCP (Model Context Protocol)** is a standard that lets AI tools like Cline connect to external services. Think of it as a plugin system: Cline on its own can work with your local files, but through MCP servers it can reach out to external platforms and data sources.

The **GitHub MCP server** is one such service. It gives Cline access to GitHub's API: reading repos, browsing file contents, searching code, and more. Once it's connected, you can ask Cline things like "go read the source code of this library on GitHub and explain how this function works" and it can actually do it.

---

## Prerequisites

Before starting, make sure you have:

- **Docker** installed and running (for the local setup)
- A **GitHub account** with a Personal Access Token (we'll create one in the steps below)
- **VS Code** with the **Cline extension** installed ([see my earlier post](/post/running-agentic-coding-for-free-my-openrouter-plus-cline-setup/) if you haven't set that up yet)

There are two ways to connect the GitHub MCP server to Cline: **local** (running via Docker on your machine) and **remote** (hosted by GitHub, connected via OAuth). I'll cover both.

---

## Part 1: Local Setup (Docker + PAT)

This is the method I'm using. It runs the GitHub MCP server as a Docker container on your machine, authenticated with a GitHub Personal Access Token.

### Step 1: Create a GitHub Personal Access Token

Go to [github.com/settings/personal-access-tokens/new](https://github.com/settings/personal-access-tokens/new) and create a new fine-grained token.

Under **Repository access**, select the repositories you want Cline to be able to read. You can pick specific repos or grant access to all repositories you own. Then, under **Permissions**, grant these repository-level permissions:

- **Contents** (read): lets Cline read source code files from the repository
- **Metadata** (read): lets Cline access repository metadata (name, description, etc.)
- **Issues** (read): optional, useful if you want Cline to read issues
- **Pull requests** (read): optional, useful if you want Cline to read pull requests

Give it a descriptive name like `cline-mcp`, and set an expiration that works for you. Once created, **copy the token immediately** because GitHub will not show it to you again.

> **Security note:** This token gives read access to your repositories. Treat it like a password. Don't commit it to version control, and consider using environment variables or a secrets manager if you work across multiple machines.

### Step 2: Pull the Docker Image

The GitHub MCP server is distributed as a Docker image. Pull it once:

```bash
docker pull ghcr.io/github/github-mcp-server
```

This downloads the latest image to your machine. You only need to do this once (or when you want to update to a newer version).

### Step 3: Configure Cline

The configuration lives in Cline's MCP settings file. The path depends on your system, but on Linux it's typically:

```
~/.config/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json
```

Open this file and add the GitHub MCP server configuration. If the file already has other servers in it, just add the new entry alongside them:

```json
{
  "mcpServers": {
    "github.com/github/github-mcp-server": {
      "command": "docker",
      "args": [
        "run",
        "-i",
        "--rm",
        "-e",
        "GITHUB_PERSONAL_ACCESS_TOKEN",
        "ghcr.io/github/github-mcp-server"
      ],
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "your-token-here"
      },
      "disabled": false,
      "autoApprove": []
    }
  }
}
```

Replace `your-token-here` with the Personal Access Token you created in Step 1.

A few things to note:

- **`command`** and **`args`**: This tells Cline to start the MCP server by running a Docker container. The `-i` flag keeps stdin open (needed for the MCP protocol), and `--rm` removes the container when it stops.
- **`env`**: The token is passed as an environment variable to the container. It's never written to disk inside the container itself.
- **`disabled: false`**: The server is active immediately.
- **`autoApprove: []`**: Cline will ask for your approval before using any MCP tool. You can configure specific tools to auto-approve later if you want.

Save the file. Cline will automatically detect the new server configuration and start the container.

### Step 4: Verify It Works

Once Cline connects to the server, you should see a new section in the MCP tools area with GitHub-related tools available. To quickly verify the connection is working, you can ask Cline something like:

> _"Use the get_me GitHub tool to check my authentication."_

If it returns your GitHub username and profile info, the server is up and running.

---

## Part 2: Remote Setup (OAuth)

If you don't want to deal with Docker, GitHub hosts a remote version of the MCP server. It uses OAuth for authentication which require you to you log in through your browser on first use, and the token is kept in memory only.

The configuration for Cline looks like this:

```json
{
  "mcpServers": {
    "github.com/github/github-mcp-server": {
      "type": "http",
      "url": "https://api.githubcopilot.com/mcp/",
      "disabled": false,
      "autoApprove": []
    }
  }
}
```

On first use, it'll open a browser window for you to authenticate with GitHub. After that, it'll  just works.

### When to use which

| | Local (Docker) | Remote (OAuth) |
|---|---|---|
| **Auth** | Personal Access Token | OAuth (browser-based) |
| **Requires Docker** | Yes | No |
| **Token stored** | In your config file | In memory only |
| **Works offline** | No (needs GitHub API) | No (needs GitHub API) |
| **Best for** | CI/CD, headless environments, fine-grained control | Simpler setup, no token management |

I prefer the local Docker setup because I want fine-grained control over the token scopes, and I'm already running Docker on my machine anyway. But the remote option is perfectly valid if you want something simpler.

---

## In Practice: Reading Dependency Source Code

Here's where this gets useful. Let me walk through the kind of thing I actually use this for.

Say my Go project depends on a library, and I'm hitting a bug where a function from that library behaves differently than I expect. Before the GitHub MCP server, my options were:

1. Open the library's repo in a browser, navigate to the file, read it myself, and explain it to Cline
2. Copy the relevant source files into my project as reference
3. Just guess and iterate until it works

None of those are great. Now, I can just ask Cline directly:

> _"Read the file `pkg/runner/executor.go` from the repo `someorg/somelib` on the `main` branch. I need to understand how it handles context cancellation when the parent context is done."_

Cline uses the GitHub MCP server's `get_file_contents` tool to fetch the file directly from GitHub, reads the code, and can then explain the behavior, trace the logic, and suggest fixes without me having to manually bring the source code into the conversation.

This works for any public repo, and for any private repo your token has access to. It also works across branches and tags, so you can read the exact version of a dependency your project uses.

A few other things I've found myself asking:

- _"What does the error handling look like in `internal/storage/writer.go` in `someorg/somelib`?"_
- _"Search for all usages of `context.WithTimeout` in the `someorg/somelib` repo."_
- _"Show me the directory listing of `pkg/` in `someorg/somelib` so I can understand how it's structured."_

The model can then take what it learned from the dependency's source and apply it directly to the code in my local project. It's a significant workflow improvement when you're dealing with libraries that aren't well-documented or whose behavior you need to verify at the source level.

---

## What Else Can You Do?

Reading code is just one capability. Once the GitHub MCP server is connected, Cline has access to a broad set of GitHub tools: managing issues, creating and reviewing pull requests, monitoring GitHub Actions workflows, searching code across repositories, and more.

These capabilities are all there if you want to explore them, but they're outside the scope of this post. The setup process is the same regardless of which tools you end up using.

---

## Security Considerations

A few things worth keeping in mind:

- **Token permissions:** Only grant the permissions you actually need. For reading public repos, you can skip repository-level permissions entirely. For private repos, grant the minimum permissions required, which **Contents (read)** is usually enough for the use case described in this post.
- **Read-only mode:** The GitHub MCP server supports a read-only flag (`--read-only` as a Docker arg or `GITHUB_READ_ONLY=1` as an env var). This prevents Cline from making any modifications through GitHub. Useful if you only want the read capabilities.
- **Token storage:** In the local Docker setup, the token sits in your `cline_mcp_settings.json` file. Make sure this file isn't committed to version control. If you're working in a team, use environment variables instead of hardcoding the token.

---

## Recap

1. Create a fine-grained GitHub Personal Access Token at [github.com/settings/personal-access-tokens/new](https://github.com/settings/personal-access-tokens/new) with **Contents (read)** permission
2. Pull the Docker image: `docker pull ghcr.io/github/github-mcp-server`
3. Add the server configuration to your `cline_mcp_settings.json` file with your token
4. Restart or let Cline pick up the new config, and verify with a `get_me` check
5. Start asking Cline to read and analyze code from GitHub repos

Alternatively, use the remote OAuth setup. Add a single entry to your MCP settings, authenticate through the browser, and skip Docker entirely.

---

If you've already got Cline running, adding the GitHub MCP server is a quick extension that opens up a lot of possibilities. For me, the ability to have Cline read and reason about dependency source code directly has been the most practical benefit and no more copy-pasting files or explaining library internals to the model manually.

Thanks for reading!