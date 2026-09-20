# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Docker image that runs the **Windows** build of the Icarus dedicated server on Linux under Wine. There is no application source code here — the repo is a `Dockerfile` plus a single bash entrypoint in [scripts/](scripts/). Nearly every unusual thing in the repo (xvfb, Wine prefixes, `-os windows` on the depot download, `linux/amd64` pinning) follows from that one fact.

There is no test suite, linter config, or build tool. "Building" means building the image.

## Commands

Images are **built** and **run** on different machines, with different tooling. Don't assume `docker` is present.

### Building

Use the [Makefile](Makefile); it picks the container engine and the DepotDownloader version for you.

```bash
make build                                 # auto-detect engine, latest DepotDownloader
make build DEPOTDOWNLOADER_VERSION=3.3.0   # pin the downloader
make build ENGINE=docker TAG=v1            # force engine and tag
make version                               # show what would be used, without building
```

`ENGINE` is auto-detected as the first of `podman`, `docker` on `PATH`. `DEPOTDOWNLOADER_VERSION` defaults to the latest release, read from the GitHub API and resolved lazily — an explicit override never queries the network, and neither do `help`, `lint` or `clean`.

Three build flags matter, and the Makefile supplies them:

- `--format docker` is added **only for podman**, whose default OCI format **silently discards the Dockerfile's `HEALTHCHECK`**. It warns during the build, then `podman inspect --format '{{.HealthCheck}}'` returns `<nil>`. `docker build` has no such flag and needs none.
- `--platform=linux/amd64` — Wine and the Windows server binaries are x86-64 only.
- `--network=host` — required on some build hosts.

Smoke-test with `make smoke`, which runs the container directly rather than through compose:

```bash
make smoke   # UID/GID remap, chown, privilege drop and env propagation, no 7 GB download
```

It is **expected to end at "Server executable missing"** — with `UPDATE_ON_START=false` and an empty volume there is no game to launch, so reaching that error means the whole entrypoint chain worked.

### Running

Deployment uses `docker compose` against a copy of [examples/docker-compose.yml](examples/docker-compose.yml):

```bash
docker compose up -d && docker compose logs -f
```

That file runs with `network_mode: host` — its `ports:` block is commented out, because published ports are ignored under host networking. The container therefore binds `PORT` and `QUERY_PORT` straight onto the host, so **`.env` alone decides which ports are in use**; there is no port mapping to cross-check against. Read the ports out of the deployed `.env` rather than assuming, and don't treat a non-default value there as a bug to reconcile against `examples/env.example`, which documents the defaults.

### Checking the scripts

```bash
bash -n scripts/*.sh      # syntax check (no linter is configured)
shellcheck scripts/*.sh   # if installed
```

Verifying a change to the depot download **without** the ~7 GB download (~10 GB on disk) — run DepotDownloader directly with `-manifest-only`, which exercises login, app/depot resolution and the OS filter in seconds:

```bash
DepotDownloader -app 2089300 -os windows -osarch 64 -dir /tmp/out -manifest-only
```

`fetch_game()` can be exercised by putting a stub `DepotDownloader` on `PATH` that echoes `"$@"`, then sourcing the entrypoint (strip its final `case` block) and calling it.

## Runtime architecture

`ENTRYPOINT` is [scripts/entrypoint.sh](scripts/entrypoint.sh), one file that runs in two stages and dispatches on its own argument at the bottom (`--serve`, `--fetch`, `--health`, or no argument for stage one).

**Stage one** is PID 1 and root: it remaps the baked-in `steam` account to `UID`/`GID` (this is why root is needed), `chown`s `/home/steam`, fetches the game unless `UPDATE_ON_START=false`, installs the `SIGTERM` trap, then launches stage two in the background and `wait`s.

**Stage two** runs as `steam` and execs the server.

Two constraints hold this shape in place:

- **PID 1 keeps the trap.** The runtime delivers SIGTERM only to PID 1, and bash will not run a trap while a foreground child is running. So the server is backgrounded and waited on, and stage one never `exec`s. Changing that to `exec ./entrypoint.sh --serve` silently destroys shutdown.
- **`runuser`, not `su -`.** `runuser` preserves the environment, so configuration reaches stage two as ordinary exported variables. `su -` wipes it, which is what forced the old copy-each-variable-by-hand approach.

### Server files come from DepotDownloader, not steamcmd

`fetch_game()` runs `DepotDownloader -app 2089300 -os windows -osarch 64 -dir /home/steam/game-files`. App `2089300` resolves to depot `2089301`; login is anonymous by default. `-os windows -osarch 64` is mandatory — the host is Linux, but we want the Windows binaries Wine will run. DepotDownloader keeps its state in `game-files/.DepotDownloader/` (three small files, ~500 KB). Its skip behaviour is worth knowing exactly, since it decides what `VALIDATE_ON_UPDATE` is for — all of this is measured against the real depot, not inferred:

- **No stored manifest** (fresh volume, or migrating off steamcmd): it checksums whatever is already on disk and downloads only what does not match. A steamcmd-era install migrates for ~0 bytes; wiping the volume first costs the full ~7 GB for nothing.
- **Stored manifest present** (the normal restart): it trusts filename plus size. A missing file is re-fetched, but a file corrupted **in place at the same size is not detected**.
- **`-validate`**: re-hashes every file and re-fetches only the differing chunks. This is the only path that repairs same-size corruption, and it is what `VALIDATE_ON_UPDATE=true` (the default) buys.

DepotDownloader never prunes files it did not download, so anything left over from a previous tool (notably `game-files/steamapps/` from steamcmd) persists until deleted by hand.

### Proxying the downloader

