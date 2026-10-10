# irc-client

**irc-client** is an IRC client written from scratch in Zig. I've been working on this project for a while, and I wanted to share it with everyone.

It comes with a small, embedded IRC library written in Zig. For simplicity, it relies on POSIX-only built-in libraries, so it only works on Unix-like systems.

## Install

This client is built with Zig, and we provide prebuilt binaries through GitHub Releases. The recommended way to install it is to manually download the appropriate binary from there.

We provide prebuilt binaries for Linux (ARM and x86_64) as well as macOS. However, as mentioned earlier, Windows is not supported, and I probably won't support it in the future since the project heavily relies on POSIX-only libraries.

## Nightly builds

Unstable builds from `main` are published every Monday at 02:00 UTC as a prerelease on the floating `nightly` tag. Each run overwrites the previous one. Expect breakage, do not use in production. The binary also prints a warning on startup and reports a `nightly-YYYYMMDD-<sha>` version via `--version`.

- Download: [nightly release](../../releases/tag/nightly)
- Trigger one right now without waiting for Monday: Actions -> Nightly -> Run workflow.

## Profiles and autojoin

Profiles live in `~/.config/irc-client/config`. To join channels
automatically after connecting, add a `channels` list to a profile:

```json
{"profiles": [{"name": "home", "nick": "hdz", "realname": "hdz",
  "host": "irc.libera.chat", "port": 6667, "tls": false,
  "favorite": true, "channels": ["#zig", "#rust"]}],
 "recent": [], "last_profile": "home"}
```

Missing keys and non-string entries are ignored, so hand-edited files
keep working.

## License

This project is licensed under the GPL-3.0 license.

> Made with ❤️ by [ilyeshdz](https://github.com/ilyeshdz)
