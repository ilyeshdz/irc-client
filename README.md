# irc-client

A small IRC client written in Zig. This is a personal project, made to learn
Zig one step at a time. Nothing fancy, just a simple client that works.

Right now it covers the foundations: connecting to a server, introducing
yourself, sending and receiving messages, and answering `PING` with `PONG` to
stay alive. MOTD support (commands 375, 372, 376) is implemented.

## Running it

You'll need [Zig](https://ziglang.org/) installed:

```sh
zig build run
```

Without arguments it shows a picker: saved profiles first (last used on top,
favorites starred), then recently used servers, then a few common servers.
Pick a number, or `n` for a new connection (which you can save as a profile).

```sh
zig build run -- --profile home   # connect with a saved profile
zig build run -- local             # quick path to 127.0.0.1:6667
zig build run -- irc.libera.chat  # quick path to another host
```

Profiles and recent servers are stored as JSON in
`~/.config/irc-client/config`.

## Test Server (local IRC)

A Docker Compose setup is provided for a local InspIRCd server:

```sh
# Start the test server (requires Docker)
docker-compose up -d

# Run the client against local server
zig build run
# Then edit src/main.zig to connect to 127.0.0.1:6667 instead of irc.ircnet.com

# Stop the test server
docker-compose down
```

The server runs on ports 6667 (plain) and 6697 (SSL). Configuration and MOTD files are in the project root.

## What's next

- Parsing the IRC protocol
- Handling IRC commands and events
- Tracking users and their state
- Maybe becoming a library one day

No promises beyond that. It's a fun learning project, and that's enough.

Made with ❤️ by [@ilyeshdz](https://github.com/ilyeshdz)
