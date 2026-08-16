<p align="center">
    <picture>
        <source media="(prefers-color-scheme: dark)" srcset="assets/gfdi-lockup-on-dark.svg">
        <source media="(prefers-color-scheme: light)" srcset="assets/gfdi-lockup-on-light.svg">
        <img alt="gfdi" src="assets/gfdi-lockup-on-light.svg" width="240">
    </picture>
</p>

&nbsp;

<p align="center">
    A tool to pull FIT files from a Garmin watch over Bluetooth LE, speaking Garmin's GFDI protocol directly.
</p>

<p align="center">
    <a href="https://github.com/braycarlson/gfdi/actions/workflows/ci.yml"><img alt="ci" src="https://img.shields.io/github/actions/workflow/status/braycarlson/gfdi/ci.yml?branch=main&amp;style=flat-square&amp;label=ci"></a>
    <a href="https://ziglang.org"><img alt="zig" src="https://img.shields.io/badge/zig-0.16.0-orange.svg?style=flat-square"></a>
    <a href="LICENSE"><img alt="license" src="https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square"></a>
</p>

## Overview

gfdi copies the activity files off a Garmin watch over Bluetooth and writes them to a
folder on your machine. The watch hands its archive over in Garmin's own framing, so gfdi
speaks that protocol itself rather than driving Garmin Express or Garmin Connect. Windows
and Linux both work.

## Features

- **No Garmin software**: Nothing from Garmin has to be installed or running.
- **No system libraries**: The Linux backend talks to BlueZ over a D-Bus client written
  here, and the Windows backend drives WinRT through COM.
- **Resumable**: A pull that drops reconnects and picks up from what is already on disk,
  through 20 attempts.
- **Filed by type**: Each file is decoded far enough to read its type and timestamp, so it
  lands as `pulled/Activity/2024-08-23-17-56-01.fit` rather than an opaque index.
- **Fuzzers**: Each wire format carries one, covering GFDI framing, protobuf, reassembly,
  the D-Bus client, FIT, and the session state machine.

## Install

The build looks for [zfit](https://github.com/braycarlson/zfit) in the same parent
directory, since `build.zig.zon` points at it by relative path.

```
git clone https://github.com/braycarlson/zfit
git clone https://github.com/braycarlson/gfdi
cd gfdi
zig build -Doptimize=ReleaseSafe
```

The binary lands in `zig-out/bin`. gfdi requires Zig 0.16.0 and no other dependency.

## Usage

The command comes first and the address second, and a bare address is shorthand for
`observe`. Linux needs BlueZ on the system bus.

| Command | What it does |
|---|---|
| `gfdi observe <address>` | The full archive pull that reconnects until the sync completes. |
| `gfdi connect <address>` | The connection by address, plus a list of the GATT services it finds. |
| `gfdi pull <address>` | The wait for the watch to advertise, then a GATT inspection. |
| `gfdi scan` | The BLE advertisers seen over eight seconds. |
| `gfdi enumerate` | The BLE devices the OS already knows. |
| `gfdi smoke` | The check that the BLE runtime loads at all. |

```console
$ just run
zig build run --
usage: gfdi <command> [address]

  observe AA:BB:CC:DD:EE:FF   pull the watch archive, reconnecting until complete
  connect AA:BB:CC:DD:EE:FF   connect by address and list GATT services
  pull    AA:BB:CC:DD:EE:FF   wait for the watch to advertise, then inspect GATT
  scan                        list BLE advertisers seen for 8 seconds
  enumerate                   list BLE devices known to the OS
  smoke                       verify the BLE runtime loads

  AA:BB:CC:DD:EE:FF           shorthand for observe with this address
```

The files land under `pulled/`, one directory per FIT file type, and the resume markers
sit in `pulled/.state`. The next run pulls everything again once that directory is
deleted.

## Development

The recipes below wrap `zig build`, and a bare `just` lists them all. The tidy law is a
test rather than a separate linter, so the mechanical rules run with everything else.

| Command | What it runs |
|---|---|
| `just ci` | The formatting check, compilation, the unit tests, and the fuzzer smoke run. |
| `just test` | Each test suite and the formatting check. |
| `just tidy` | The tidy law on its own. |
| `just check-windows` | The compile of every artifact for Windows from any host. |
| `just fuzz <name> [seed] [events]` | The named fuzzer, such as `gfdi`, `protobuf`, `reassembly`, or `session`. |

## Licence

MIT. See [LICENSE](LICENSE).
