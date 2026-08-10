---
title: "Running Worms W.M.D Natively on PikaOS Linux"
date: 2026-08-10
draft: false
tags:
    - games
    - linux
categories: 
    - troubleshooting
summary: "How I got the native Linux build of Worms W.M.D running on Debian-based Linux using Steam Runtime libraries and a launch wrapper."
description: "A practical troubleshooting guide for running the 2016 native Linux Worms W.M.D build on modern Debian-based systems by combining Steam Runtime libraries, Debian multiarch paths, and an LD_PRELOAD wrapper."
---

I recently tried to get the native Linux version of **Worms W.M.D** running on my Linux desktop. The game is available on [Steam](https://store.steampowered.com/app/327030/Worms_WMD/) with a native Linux build, so there is no reason to use Proton just to get the game running.

Unfortunately, the Linux build is from 2016, and some of its library dependencies are old enough that they no longer line up with a modern Debian-based system.

I eventually got it working by combining the old libraries provided by Steam Runtime with a couple of libraries from my system.

This is how I did it.

## The problem

After installing Worms W.M.D from Steam and launching the native Linux version, the game failed immediately.

The interesting part is that the game itself is not particularly broken. The problem is its runtime dependencies.

There is an [Arch Linux forum thread about exactly this problem](https://bbs.archlinux.org/viewtopic.php?id=307036), where users investigated the dependencies of the Linux build and eventually found a way to run it on modern Arch Linux.

The important discovery was that Steam already ships a number of old libraries through **Steam Runtime**.

The game therefore doesn't necessarily need us to install ancient versions of everything system-wide.

---

## Missing `libtheora`

The first missing libraries I encountered were:

```text
libtheoraenc.so.1
libtheoradec.so.1
```

I installed them from the distribution packages:

```bash
sudo apt install libtheoraenc1
sudo apt install libtheoradec1
```

After that, those dependencies were resolved.

I deliberately didn't try to solve this by creating symlinks between different versions of the libraries. A shared library's SONAME represents an ABI, so simply making:

```text
libfoo.so.1 -> libfoo.so.2
```

isn't necessarily safe.

---

## The Steam Runtime

The next interesting part was discovering that Steam already contains many of the old libraries that Worms expects.

For example, Steam provides:

```text
libidn.so.11
libgcrypt.so.11
librtmp.so.0
libcurl-gnutls.so.4
libdbus-1.so.3
```

The relevant Steam Runtime directory on my installation is:

```text
~/.local/share/Steam/ubuntu12_32/steam-runtime
```

The Arch forum solution uses `LD_PRELOAD` to force the game to use these libraries.

However, there was one important difference between the Arch setup and mine.

---

## Debian's multiarch library path

The Arch solution uses:

```text
/usr/lib/libwavpack.so.1
```

But my system is [PikaOS](https://wiki.pika-os.com/en/home) (Debian sid-based) and uses the multiarch directory:

```text
/usr/lib/x86_64-linux-gnu/
```

So the actual library on my system is:

```text
/usr/lib/x86_64-linux-gnu/libwavpack.so.1
```

This distinction turned out to be important.

When I used the original Arch path, the game failed with:

```text
error while loading shared libraries:
libwavpack.so.1: cannot open shared object file
```

Changing the path to:

```text
/usr/lib/x86_64-linux-gnu/libwavpack.so.1
```

fixed that particular problem.

---

## `libidn.so.11`

There was one more old dependency I couldn't directly satisfy with the current system library.

My system has:

```text
libidn.so.12
```

while the application expects:

```text
libidn.so.11
```

I created the following symlink:

```bash
sudo ln -s \
    /usr/lib/x86_64-linux-gnu/libidn.so.12 \
    /usr/lib/x86_64-linux-gnu/libidn.so.11
```

This worked for me.

This is worth calling out because **SONAME compatibility is not guaranteed merely because two libraries have similar names**. In general, replacing an older ABI with a newer one using a symlink is something to approach cautiously. In this particular case, it allowed Worms W.M.D to start on my system.

---

# The wrapper script

At this point I needed a way to inject the old libraries into the game's process without modifying the system globally.

I created `MyRun.sh` in the Worms W.M.D installation directory:

```text
~/.local/share/Steam/steamapps/common/WormsWMD/MyRun.sh
```

The final version is:

```bash
#!/bin/bash

_libraries=(
    lib/libQt5*.so.5
    /usr/lib/x86_64-linux-gnu/libwavpack.so.1
    "$STEAM_RUNTIME"/amd64/lib/x86_64-linux-gnu/libdbus-1.so.3
    "$STEAM_RUNTIME"/usr/lib/x86_64-linux-gnu/libcurl-gnutls.so.4
    "$STEAM_RUNTIME"/usr/lib/x86_64-linux-gnu/libidn.so.11
    "$STEAM_RUNTIME"/lib/x86_64-linux-gnu/libgcrypt.so.11
    "$STEAM_RUNTIME"/usr/lib/x86_64-linux-gnu/librtmp.so.0
)

export LD_PRELOAD="${_libraries[@]}"

unset QT_QPA_PLATFORM

exec "$@" > "$HOME/worms-stdout.log" 2> "$HOME/worms-stderr.log"
```

Then:

```bash
chmod +x MyRun.sh
```

There are two particularly important parts here.

### `LD_PRELOAD`

This forces the game to load the libraries listed above before its normal dependency resolution.

The Qt libraries are included from the game's own `lib` directory:

```bash
lib/libQt5*.so.5
```

while the older system dependencies come from either the local system or Steam Runtime.

### `unset QT_QPA_PLATFORM`

This one took some debugging.

On my desktop, `QT_QPA_PLATFORM` was set in the environment. The value was incompatible with the old Qt version bundled with Worms W.M.D.

Removing it before starting the game avoids that problem:

```bash
unset QT_QPA_PLATFORM
```

---

# Configuring Steam

The important part is **how the script is launched**.

In:

**Steam → Worms W.M.D → Properties → General → Launch Options**

I use:

```text
./MyRun.sh %command%
```

Steam then effectively constructs this chain:

```text
Steam
  ↓
MyRun.sh
  ↓
steam-launch-wrapper
  ↓
SteamLinuxRuntime
  ↓
Worms W.M.Dx64
```

I initially wasn't sure whether Steam was actually executing my wrapper script, so I temporarily replaced it with a small debugging script that wrote to:

```text
/tmp/worms-test.log
```

That confirmed that Steam was invoking the script correctly.

The resulting command line showed:

```text
steam-launch-wrapper
    ↓
reaper
    ↓
SteamLinuxRuntime_soldier
    ↓
scout-on-soldier-entry-point-v2
    ↓
Worms W.M.Dx64
```

That was useful because it eliminated Steam's launch configuration as a possible problem.

---

# Debugging with `LD_PRELOAD`

The first time I got the wrapper running, the stderr log contained a lot of messages like:

```text
ERROR: ld.so: object '...' from LD_PRELOAD cannot be preloaded
(wrong ELF class: ELFCLASS64): ignored.
```

At first this looked like a serious problem.

It wasn't.

Steam's launch chain includes 32-bit components, while the libraries we're preloading are 64-bit. Those 32-bit processes therefore complain when they inherit the 64-bit `LD_PRELOAD`.

The important error was further down:

```text
Worms W.M.Dx64:
error while loading shared libraries:
libwavpack.so.1: cannot open shared object file
```

That was what led me to the Debian multiarch path:

```text
/usr/lib/x86_64-linux-gnu/libwavpack.so.1
```

After correcting that path, the game launched.

---

# Logging

The wrapper also redirects the game's output:

```bash
exec "$@" > "$HOME/worms-stdout.log" 2> "$HOME/worms-stderr.log"
```

So when something goes wrong, I can check:

```bash
cat ~/worms-stdout.log
cat ~/worms-stderr.log
```

The stderr log was particularly useful during the troubleshooting process because it exposed the missing libraries instead of just having Steam silently return to the Play button.

---

# Final setup

The resulting setup is quite small:

```text
WormsWMD/
├── MyRun.sh
├── Run.sh
├── Worms W.M.Dx64
├── lib/
├── platforms/
└── ...
```

Steam Launch Options:

```text
./MyRun.sh %command%
```

Installed packages:

```bash
sudo apt install libtheoraenc1
sudo apt install libtheoradec1
```

And the additional compatibility symlink:

```bash
sudo ln -s \
    /usr/lib/x86_64-linux-gnu/libidn.so.12 \
    /usr/lib/x86_64-linux-gnu/libidn.so.11
```

The final wrapper:

```bash
#!/bin/bash

_libraries=(
    lib/libQt5*.so.5
    /usr/lib/x86_64-linux-gnu/libwavpack.so.1
    "$STEAM_RUNTIME"/amd64/lib/x86_64-linux-gnu/libdbus-1.so.3
    "$STEAM_RUNTIME"/usr/lib/x86_64-linux-gnu/libcurl-gnutls.so.4
    "$STEAM_RUNTIME"/usr/lib/x86_64-linux-gnu/libidn.so.11
    "$STEAM_RUNTIME"/lib/x86_64-linux-gnu/libgcrypt.so.11
    "$STEAM_RUNTIME"/usr/lib/x86_64-linux-gnu/librtmp.so.0
)

export LD_PRELOAD="${_libraries[@]}"

unset QT_QPA_PLATFORM

exec "$@" > "$HOME/worms-stdout.log" 2> "$HOME/worms-stderr.log"
```

And that's it.

## Conclusion

The interesting thing about this problem is that **the native Linux build of Worms W.M.D isn't fundamentally unusable on a modern Linux distribution**. It is mostly a matter of dealing with the dependency environment it was built for in 2016.

Steam Runtime is particularly useful here because it still contains many of the older libraries required by the game.

The Arch Linux forum thread provided the key insight, but the solution needed a small adjustment for my Debian-based system: specifically, using Debian's multiarch path for `libwavpack.so.1`.

So the final solution is essentially:

```text
old Worms W.M.D binary
        +
game's bundled Qt libraries
        +
old libraries from Steam Runtime
        +
Debian's libwavpack
        ↓
      works
```

And importantly, I can run the native Linux version directly through Steam without Proton.

[Arch Linux BBS — Problems with Worms WMD](https://bbs.archlinux.org/viewtopic.php?id=307036&utm_source=chatgpt.com)
