# irc-client

A small IRC client in Zig. It's a side project for learning Zig and for
remembering what chatting on the internet used to feel like.

No frameworks, no dependencies. Just sockets and the IRC protocol.

## Running it

Needs [Zig](https://ziglang.org/):

```sh
zig build run                  # picker with profiles and some common servers
zig build run -- --profile home
zig build run -- local         # local test server
```

First launch shows a small picker: your saved profiles, then recently used
servers, then a few well-known ones. Pick a number, or `n` to save a new
connection as a profile. Profiles live in `~/.config/irc-client/config` as
plain JSON.

In the client, `/help` lists what's implemented: joining channels, private
messages, topics, whois, kicks, modes, away. Your own messages echo back, and
server errors show up instead of disappearing.

## Local server

There's a docker compose file in the repo so you don't have to bother a real
network while hacking:

```sh
docker-compose up -d    # Ergo on port 6667
zig build run -- local
```

Open a second terminal with another nickname and you can test messaging,
kicks, invites and topics against yourself.

## TODO

User tracking, channel state, message history. Possibly splitting the
protocol handling into its own library at some point.

Made by [@ilyeshdz](https://github.com/ilyeshdz)