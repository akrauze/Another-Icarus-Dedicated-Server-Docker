# Making it generic

What it would take to turn this image from an Icarus server into a runner for **any Windows
dedicated server under Wine**.

This is a plan, not a description of the current image. For how the image works today,
see the [README](README.md) and [DESIGN-DECISIONS.md](DESIGN-DECISIONS.md).

## Scope

**In scope:** Steam-distributed dedicated servers that ship only Windows binaries and run
under Wine.

**Out of scope:** native Linux servers. [LinuxGSM](https://linuxgsm.com/) already covers
them well, and supporting them here would mean running without Wine: a different code path
and, ideally, a separate image about 1 GB smaller. At most, `-os` and `-osarch` become
overridable. Their defaults stay `windows` and `64`.

## Core configuration

These are the minimum settings that separate one game from another.

| Variable | Replaces | Notes |
|---|---|---|
| `STEAM_APP_ID` | `APP_ID=2089300` | Required. The container exits with a clear error if it is unset. |
| `SERVER_EXE` | `SERVER_EXE`, `SERVER_EXE_NAME` | Required. Path relative to `game-files`, e.g. `Icarus/Binaries/Win64/IcarusServer-Win64-Shipping.exe`. The file name is taken from this path with `basename`, so there aren't two settings that can disagree. |
| *container arguments* | Icarus-specific flag building in `serve()` | See below. |

### Pass the command line as container arguments, not a variable

The server command line is built as a bash array and `exec`'d so that values containing
spaces need no quoting and nothing passes through `eval`. A single
`COMMAND_LINE_OPTIONS` string would undo that: it has to be split somehow, and every way of
splitting it either breaks values like `My Server` or brings `eval` back.

Use the container's own arguments instead:

```yaml
command: ["-SteamServerName=My Server", "-PORT=${PORT}", "-QueryPort=${QUERY_PORT}"]
```

Compose passes that as a real list and fills in `${…}` from `.env`. The entrypoint forwards
`"$@"` through `runuser` and adds it to the end of the server's arguments.

What has to change in the entrypoint:

- It currently decides what to do based on its first argument (`--serve`, `--fetch`,
  `--health`). Those internal modes need a prefix no game will use, or user arguments must
  follow a `--`.
- All the Icarus-specific flag handling in `serve()` goes: `STEAM_SERVER_NAME`,
  `MAX_PLAYERS`, the prospect flags and the wiki ordering. `PORT` and `QUERY_PORT` are used
  only in the "Launching…" log line.

## Needed for most games

1. **Steamworks redistributable: `STEAMWORKS_REDIST` or `EXTRA_APP_IDS`.**
   Most Windows servers need `steamclient64.dll` and related files next to the executable.
   steamcmd puts them there; DepotDownloader does not. Icarus happens to ship its own.
   Other games usually need app `1007` (Steamworks SDK Redist) downloaded into the same
   directory, so `fetch_game()` has to be able to fetch more than one app.

2. **Process to watch: `PROCESS_NAME`** (defaults to the file name of `SERVER_EXE`).
   `server_pids()` finds the server by the executable name in the process's first
   argument, and both shutdown and the health check depend on that. Many games start a
   launcher exe that then spawns the real server. If the launcher is the configured exe,
   nothing matches, the health check fails, and every stop becomes a forced kill.

3. **Beta branches: `STEAM_BRANCH` and `STEAM_BRANCH_PASSWORD`.**
   Passed to DepotDownloader as `-branch` and `-branchpassword`. Many servers are run from
   beta branches.

## Settings where Icarus happens to work

4. **`USE_XVFB`** (default `true`). Icarus needs a display; many servers do not, and xvfb
   is one more process that can fail.

5. **`WINETRICKS`**: a list of winetricks components (e.g. `vcrun2022 dotnet48`),
   installed once when the Wine prefix is first created. Many servers need them. This also
   means adding `winetricks` and `cabextract` to the image. Without it, the image works
   only for games that run on plain Wine. SCUM needs `crypt32` (see
   [SCUM as the second game](#scum-as-the-second-game)). For how to work out which
   components a game needs, see
   [Finding out which winetricks a game needs](#finding-out-which-winetricks-a-game-needs).

6. **`WORKING_DIR`**. `serve()` currently starts the server from `game-files`. Some servers
   look for files relative to the executable's own directory.

7. **Shutdown.** Icarus saves and exits on SIGTERM through Wine. Other servers need an RCON
   command or input on stdin, or ignore SIGTERM altogether. SCUM needs **SIGINT**, so
   `SHUTDOWN_SIGNAL` (default `TERM`) is needed. A `PRE_STOP_HOOK` script for RCON-style
   shutdowns can wait until a game needs one.

   Either way, `SHUTDOWN_TIMEOUT` and the compose `stop_grace_period` may need to be longer
   for servers with large saves. Change one and check the other.

8. **`PRE_START_HOOK`**: path to a user script in the volume, run as `steam` just before
   launch. This is the simplest general answer to per-game setup: writing config files,
   creating symlinks, dropping in extra DLLs. Icarus's `ServerSettings.ini` is exactly this
   kind of file, and the image cannot template config files for every game.

9. **Steam login: `STEAM_USERNAME` and related variables.** Some dedicated servers cannot
   be downloaded with anonymous login. DepotDownloader supports accounts, but Steam Guard
   needs someone to answer a prompt, which a container cannot do.
   `-remember-password` with a login saved in the volume works, but is awkward.
   **Recommend deferring this.**

### Finding out which winetricks a game needs

Don't guess. Add a component only when there is a log line that it fixes. Icarus runs with
none, only the `dwmapi=n,b` override, and the proof is that it starts on a fresh prefix.
There are three ways to find the evidence for another game.

**1. Read the executable's imports.** The import table lists the DLLs the exe needs.
`winedump` comes with the `wine` package:

```bash
winedump -j import SERVER.exe | grep -i dll
# or, with mingw binutils:
x86_64-w64-mingw32-objdump -p SERVER.exe | grep 'DLL Name'
```

Check the DLLs shipped next to the exe too. These imports point to a winetricks candidate:

| Import | Suggests | winetricks candidate |
|---|---|---|
| `MSVCP140.dll`, `VCRUNTIME140*.dll` | MSVC 2015–2022 runtime | `vcrun2022` |
| `MSVCR120.dll` / `MSVCR110.dll` | older MSVC runtime | `vcrun2013` / `vcrun2012` |
| `mscoree.dll` | .NET Framework app | wine-mono first, then `dotnet48` |
| `d3dcompiler_47.dll`, `d3dx*` | DirectX runtime parts | `d3dcompiler_47`, `d3dx9` |
| `crypt32`, `bcrypt`, `secur32` | TLS / crypto | usually fine as builtin |

An import is a suspect, not a requirement: Wine has builtin versions of most of these
DLLs. Also check what the depot ships. `_CommonRedist/`, Unreal's
`Engine/Extras/Redist/.../UEPrereqSetup_x64.exe` and DLLs next to the exe mean the game
brings its own copy, and winetricks isn't needed for it.

**2. Run it and read Wine's log.** This is the test that decides. On a fresh prefix:

```bash
WINEDEBUG=+loaddll,err+all wine SERVER.exe ... 2>&1 | tee wine.log
grep -E 'not found|Unimplemented function|import_dll|mscoree' wine.log
```

- `err:module:import_dll Library X.dll ... not found`: the DLL is missing entirely. A
  winetricks component or the game's shipped redist fixes it.
- `Unimplemented function msvcp140.dll.…`: Wine's builtin exists but is incomplete. This
  is the usual case where a native version from winetricks (`vcrun2022`) helps.
- `+loaddll` lines: show whether each DLL loaded as `builtin` or `native`.
- A crash with no DLL error is usually not a winetricks problem. Look at other causes
  first, such as `vm.max_map_count`, the display, or memory.

**3. See what others found.** ProtonDB and the WineHQ AppDB for the game, other Docker
images for the same server (their Dockerfiles show exactly which winetricks they run), and
the depot's `installscript.vdf`, which lists the redists Steam would install on Windows.

Components added "just in case" slow down the first start and can hide the real problem.
Native `dotnet48` replaces wine-mono, and a native `vcrun` replaces a builtin that may have
been working. SCUM's `crypt32` should get the same check: run it with and without on a
fresh prefix, and keep it only if it removes an error.

## Decisions beyond environment variables

- **Health check start period.** `--start-period=15m` in the [Dockerfile](Dockerfile) was
  chosen for Icarus's ~7 GB download. It is set at build time, not by environment variable.
  A compose `healthcheck:` block can override it, so this needs documenting, not code.

- **Branding.** "Icarus" appears in:
  - the `LABEL` title and description in the [Dockerfile](Dockerfile)
  - `IMAGE ?= icarus-server` in the [Makefile](Makefile)
  - the service name in [examples/docker-compose.yml](examples/docker-compose.yml)
  - the log lines in [scripts/entrypoint.sh](scripts/entrypoint.sh) ("Fetching Icarus…")
  - most of the [README](README.md)

- **Licensing.** Renaming the image doesn't change the GPL-3.0 licence or the third-party notices. 
  [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) stay whatever the image is renamed to.

- **Game presets.** Ship `examples/icarus.env` plus the matching compose `command:` as the
  reference game. The Icarus-specific knowledge now spread through the README and
  CLAUDE.md moves into that preset's documentation instead of disappearing:
  - the prospect flags
  - `ServerSettings.ini` and where passwords go
  - `vm.max_map_count` for large prospects

## What stays the same

Most of the image already works for any game:

- the two-stage entrypoint: root as PID 1, then `runuser` to `steam`
- UID/GID remapping and the `chown` on start
- the `SIGTERM` trap, with the server backgrounded and waited on
- DepotDownloader, `VALIDATE_ON_UPDATE` and `UPDATE_ON_START`
- `SOCKS_PROXY` through proxychains
- setting up the Wine prefix on first run, and the `WINE*` defaults, which can already be
  overridden
- `lan_ips()` and the address logging
- the Makefile, including the podman `--format docker` handling

## Effort

The entrypoint changes are small. About 30 lines leave `serve()`, two variables become
required with a clear error when they are missing, and `"$@"` gets passed through. Most of
the work is elsewhere:

1. Downloading more than one app (item 1).
2. Hooks and winetricks (items 5 and 8).
3. Rewriting the README around a generic image with Icarus as the example.
4. Testing against a **second real game**.

For that second game, pick one that does *not* start as easily as Icarus: ideally one that
needs the Steamworks redist, winetricks components, or a launcher exe. Otherwise the test
cannot show whether the generic version really works.

### SCUM as the second game

[EvilOlaf/scum](https://github.com/EvilOlaf/scum), listed in the acknowledgements in
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md), runs the SCUM dedicated server
(app `3792580`) under Wine. It tests several parts of this plan:

| What that image does | Which part of this plan it tests |
|---|---|
| `winetricks -q crypt32` at build time; installs `cabextract` for it | `WINETRICKS` (item 5). Here the prefix is created at runtime in the volume, not in the image, so the components have to be installed the first time the prefix is created. `cabextract` has to be added to the image too. |
| Stops the server with **SIGINT**, not SIGTERM, and waits up to 60 s (`stop_grace_period: 65s`) | `SHUTDOWN_SIGNAL` (item 7) is needed, not optional. It also needs `SHUTDOWN_TIMEOUT` of about 60 s. |
| Runs `SCUM/Binaries/Win64/SCUMServer.exe` under `xvfb-run` | `SERVER_EXE` and `USE_XVFB=true`. Whether it needs a launcher-style `PROCESS_NAME` should be checked with `ps` on a running server. |
| Passes extra flags through a word-split `ADDITIONALFLAGS` string | The quoting problem described under [Pass the command line as container arguments](#pass-the-command-line-as-container-arguments-not-a-variable). |
| Uses steamcmd, not DepotDownloader | Unknown: whether SCUM needs the Steamworks redist (item 1). steamcmd may have been supplying `steamclient64.dll` without anyone noticing. |
| Memory watchdog: shuts down cleanly when host memory is nearly full | Something this image doesn't do. It could be added later as a general feature, but it isn't needed to start the server. |

The other items in the plan still have to be checked against a running SCUM server.

## Suggested order

1. Make `STEAM_APP_ID` and `SERVER_EXE` required. Pass container arguments through `"$@"`,
   and move the internal modes out of their way. Keep Icarus working via
   `examples/icarus.env`, and confirm with `make smoke` and a real start.
2. `PROCESS_NAME`, `WORKING_DIR`, `USE_XVFB`, `SHUTDOWN_SIGNAL`.
3. Downloading more than one app, with the Steamworks redist.
4. `PRE_START_HOOK`, then `WINETRICKS` (adds a package to the image).
5. Bring up the second game, then fix whatever it shows is missing.
6. Branding, README rewrite, presets.
7. `PRE_STOP_HOOK` and Steam login, only if a real game needs them.
