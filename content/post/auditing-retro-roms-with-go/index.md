---
title: "Auditing Retro ROMs with Go: Building a Hash-Based Identification Tool"
date: 2026-09-06
draft: false
categories:
    - programming
    - projects
tags:
    - programming
    - go
    - retro-gaming
summary: "How I built a Go tool to audit my Retro handheld's ROM collection using content hashing and DAT databases."
description: "Building a Go tool to audit retro ROM collections using content hashing and DAT databases."
---

I have an [Anbernic RG CubeXX](https://anbernic.com/products/rg-cubexx), a retro gaming handheld that came pre-loaded with thousands of ROM files on its microSD card. The ROMs were renamed, mislabeled, or stripped of metadata. I wanted to join [RetroAchievements](https://retroachievements.org/), a platform that tracks achievements for retro games, but it requires specific ROM versions: if your ROM doesn't match their database, achievements won't show up. So I built [`rom-lookup`](https://github.com/rohmanhakim/rom-lookup), a Go tool that identifies ROMs by their content hash and resolves them to canonical names.

## What Are ROMs?

If you're not from the retro gaming world, a quick primer: a **ROM** (Read-Only Memory) is a digital copy of a game cartridge or disc. When someone "dumps" a game from a physical cartridge, they get a binary file — a ROM. These files carry the exact bytes that the original hardware would read.

The problem is that ROM files are often renamed, organized inconsistently, or modified. Two files named `GoldenSun.gba` could be completely different versions of the game — different regions, different dump sources, or even hacked modifications. The filename tells you almost nothing about what's actually inside.

## The Problem

Here's what my ROM collection looked like:

```
GBA/
├── 001 Golden Sun.gba
├── 002 Tekken Advance.gba
├── 003 Crash Bandicoot.gba
└── ...
```

Is `001 Golden Sun.gba` the USA version? Europe? Is it the original dump or a modified ROM? For RetroAchievements compatibility, I need to know the exact version. Renaming the files manually would take forever, and I'd still be guessing.

## The Solution at a Glance

[`rom-lookup`](https://github.com/rohmanhakim/rom-lookup) is a Go tool that answers one question: **what is this ROM file, really?** It has two modes:

- **CLI** — scan files from your terminal and get instant identification
- **Library** — embed the same logic in your own Go programs

```
$ romlookup scan GBA/001\ Golden\ Sun.gba

  [no-intro] Golden Sun (USA, Europe)
    Region:   USA, Europe
    Size:     16,777,216 bytes
    CRC32:    DBEF116C
```

The trick? It doesn't look at the filename at all. It reads the file's **content hash** — a mathematical fingerprint of the actual bytes — and matches it against a database of known ROMs.

## Content Hashing: The Core Idea

If filenames are unreliable, what can we trust? The file contents themselves.

A **hash function** takes an arbitrary amount of data and produces a fixed-size string — a fingerprint. Change even one byte in the input, and the output changes completely. This means two identical files will always produce the same hash, regardless of what they're named.

Three hash algorithms are commonly used in ROM databases:

| Algorithm | Output Size | Speed | Use Case |
|-----------|------------|-------|----------|
| CRC32 | 4 bytes | Very fast | Primary lookup key in No-Intro/Redump |
| MD5 | 16 bytes | Fast | Backup identifier, cross-database matching |
| SHA1 | 20 bytes | Moderate | Used by some Redump disc entries |

**CRC32** (Cyclic Redundancy Check) is a checksum, not a cryptographic hash — it's fast but has a higher chance of collisions (two different files producing the same hash). That's why databases store all three: CRC32 for quick lookups, MD5/SHA1 to disambiguate when CRC32 matches multiple entries.

The lookup flow is simple: compute all three hashes from the ROM file, then search the database by CRC32 first. If multiple entries match, narrow down with MD5 and SHA1.

## DAT Files: The Data Source

The hash database needs to come from somewhere. Fortunately, the retro gaming community maintains several well-known projects that catalog verified ROM dumps:

- **[No-Intro](https://no-intro.org/)** — Tracks cartridge-based ROMs (NES, SNES, GBA, Genesis, etc.). Each entry is verified against a known-good dump.
- **[Redump](http://redump.org/)** — Tracks disc-based ROMs (PlayStation, Dreamcast, CD-i). Focuses on exact disc images.
- **[TOSEC](https://www.tosecdev.org/)** — Covers home computers and arcade systems (Commodore 64, Amiga, arcade boards).

These projects distribute their data as **DAT files** — a plain-text format originally created by [ClrMamePro](https://mamedev.emulab.it/clrmamepro/), a ROM management tool. Every major ROM manager (ClrMamePro, ROMVault, RomCenter) uses this format. It's the de facto standard.

All three databases are freely available via [libretro-database](https://github.com/libretro/libretro-database) on GitHub — no API keys, no rate limits, no paywalls.

Here's what a DAT entry looks like:

```
clrmamepro (
    name "Nintendo - Game Boy Advance"
    version "2026.08.01"
)

game (
    name "Advance Wars (USA)"
    region "USA"
    rom ( name "Advance Wars (USA).gba" size 4194304 crc DBEF116C md5 27F322F5... )
)
```

Each `game` block contains a name, region, and a `rom` entry with the file size, CRC32, and MD5 hash. That's all we need: hash the ROM file, search for a matching CRC32, and we've identified it.

## Implementation Deep Dive

Now that we know *what* we're doing (hash files, search DAT databases), let's look at *how* it works in Go.

### Parsing DAT Files

The DAT format uses nested blocks with quoted strings — not JSON, not YAML, not XML. Parsing it means handling `(`, `)`, `"`, and whitespace in the right order. I implemented a state-machine tokenizer:

```go
func Parse(raw []byte) ([]Game, error) {
    src := string(raw)
    games := []Game{}

    // Skip header block (clrmamepro metadata)
    if strings.HasPrefix(src, "clrmamepro") {
        rest, _ := skipBlock(src)
        src = rest
    }

    // Parse game blocks
    for strings.HasPrefix(src, "game") {
        inner, rest, _ := extractBlock(src)
        game, _ := parseGameFields(inner)
        games = append(games, game)
        src = rest
    }
    return games, nil
}
```

The `skipBlock` and `extractBlock` functions track parenthesis nesting and extract the content between matching `(` and `)`. It's not glamorous, but it's reliable.

### Single-Pass Hashing

Go's `io.MultiWriter` is the key to fast hashing. It lets you write to multiple `io.Writer` objects simultaneously — so one pass through the file computes all three hashes at once:

```go
func Hash(r io.Reader) (HashResult, error) {
    crc := crc32.NewIEEE()
    m := md5.New()
    s := sha1.New()

    multi := io.MultiWriter(crc, m, s)
    n, err := io.Copy(multi, r)
    // ...
}
```

The key detail: we never load the full file into memory. A 600MB PS1 disc image hashes in under a second because `io.Copy` streams the data through the hash writers in chunks. This gives us ~500-700 MB/s on modern hardware.

If you've used `io.MultiWriter` before, it's probably for combining `os.Stdout` and a log file. Using it for parallel hashing is a neat trick — same API, different purpose.

### Magic Bytes Detection

Sometimes you need to identify a ROM file before hashing it — for example, to determine which platform it belongs to. **Magic bytes** are specific byte sequences at fixed offsets in the file that act as a file-type signature:

```go
const (
    MagicNES       = []byte{0x4E, 0x45, 0x53, 0x1A} // "NES\x1A"
    MagicGBA       = []byte{0xEE, 0x00, 0x00, 0xEA} // ARM branch instruction
    MagicMegaDrive = []byte("SEGA GENESIS")          // at offset 0x100
)
```

This is the same concept as the `#!` magic bytes at the start of shell scripts, or the `%PDF` header in PDF files. Every file format has its own signature — if you know where to look, you can identify the format without relying on the file extension.

Not every system has reliable magic bytes though. CDI, ISO, and PS1 BIN files don't have consistent signatures. For those, you fall back on extension-based detection or folder context (e.g., "everything in the `/PS1/` folder is probably a PlayStation disc image").

## Using rom-lookup

### CLI Usage

First, download the database (one-time setup):

```bash
romlookup update
```

This fetches ~100MB of DAT files from No-Intro, Redump, and TOSEC. Subsequent updates are fast because it only downloads files that changed (more on that below).

Then scan a ROM:

```bash
$ romlookup scan GBA/001\ Golden\ Sun.gba

  [no-intro] Golden Sun (USA, Europe)
    Region:   USA, Europe
    Size:     16,777,216 bytes
    CRC32:    DBEF116C
```

Or scan an entire directory:

```bash
$ romlookup scan-dir GBA/

  ✓ 001 Golden Sun.gba         → Golden Sun (USA, Europe)
  ✓ 002 Tekken Advance.gba     → Tekken Advance (USA, Europe)
  ✗ 003 Bootleg Special.gba    ← not in database
  ...

  Found 953 files, 941 identified, 12 unrecognized.
```

The `verify` command shows what needs attention:

```bash
$ romlookup verify GBA/

  Verified: 941/953 ROMs match database
  Unknown: 12 ROMs

  Unknown ROMs (not in database):
  ? Bootleg Special.gba
  ? Hack Rom (Unl).gba
  ...
```

### Library Usage

For Go programs, the library provides a clean API:

```go
import (
    "github.com/rohmanhakim/rom-lookup/pkg/romlookup"
    "github.com/rohmanhakim/rom-lookup/pkg/romlookup/hash"
)

// Load the database into memory
index, _ := romlookup.LoadDirMulti("~/.config/romlookup/dat/")

// Hash a ROM file
result, _ := hash.HashFile("/path/to/rom.gba")

// Look up by CRC32
game := index.Best(result.CRC32)
if game != nil {
    fmt.Printf("%s [%s]\n", game.Name, game.ROM.CRC32)
    // Output: Golden Sun (USA, Europe) [DBEF116C]
}
```

The library is split into focused packages:

| Package | Purpose |
|---------|---------|
| `dat` | Parse DAT files, build hash index |
| `hash` | Compute CRC32, MD5, SHA1 |
| `platform` | Detect system from extension/magic bytes |

## Engineering Decisions

### SHA-Based Version Tracking

The DAT files are large (~100MB total). Re-downloading everything on every run would be wasteful. Instead, I track the SHA hash of each file on GitHub:

```go
type Metadata struct {
    Sources map[string]map[string]string `json:"sources"`
    // sources["no-intro"]["Nintendo - Game Boy Advance.dat"] = "77a022f..."
}
```

On update, the tool:
1. Fetches the GitHub API to get current file SHAs
2. Compares with the local `sha.json`
3. Downloads only files where the SHA changed

First update takes ~60s. Subsequent updates take less than a second.

### Caching and Read-Only Systems

The CLI downloads ~100MB of DAT files on first run, stored locally at `~/.config/romlookup/dat/`. On subsequent runs, it checks GitHub for changes and only re-downloads modified files.

But the *library* doesn't handle caching at all. This was a deliberate design decision. The library is meant to be embedded in different environments:

- Desktop applications (writable cache)
- Docker containers (read-only filesystem)
- Web servers (no local storage)
- Embedded devices (limited storage)

Instead of forcing a cache strategy, the library lets the client decide where the data comes from:

```go
// Client provides the data source
index, _ := dat.LoadDirMulti("/path/to/dat/files")
```

For a Docker deployment, you can bake the DAT files into the image at build time:

```dockerfile
# Build stage: download DATs
FROM golang:1.22 AS builder
RUN romlookup update

# Runtime stage: read-only
FROM gcr.io/distroless/static
COPY --from=builder /root/.config/romlookup/dat/ /data/dat/
ENTRYPOINT ["/romlookup", "--dat-dir", "/data/dat/"]
```

The CLI handles caching because it's a concrete application with a specific use case. The library stays flexible for other contexts.

## What I Learned

### io.MultiWriter is underrated

Most developers know it for combining writers, but using it to compute multiple hashes in a single pass is elegant and efficient. One `io.Copy`, three hashes, no extra allocations.

### Typed errors make error handling clean

```go
var pe *dat.ParseError
if errors.As(err, &pe) {
    fmt.Println(pe.File, pe.Msg)
}
```

Instead of string-matching error messages, callers can handle specific failure modes with type assertions. This pattern is worth reaching for whenever a library has distinct error categories.

### Fuzz testing catches parser bugs

Adding `FuzzParse` found edge cases I never thought of:
- `"game()"` — empty game block
- `"()()"` — nested empty parentheses
- Unterminated strings and blocks

The parser never panics now, regardless of input. If you're writing a parser for any custom format, fuzz it early — Go's built-in fuzzing support (`go test -fuzz`) makes this almost effortless.

## Results

I scanned my RG CubeXX's ROM collection:

| System | Total | Identified | Match Rate |
|--------|-------|------------|------------|
| Game Boy | 729 | 709 | 97% |
| Mega Drive | 649 | 603 | 93% |
| Game Boy Advance | 952 | 66 | 7% |

The GBA match rate was surprisingly low. Many ROMs appear to be from different dump sources or modified versions — the file bytes don't match any known-good dump in No-Intro. This is actually useful information: it tells me exactly which GBA ROMs need to be replaced for RetroAchievements compatibility, rather than guessing which ones are "wrong."

## What's Next

- Better GBA ROM detection (handling different dump sources and versions)
- Direct RetroAchievements integration (checking compatibility automatically)
- ROM renaming based on audit results

The project is open source: [github.com/rohmanhakim/rom-lookup](https://github.com/rohmanhakim/rom-lookup)
