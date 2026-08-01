# irc-client

A small IRC client written in Zig. This is a personal project, made to learn
Zig one step at a time. Nothing fancy, just a simple client that works.

Right now it covers the foundations: connecting to a server, introducing
yourself, sending and receiving messages, and answering `PING` with `PONG` to
stay alive.

## Running it

You'll need [Zig](https://ziglang.org/) installed:

```sh
zig build run
```

## What's next

- Parsing the IRC protocol
- Handling IRC commands and events
- Tracking users and their state
- Maybe becoming a library one day

No promises beyond that. It's a fun learning project, and that's enough.

Made with ❤️ by [@ilyeshdz](https://github.com/ilyeshdz)