`SOCKS_PROXY` wraps the DepotDownloader call in `proxychains4 -q -f <generated conf>`. `write_proxy_config()` in [scripts/entrypoint.sh](scripts/entrypoint.sh) parses the spec, writes `/tmp/proxychains.conf` mode 600 (it can hold credentials) and echoes the path; `redact()` masks credentials for the log line.

Why proxychains rather than the proxy env vars — measured through a local SOCKS5 server, DepotDownloader opens three kinds of connection:

| Connection | Example | Covered by `HTTP_PROXY`? |
|---|---|---|
| Steam Web API | `api.steampowered.com:443` | yes |
| **Steam CM** | `ext2-maa2.steamserver.net:27021` | **no — plain socket** |
| Content CDN | `cache3-iad1.steamcontent.com:443` | yes |

proxychains hooks `connect()` in libc, so it catches all three; `proxy_dns` in the generated config keeps name resolution on the proxy side too. `HTTP_PROXY`/`HTTPS_PROXY` reach only .NET's `HttpClient`, which is why they cannot carry the CM connection. Setting both proxies the CDN traffic twice, and `fetch_game()` warns about it.

This is also why the image moved off steamcmd: proxychains needs a preload library matching the target binary's architecture, and steamcmd is 32-bit. DepotDownloader is x86-64, so the stock amd64 `libproxychains.so.4` applies.

Only `fetch_game()` is wrapped. The game server itself is not proxied.

The linux-x64 release is self-contained, so the image has no .NET runtime. `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1` is set in the Dockerfile so it does not need `libicu`, which `debian:trixie-slim` does not ship.

### Graceful shutdown

`stop_grace_period: 30s` in [examples/docker-compose.yml](examples/docker-compose.yml) bounds the whole sequence; `SHUTDOWN_TIMEOUT` defaults to 25s so the forced kill still has room inside it. Change one and check the other.

Finding the server is the subtle part, and it is **not** `pidof wine-preloader` — under new-WoW64 Wine no such process exists, which is why the original handler silently never signalled anything. Three processes carry the exe path in their command line: the `xvfb-run` wrapper (argv[0] `/bin/sh`), Wine's `start.exe` launcher, and the game (argv[0] the exe itself, as `Z:\home\...` or `.../dosdevices/z:/...`). `server_pids()` matches **argv[0] only**; signalling the wrapper would tear down the X server before the game could save.

`stop_server()` sends SIGTERM to every matching pid, re-queries liveness each second, and returns non-zero on timeout, at which point `on_term` calls `kill_server()` for SIGKILL. Both are safe to call when nothing is running.

## Adding an environment variable

`runuser` preserves the environment, so a variable set on the container reaches stage two without plumbing. There are only two places to touch:

1. A default, if it needs one — either in the `ENV` block of the [Dockerfile](Dockerfile) or inline as `${VAR:-default}` in the entrypoint.
2. For user-facing options, document it in both [examples/env.example](examples/env.example) and the config table in [README.md](README.md).

The server command line is built as a **bash array** and `exec`d, never assembled into a string and `eval`'d, so values containing spaces (`STEAM_SERVER_NAME`, `CREATE_PROSPECT`) need no quoting gymnastics. Append with `argv+=("-Flag=${VAR}")` and let the array carry the boundaries.

Game launch options follow two conventions, documented for users in [examples/env.example](examples/env.example) and [README.md](README.md):

- **Naming:** the variable is the argument name in `UPPER_SNAKE_CASE` (`-SteamServerName` → `STEAM_SERVER_NAME`); all-caps arguments keep their name (`PORT`, `LOG`, `ABSLOG`, `MULTIHOME`). The one irregular name is `-saveddirsuffix` → `SAVED_DIR_SUFFIX`.
- **Order:** `serve()` appends flags in the order of the RocketWerkz wiki's *Command Line Args* list, with the wiki's spelling. `-MaxPlayers` is not in that list and goes last. Keep env.example and the README table in the same order.

## Wine notes

The prefix is bootstrapped on first run only, detected via `$WINEPREFIX/system.reg`, with a plain `wineboot --init`. `WINEPREFIX`, `WINEARCH=win64` and `WINEDEBUG=fixme-all` are the stock values from wine(1). `WINEDLLOVERRIDES` defaults to `dwmapi=n,b`; it was added deliberately (commit `a35b8a9`), so treat it as intentional rather than leftover. The server is launched under `xvfb-run` because it still expects a display, and the `HEALTHCHECK` runs `entrypoint.sh --health`, which reuses `server_running()` so it reports on the game process, not on any `wine` process that happens to be alive.

README documents that OOM-style crashes on large prospects are usually the host's `vm.max_map_count` being too low for Wine's mapping count — a host-side sysctl, not an image problem.

## Distribution

No image is published and there is no CI. The repository carries no workflows: images are
built locally with the Makefile and, if pushed at all, pushed to a private registry. The
README states deliberately that users should build from source rather than pull an image
from a stranger. `--platform=linux/amd64` is pinned regardless, because Wine and the
Windows server binaries are x86-64 only.

## Packages that look unused but are not

A naive grep of the entrypoint finds no mention of these, and both are essential:

- **`procps`** supplies `pgrep`, which `server_pids()` depends on to find the server at all. Without it, shutdown silently signals nothing and every stop becomes a hard kill.
- **`xauth`** is shelled out to by `xvfb-run`. Without it the server cannot start: `xvfb-run: error: xauth command not found`.

`DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1` in the Dockerfile is likewise load-bearing, not defensive. `libicu` used to arrive transitively via `winbind`; with `winbind` gone the image ships no ICU at all, and without this flag DepotDownloader aborts on startup with *"Couldn't find a valid ICU package installed on the system"*. Verified, not inferred.
