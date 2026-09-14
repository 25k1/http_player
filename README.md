# http-player

A small HTTP server that plays sound files on demand.

Start it once, then trigger sounds from anything that can make an HTTP request - a script, a build hook, a home automation rule, another machine on your network.

```sh
curl -X POST http://127.0.0.1:57919/play \
     -H "Content-Type: application/json" \
     -d '{"file_name": "done.wav", "volume": 60}'
```

Written in Zig, with [miniaudio](https://github.com/mackron/miniaudio) for playback.

## API

All endpoints take and return JSON.

### `POST /play`

```json
{ "file_name": "done.wav", "volume": 60 }
```

`file_name` is a path relative to the sounds directory, so sounds can be organised into subdirectories: `"done.wav"`, `"alerts/error.wav"`.

`volume` is optional, `0`–`100` percent, default `100`. It is a linear gain applied to that sound only.

```json
{ "playing": "done.wav", "status": "ok", "volume": 60.0 }
```

| Response | Meaning |
| --- | --- |
| `200` | Playing |
| `400` | Bad JSON, missing `file_name`, an incorrect file or path, or `volume` out of range |
| `404` | No such file in the sounds directory |
| `500` | The file could not be decoded or played |

> **WAV format only.** Any sample rate and channel count works; audio is converted to the output device format automatically.

### `POST /speak` (Windows)

```json
{ "text": "build finished" }
```

Speaks through a running [NVDA](https://www.nvaccess.org/) screen reader, over
its local RPC interface.

| Response | Meaning |
| --- | --- |
| `200` | Handed to NVDA |
| `400` | Missing, empty or non-string `text`, or invalid JSON |
| `502` | NVDA refused the call |
| `503` | NVDA is not running |

This endpoint only exists on Windows; elsewhere it is not registered.

## Build

Prebuilt Linux and Windows binaries are attached to every [release](../../releases). To build it yourself you need **Zig 0.16.0**. Zig brings its own C toolchain, and fetches miniaudio itself.

```sh
zig build                              # debug
zig build -Doptimize=ReleaseSmall      # smallest binary
zig build run -- --help
```

The executable lands in `zig-out/bin/`, with `sounds/` and `config.json` copied
next to it. Drop your `.wav` files into `sounds/`.

Cross-compiling to Windows works from any host:

```sh
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSmall
```

## Configuration

Precedence, later winning: **built-in defaults → `config.json` → command line**.

`config.json` is picked up automatically if it sits next to the executable:

```json
{ "host": "127.0.0.1", "port": 57919, "sounds": "sounds" }
```

A relative `sounds` path is resolved against the config file itself. Write a
starter file with `http_player generate-config`; an existing one is never
overwritten.

| Option | Default |
| --- | --- |
| `--host <addr>` | `127.0.0.1` |
| `--port <n>` | `57919` |
| `--sounds <dir>` | `sounds`, next to the executable |
| `-c, --config <file>` | `config.json`, next to the executable |
| `-q, --quiet` | Off. Hides the startup banner; errors are still shown. `register` adds it to the logon command |

Run `http_player --help` for the full list.

By default the server binds to `127.0.0.1` and is reachable only from this machine. `--host 0.0.0.0` accepts connections from anywhere. `/play` and `/speak` are unauthenticated, so only do that on a trusted network.
