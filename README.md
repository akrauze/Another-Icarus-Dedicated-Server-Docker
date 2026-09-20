
# Icarus dedicated server in a container

Runs the Windows build of the Icarus dedicated server on a Linux host, under Wine, in a
Docker-compatible container.

Server files are fetched from Steam with [DepotDownloader](https://github.com/SteamRE/DepotDownloader) using the anonymous account.

The reasons behind the less obvious choices, such as DepotDownloader over steamcmd and the
split-tunnel hosting setup, are collected in [DESIGN-DECISIONS.md](DESIGN-DECISIONS.md).

## No prebuilt image is published

You build this image yourself. There is no registry to pull from, by design.

You should not run container images built by strangers on the internet unless you have
reason to trust them. You have no reason to trust me — we have never met, and a lack of
trust is the correct default. Building from this source means you can read exactly what
goes into the image before you run it.

Building it is three commands — see [Building the image](#building-the-image).

## Prerequisites

**To build the image**

- A container engine — `docker` or `podman`. The [Makefile](Makefile) detects either.
- An **x86-64** host. The Dockerfile pins `--platform=linux/amd64`, because Wine and the
  Windows server binaries are 64-bit x86 only. Building on arm64 needs emulation and is
  untested.
- Around **3 GB of free disk** for the finished image, plus several GB more for
  intermediate build layers and the apt cache. Allow 8 GB to be comfortable.
- Network access during the build to `deb.debian.org`, `dl.winehq.org` and `github.com`.
  Nothing else is contacted.
- Optional, only if you use the Makefile: `make` and `curl`. `curl` is used to look up the
  latest DepotDownloader release from `api.github.com`; pinning
  `DEPOTDOWNLOADER_VERSION` skips that call entirely.

**To run the server**

- **Docker.** The instructions here assume `docker` / `docker compose`, which is what this
  has been run against. Podman builds the image fine, but the run path is not equivalent
  out of the box — see [A note on podman](#a-note-on-podman) below.
- Roughly **12 GB of free disk**: about 10.4 GB for the game files (the depot is 501
  files, ~7 GB downloaded), plus ~1 GB of headroom for saves, logs and backups. The
  server keeps roughly ten rolling backups of each prospect, so a single active prospect
  costs several times its own size — a 2.5 MB save with its backups is closer to 26 MB —
  and logs accumulate alongside it. A server with three prospects and a month of logs sits
  under 100 MB, so 1 GB is generous, but it grows with world size and playtime.
- Network access to Steam on first start, and on any start with `UPDATE_ON_START=true`.
- A host `vm.max_map_count` of at least `262144`. The default is too low for the number of
  memory mappings Wine creates, and the symptom is out-of-memory crashes on large
  prospects despite plenty of free RAM. See
  [Out-of-memory crashes](#out-of-memory-crashes-on-large-prospects).
- The `./game-files` directory owned by the uid and gid the container runs as — `1000:1000`
  unless you change `UID`/`GID`.
- UDP ports open for the game and query ports. See [Ports](#ports).

### A note on podman

Podman builds this image without trouble, and rootful podman (`sudo podman`, or podman as
root) runs it the same way docker does. **Rootless** podman is the awkward case, and it
will not work by simply substituting the command.

The obstacle is user namespaces. Rootless podman maps container uids through your
`/etc/subuid` range, so a container process running as uid 1000 is not host uid 1000 — with
a typical range starting at 100000 it lands on host uid 100999. The `./game-files`
directory you chowned to `1000:1000` is then unreadable to the server, and it fails on
startup with permission errors rather than anything that names the real cause.

The usual remedies are `--userns=keep-id`, the `:U` mount flag to have podman rechown the
volume into the namespace, or chowning the directory from inside the namespace with
`podman unshare chown -R 1000:1000 ./game-files`. Which is appropriate depends on your
setup, and none of them has been tested here — rootless podman is the one configuration
this has not been validated against.

## Building the image

Step by step, assuming you have never done this before.

**1. Install Docker.** Follow the official instructions for your system:
[Docker Engine on Linux](https://docs.docker.com/engine/install/),
[Docker Desktop for Windows or macOS](https://docs.docker.com/desktop/). Check it works:

```bash
docker --version
```

**2. Download this repository.** Either clone it:

```bash
git clone <this-repository-url>
cd icarus-server-docker
```

or download the ZIP from the repository page, unpack it, and `cd` into the folder. You
should be in the directory that contains `Dockerfile`.

**3. Build the image.** The `-t icarus-server` part is the name you are giving it, and the
`.` at the end means "build from this directory" — don't leave it out:

```bash
docker build -t icarus-server .
```

This takes several minutes and needs an internet connection. It downloads Debian packages,
Wine, and DepotDownloader. You will see a long stream of installation output; that is
normal. What matters is that it finishes without an error — depending on your Docker
version the final lines mention either `Successfully tagged icarus-server:latest` or
`naming to docker.io/library/icarus-server`. Either is success.

**4. Check it is there.**

```bash
docker images icarus-server
```

If that lists your image, you are done building. It is about 2.8 GB. Nothing has been
downloaded from Steam yet — the game files come later, on first start.

Now continue to [Quick Start](#quick-start) to configure and run it.

> **Optional:** if you have `make` installed, `make build` does the same thing, and adds
> version pinning and podman support. See the [Makefile](Makefile). You do not need it.

## Quick Start

Build the image first — there is no image to pull. Then copy the example files out of
[`examples/`](examples/) and edit your copies; the originals stay untouched so updates to
this repository never overwrite your configuration.

### Docker Compose

1. Build the image, if you have not already — see
   [Building the image](#building-the-image).

2. Copy the examples into place:
```bash
cp examples/docker-compose.yml docker-compose.yml
cp examples/env.example .env
```

3. Edit `docker-compose.yml` to set `image:` to the tag you just built, and edit `.env`
   with your settings. At minimum check `UID`/`GID` match the owner of `./game-files`.

4. Start the server:
```bash
docker compose up -d && docker compose logs -f
```

### Docker Run

```bash
docker run -d \
    --restart unless-stopped \
    --name icarus \
    --stop-timeout 30 \
    --network host \
    --env-file .env \
    -v ./game-files:/home/steam/game-files \
    icarus-server
```

Both examples use host networking (`network_mode: host` in compose, `--network host`
here) because **LAN discovery needs it**. Steam finds LAN servers by broadcasting on the
local network. Published ports forward only traffic addressed to the host, so those
broadcasts never reach a container on Docker's bridge network, and the server does not
appear in the **LAN** tab.

With host networking no ports are published: the container binds `PORT` and `QUERY_PORT`
directly on the host. If players only ever connect over the internet, you can publish
ports instead. Drop `--network host` and add `-p 17777:17777/udp -p 27015:27015/udp`,
matching whatever you set in `.env`. In compose, remove `network_mode: host` and
uncomment the `ports:` block.

## Configuration

All settings are environment variables, read from `.env`.

### Game launch options

Each of these becomes one argument on the server's command line. They are the arguments
RocketWerkz documents under
[Command Line Args](https://github.com/RocketWerkz/IcarusDedicatedServer/wiki/Server-Config-&-Launch-Parameters#command-line-args),
listed here in the same order; see that page for the authoritative behaviour of each.

The variable name is the argument name in `UPPER_SNAKE_CASE`: `-SteamServerName` becomes
`STEAM_SERVER_NAME`, `-QueryPort` becomes `QUERY_PORT`. Arguments the game already spells
in capitals keep their name (`PORT`, `LOG`, `ABSLOG`, `MULTIHOME`). The one irregular name
is `-saveddirsuffix`, which the game spells in lowercase: its variable is
`SAVED_DIR_SUFFIX`. The mapping is written out by hand in
[scripts/entrypoint.sh](scripts/entrypoint.sh), so a variable not in this table is ignored.
An unset option is left off the command line.

| Variable | Argument | Default | What it does |
|----------|----------|---------|--------------|
| `STEAM_SERVER_NAME` | `-SteamServerName` | icarus-server | Name shown in the server browser, up to 64 characters |
| `USER_DIR` | `-UserDir` | - | Directory that `Saved/` is created under, relative or absolute |
| `SAVED_DIR_SUFFIX` | `-saveddirsuffix` | - | Suffix for the `Saved/` directory; `x` gives `Saved_x/` |
| `LOG` | `-LOG` | - | Log file, relative to `Saved/Logs/` |
| `ABSLOG` | `-ABSLOG` | - | Log file as an absolute path |
| `PORT` | `-PORT` | 17777 | UDP game port |
| `QUERY_PORT` | `-QueryPort` | 27015 | UDP port answering Steam server queries |
| `MULTIHOME` | `-MULTIHOME` | - | Local IP address to bind to |
| `RESUME_PROSPECT` | `-ResumeProspect` | - | Any value passes the flag, which reopens the last prospect on start |
| `LOAD_PROSPECT` | `-LoadProspect` | - | Save name of a prospect to open on start |
| `CREATE_PROSPECT` | `-CreateProspect` | - | Start a new prospect; see below |
| `MAX_PLAYERS` | `-MaxPlayers` | 8 | Player limit, 1 to 8 |

`MAX_PLAYERS` is the exception: the wiki's command-line list does not include it, and
documents `MaxPlayers` as a `ServerSettings.ini` setting instead. It is passed last.

#### Creating a prospect

`CREATE_PROSPECT` takes four space-separated values, in the order the game defines for
[`-CreateProspect`](https://github.com/RocketWerkz/IcarusDedicatedServer/wiki/Server-Config-&-Launch-Parameters#prospect-setup-and-load):
prospect type, difficulty, hardcore, save name. Using the wiki's own example:

```bash
CREATE_PROSPECT="Tier1_Forest_Recon_0 3 false TestProspect01"
```

The type is one of the game's internal names from the
[Prospect Names](https://github.com/RocketWerkz/IcarusDedicatedServer/wiki/Prospect-Names) page. Difficulty runs from `1` to `4`, and hardcore
`true` means no respawns. Keep the whole value in one variable; the entrypoint passes it
to the game as a single argument.

### Container options

These control the container itself and never reach the game.

| Variable | Default | What it does |
|----------|---------|--------------|
| `UPDATE_ON_START` | true | Fetch or update the server files before each start |
| `VALIDATE_ON_UPDATE` | true | Checksum every installed file when updating, and repair any that differ |
| `SOCKS_PROXY` | - | Route server updates through a SOCKS proxy, e.g. `socks5://10.0.0.2:1080` |
| `SHUTDOWN_TIMEOUT` | 25 | Seconds to wait for a clean stop before killing the server |

## Join and admin passwords

Passwords are **not** set through environment variables. The server reads them from its
own config file, which lives in the game files volume:

```
game-files/Icarus/Saved/Config/WindowsServer/ServerSettings.ini
```

Add them under the `[/Script/Icarus.DedicatedServerSettings]` section:

```ini
[/Script/Icarus.DedicatedServerSettings]
JoinPassword=****
AdminPassword=****
```

The file appears after the server has started once and written its defaults. Restart the
server after editing it. Because the file lives in the mounted volume it survives
container recreation and image updates.

## Ports

Players and the Steam server browser reach the server on two UDP ports, and both have to
be open inbound on any firewall or router in the way. `PORT` and `QUERY_PORT` in `.env`
set them; out of the box they are:

| Port | Used for |
|------|----------|
| `17777/udp` | Gameplay traffic (`PORT`) |
| `27015/udp` | Steam server queries (`QUERY_PORT`) |

If you want the server to be discoverable on your own network, `QUERY_PORT` also has
to sit inside the range Steam scans for LAN servers — see
[Server missing from the LAN tab](#server-missing-from-the-lan-tab).

For instructions specific to your router, visit
[portforward.com](https://portforward.com/).

To check the result from outside your network, use
[Sara's Steam Dedicated Server Query Tool](https://saraserenity.net/steam/server_query.php).
It queries your server the way Steam does, so it confirms not just that the port is open
but that the server is answering — which is the more useful signal when a server builds
and starts cleanly yet never appears in the browser.

## Volumes

One bind mount holds everything that has to outlive the container:

| Host | Container | Contents |
|------|-----------|----------|
| `./game-files` | `/home/steam/game-files` | The downloaded server, plus everything it writes under `Icarus/Saved/`: prospects, `ServerSettings.ini` and logs |


## Proxying server updates

Set `SOCKS_PROXY` to route DepotDownloader through a SOCKS proxy when fetching or
updating server files:

```bash
SOCKS_PROXY=socks5://10.0.0.2:1080
```

Accepted forms are `socks5://[user:pass@]host:port`, `socks4://...`, or a bare
`host:port` (treated as socks5). Credentials are masked in the container logs. This
wraps DepotDownloader in `proxychains`, which intercepts connections at the socket
level, so **everything** it opens is proxied — the Steam CM connection on port 27021
as well as the HTTPS content downloads.

`HTTP_PROXY` and `HTTPS_PROXY` are passed through to DepotDownloader too, but those
are only honoured by its HTTPS content downloads; the Steam CM connection is a plain
socket and ignores them. Use `SOCKS_PROXY` if you need the whole exchange proxied.
Setting both sends download traffic through two proxies, and the container logs a
warning if you do.

Only server updates are proxied. The game server itself is not run under proxychains,
so its own Steam traffic is unaffected.

For a worked example of why you might want this — routing the ~7 GB download out via
your own WAN while player traffic goes through a VPS — see
[Hosting without a public IP](#hosting-without-a-public-ip).

## Hosting without a public IP

![Split tunnel setup](img/Game%20Server%20Split%20Tunnel.png)

A dedicated game server normally needs a routable public IP: players connect to it
directly, and it advertises that address to the Steam server browser. The setup above
removes that requirement by renting a public IP from a cheap VPS and tunnelling it
back to a server on your own network.

It is more moving parts than most people need. Two situations make it worth the effort:

1. **You are behind CGNAT** and have no public IP to forward ports on.
2. **You have one but would rather not publish it.** A game server hands its address
   to every player who joins and to the Steam server browser.

### How it works

Traffic is deliberately split across two paths, which is where most of the complexity
comes from:

- **Player traffic goes through the VPS.** Inbound game connections land on the VPS
  public IP and are relayed over a UDP port-forwarding tunnel to the game server on
  your network. Outbound traffic from the game server — including its Steam
  registration and heartbeats — is forced back out through the same VPS. What players
  and the server browser see is the VPS address; your WAN IP never appears. The
  redirect covers internet-bound traffic only — LAN destinations, broadcast and
  multicast are deliberately left out, so the server's local traffic stays on your
  network and players at home can reach it directly.
- **Server updates go out through your own WAN.** DepotDownloader pulls roughly 7 GB
  on a fresh install, and VPS egress is usually metered or capped. Pointing
  `SOCKS_PROXY` at a SOCKS proxy inside your network sends that download straight out
  of your home connection instead of over the tunnel. See
  [Proxying server updates](#proxying-server-updates).

That second path is why the SOCKS proxy **must run on a different host than the game
server**. The firewall rule that forces game-server traffic through the VPS would
otherwise capture the proxy's traffic as well, defeating the split.

### What you need

| Component | Purpose | Options |
|---|---|---|
| VPS with a public IP | Terminates player connections | Oracle Always-Free Ampere on a PAYG plan is a good fit |
| UDP-capable port forwarding tunnel | Relays game traffic to your network | [Rathole](https://github.com/rathole-org/rathole), FRP, ngrok |
| SOCKS proxy | Sends server downloads out via your WAN | [MicroSocks](https://github.com/rofl0r/microsocks), Dante |
| Router with firewall and VPN client | Enforces which traffic takes which path | OPNsense, pfSense, Asus with Merlin |
| Outbound tunnel from router to VPS | Carries relayed traffic | WireGuard, OpenVPN |
| A Docker host | Runs this container | — |

### Setup

**On the VPS**

1. Confirm the instance has a public IP.
2. Allow inbound connections on the game and query ports, and on the tunnel's control
   port.
3. Allow outbound/egress TCP and UDP.
4. Configure its firewall to match.
5. Run the port-forwarding tunnel in server mode, listening on those ports.

**Between the VPS and your network**

6. Establish a VPN tunnel between your router and the VPS. Which end acts as client
   and which as server depends on your threat model; see
   [DESIGN-DECISIONS.md](DESIGN-DECISIONS.md#which-end-of-the-vpn-is-the-client) for the
   choice made here.

**On your network**

7. Run the port-forwarding tunnel in client mode, connecting out to the VPS and
   pointing the game and query ports at your game server.
8. Install a SOCKS proxy on a host **other than** the game server.
9. Add a firewall rule that redirects traffic **originating from the game server's
   address** (say `192.168.0.100`) into the VPS tunnel, **except** traffic to your
   LAN — e.g. destination `192.168.0.0/16`, matching whatever range you actually use.
   Without that exception the server cannot reach anything local, including the SOCKS
   proxy. If parts of your network live in `10.0.0.0/8` or `172.16.0.0/12`, exempt
   those too.

   Order matters: the exception has to be matched before the catch-all redirect, or
   the redirect swallows it.

   Broadcast and multicast need no rule of their own. They are never routed, so they
   stay on the local segment and do not reach the tunnel.

   LAN discovery does not depend on this rule either. On a flat segment
   the client's broadcast and the server's reply never reach the firewall at all, so
   no rule there can break — or fix — it. If the server is missing from the **LAN**
   tab, the cause is almost certainly on the client — see
   [Server missing from the LAN tab](#server-missing-from-the-lan-tab).

10. Set `SOCKS_PROXY` in your `.env` to point at the SOCKS proxy.

### Example configuration

[`examples/rathole.toml`](examples/rathole.toml) is a commented Rathole config covering
both ends of the tunnel — the same file runs as server on the VPS
(`rathole --server rathole.toml`) and as client on your network
(`rathole --client rathole.toml`). Replace the placeholder addresses and tokens before
using it.

### A note on encryption

Some tunnels, Rathole included, can encrypt the link; the example enables its Noise
transport. Whether you need it is a threat-model decision, but be clear about what it
covers: **encryption applies only between the VPS and your network.** Traffic between
players and the VPS is unaffected, and the game protocol itself is not protected.

If you would rather not rely on the tunnel's own encryption, you can route the tunnel
through the VPN instead, at the cost of some additional overhead.

## Upgrading from a steamcmd-based image

Server files are now fetched with DepotDownloader instead of steamcmd. Both install to
the same layout, so **keep your existing `game-files` volume as it is** — do not wipe it.

DepotDownloader cannot read steamcmd's state, but on the first run it checksums whatever
is already on disk and reuses every file that matches the depot. A steamcmd-installed
server therefore migrates without re-downloading the game. Saves, configs and logs under
`Saved/` are not touched; the depot does not ship that directory at all.

The one thing worth removing is `game-files/steamapps/`, which steamcmd created and
nothing uses any more. DepotDownloader never prunes files it did not download, so it will
sit there indefinitely — including any partial downloads under `steamapps/downloading/`:

```bash
rm -rf game-files/steamapps
```

Deleting the game files themselves is counterproductive: that is what forces the full
~7 GB download the checksum pass would otherwise avoid.

Depending on the image you were using before you may need to adjust the mount point.

## Server missing from the LAN tab

**Symptoms:** The server shows up under Internet/Community in the Steam server browser,
and direct connection by IP works, but it never appears under **LAN** — even though the
client and the server are on the same network.

**Root Cause:** Almost always the client machine, not the server. Steam discovers LAN
servers by broadcasting to `255.255.255.255` on UDP 27015-27020. Windows sends limited
broadcast out **one** interface — the one with the lowest metric — and virtual adapters
from Hyper-V, WSL, Docker Desktop or a VPN client routinely outrank the physical NIC. The
scan then goes into a virtual network and never reaches the LAN at all. Nothing on the
server, in its firewall or in its port configuration can compensate.

Check it in PowerShell on the **client**:

```powershell
route print -4 | Select-String "255.255.255.255"
```

Your primary LAN IP should have the **lowest** metric in that list. Here it does not —
a Hyper-V adapter at 271 beats the real NIC at 276, so the scan leaves on `172.23.176.1`:

```
     172.23.176.1  255.255.255.255         On-link      172.23.176.1    271
     192.168.1.50  255.255.255.255         On-link      192.168.1.5     276
  255.255.255.255  255.255.255.255         On-link      192.168.1.5     276
  255.255.255.255  255.255.255.255         On-link      172.23.176.1    271
```

**Fix:** raise the offending adapter's metric above the LAN NIC's. List the interfaces to
find the two numbers:

```powershell
Get-NetIPInterface -AddressFamily IPv4 | Sort-Object InterfaceMetric |
  Format-Table ifIndex, InterfaceAlias, InterfaceMetric
```

```
ifIndex InterfaceAlias                 InterfaceMetric
------- --------------                 ---------------
     47 vEthernet (Default Switch)                  15
     10 Ethernet                                    20
```

Then use `Set-NetIPInterface -InterfaceIndex XX -InterfaceMetric YY route print -4 | Select-String "255.255.255.255"` in PowerShell **as administrator**.

- **XX** is the `ifIndex` of the virtual adapter that outranks your LAN NIC — `47` here.
  Match it to the address from `route print` by its `InterfaceAlias`.
- **YY** is any metric higher than your LAN NIC's — `50` here, comfortably above `20`.
  Do not lower the LAN NIC to `1`; leave room to adjust later.

```powershell
Set-NetIPInterface -InterfaceIndex 47 -InterfaceMetric 50
route print -4 | Select-String "255.255.255.255"
```

The LAN IP should now hold the lowest metric. (The numbers in `route print` are the
interface metric plus a base of 256, which is why `15` and `20` appear as `271` and
`276`.) Restart Steam and re-check the LAN tab.

Four things worth knowing:

- This is **per client machine**. Every player running WSL, Hyper-V, Docker Desktop or a
  VPN adapter needs the same fix on their own PC.
- Hyper-V recreates the Default Switch, so the metric can reset across reboots or
  Hyper-V updates. Re-check if the server disappears again.
- `QUERY_PORT` must fall inside the range Steam scans for LAN servers — `4242`,
  `26900-26905`, `27015-27020` or `27215`. The default `27015` qualifies; a value moved
  outside those ranges will never be discovered, however the metrics are set.
- The container must run with **host networking**. On Docker's bridge network the
  client's broadcast never reaches the server, even with the client fixed — see
  [Docker Run](#docker-run).

To confirm the direction of the fault before changing anything, run this on the server
host while the client refreshes its LAN tab:

```bash
tcpdump -ni eth0 'udp and (broadcast or multicast)'
```

No broadcast on the wire means the client never asked, and the problem is the client. A
broadcast arriving with no reply points at the server. Note that WSL2 with mirrored
networking silently drops outbound limited broadcast, so run client-side broadcast tests
from Windows itself rather than inside WSL.


## Known issues

### Out-of-memory crashes on large prospects

A large prospect can crash the server with an out-of-memory error, such as `Freeing X
bytes from backup pool to handle out of memory` or `Ran out of memory allocating 0 bytes`,
while the host still has free RAM.

What runs out is memory mappings, not memory. Wine maps a great many regions, and the
kernel caps how many one process may hold at `vm.max_map_count`. It is a kernel setting,
so it is set on the **host**; nothing inside the container can change it.

Check the current value first:

```bash
sysctl vm.max_map_count
```

`262144` is known to work. The kernel's own default is 65530, but several distributions
ship a larger value for the sake of games running under Wine and Proton: Fedora 39+,
Ubuntu 22.10+ and Arch set `1048576`, and SteamOS sets it higher still. If your host
already reports `262144` or more, leave it alone. The setting is a ceiling, not a
reservation, so a larger value costs nothing, and writing `262144` would **lower** it.

Only if the value is below `262144`, raise it:

```bash
sudo sysctl -w vm.max_map_count=262144                                # until reboot
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-icarus.conf # persistent
sudo sysctl --system                                                  # reload
sysctl vm.max_map_count                                               # check
```

Credit for this fix goes to Icarus Discord user **Fabiryn**, as recorded in the
[Known Issues](https://gitlab.com/fred-beauch/icarus-dedicated-server#known-issues) of
Nerodon's icarus-dedicated-server.

## Credits and license

Licensed under the GNU General Public License v3 — see [LICENSE](LICENSE). This
program comes with ABSOLUTELY NO WARRANTY; it is free software, and you are welcome
to redistribute it under the terms of that license.

Inspired by many other projects. See [Third-party notices](THIRD-PARTY-NOTICES.md).

### Thanks

**[Noredon (fred-beauch)](https://gitlab.com/fred-beauch/icarus-dedicated-server)** built
the first Docker deployment of the Icarus dedicated server, and it remains the most widely
used one. None of his code is in this project — the two were written independently, and a
line-by-line comparison finds essentially nothing in common — but he solved the problem
first and showed it could be done. That is worth acknowledging on its own terms.

To be unambiguous about the warning further up this file: he is emphatically not one of
the "strangers on the internet". His work has been public, scrutinised and relied upon for
years.

### Third-party components

Full notices are in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). In summary:

- The image bundles a binary of
  [DepotDownloader](https://github.com/SteamRE/DepotDownloader) (GPL-2.0), pinned by the
  `DEPOTDOWNLOADER_VERSION` build argument. It is run as a separate executable, not
  linked, so its inclusion is mere aggregation. Source for the exact version, and a
  written offer under GPL-2.0 section 3(b), are in the notices file.
- The entrypoint's per-level log colours follow
  [thijsvanloef/palworld-server-docker](https://github.com/thijsvanloef/palworld-server-docker)
  (MIT); its notice is reproduced in the notices file.
- Wine (LGPL-2.1-or-later) and the Debian packages are installed unmodified from WineHQ
  and Debian, which publish their corresponding source.

### Modifications in this fork

Changed from the upstream project, most recently September 2026:

- Server files are fetched with DepotDownloader instead of steamcmd, and the image is
  built on `debian:trixie-slim` rather than `cm2network/steamcmd`.
- Added `VALIDATE_ON_UPDATE` to control checksum verification of an existing install.
- Added `SOCKS_PROXY` to route server updates through a SOCKS proxy via proxychains.

## Further reading

For why this project is built the way it is, see [DESIGN-DECISIONS.md](DESIGN-DECISIONS.md).

The official dedicated-server documentation is the
[RocketWerkz wiki](https://github.com/RocketWerkz/IcarusDedicatedServer/wiki). The pages this README relies on most are:

- [Server-Config-&-Launch-Parameters](https://github.com/RocketWerkz/IcarusDedicatedServer/wiki/Server-Config-&-Launch-Parameters): every
  launch argument and `ServerSettings.ini` key
- [Prospect-Names](https://github.com/RocketWerkz/IcarusDedicatedServer/wiki/Prospect-Names): valid values for the first field of
  `CREATE_PROSPECT`
- [Server-Setup](https://github.com/RocketWerkz/IcarusDedicatedServer/wiki/Server-Setup): the setup guide for running the server natively
