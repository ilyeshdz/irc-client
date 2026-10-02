# irc-client

An IRC client written in Zig. Two parts: a small IRC library in `src/lib`
and a terminal client in `src/app` built on top of it.

I've been working on this on and off for a while to learn Zig. It works,
it's not finished, and that's fine by me.

## Running it

Needs [Zig](https://ziglang.org/) 0.16.

```sh
zig build run                    # picker
zig build run -- -p home         # --profile NAME
zig build run -- local           # 127.0.0.1:6667
zig build run -- --help          # all options
```

No arguments and you get a picker: your profiles, recent servers, a few
known ones. `n` saves a new connection. Profiles are plain JSON in
`~/.config/irc-client/config`. Bad flags print an error and exit with
code 2.

`/help` lists the commands: join, part, msg, me, nick, topic, names, whois,
who, mode, kick, invite, away, list, raw, quit. Plain TCP only, no TLS.

## Local server

```sh
docker-compose up -d             # Ergo on 6667
zig build run -- local
```

Open a second terminal with another nickname and test things against
yourself.

## The library

`src/lib` is the protocol half: `Message` parses and formats IRC lines,
`IrcClient` connects, sends commands and reads replies. `zig build` builds
it alongside the client.

## Tests

```sh
zig build test
```

## TODO

User tracking, channel state, message history.

Made by [@ilyeshdz](https://github.com/ilyeshdz)
