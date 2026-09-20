# Design decisions

Some choices in this project look odd until you know the reasoning behind them. This page
collects those questions and the answers.

The [README](README.md) explains *how* to set things up. This page explains *why* they are
set up that way.

**Hosting without a public IP**

These cover the optional
[Hosting without a public IP](README.md#hosting-without-a-public-ip) setup.

- [Why a Rathole tunnel instead of port forwarding on the VPS?](#why-a-rathole-tunnel-instead-of-port-forwarding-on-the-vps)
- [Why Rathole and not FRP or ngrok?](#why-rathole-and-not-frp-or-ngrok)
- [Which end of the VPN is the client?](#which-end-of-the-vpn-is-the-client)
- [Why encrypt the Rathole tunnel with Noise?](#why-encrypt-the-rathole-tunnel-with-noise)
- [Why split the tunnel?](#why-split-the-tunnel)
- [Why suggest Oracle Cloud on a pay-as-you-go plan?](#why-suggest-oracle-cloud-on-a-pay-as-you-go-plan)

**The image**

- [Why DepotDownloader instead of steamcmd?](#why-depotdownloader-instead-of-steamcmd)
- [Why validate the game files on every update?](#why-validate-the-game-files-on-every-update)
- [Why Debian?](#why-debian)

## Why a Rathole tunnel instead of port forwarding on the VPS?

The obvious approach is to forward the game ports on the VPS through the VPN to the game
server. For that to work, the home firewall has to accept connections that **start on the
VPS**.

My threat model does not allow that. Traffic may pass between my network and the VPS, but
only on connections that **my network opens**. Rathole fits this: its client runs inside my
network and connects out to the VPS, and player traffic comes back over that connection.
The VPS never needs a route or a firewall rule that lets it open connections into my
network.

The VPS is the exposed part of this setup. It has a public IP, it runs on someone else's
hardware, and it accepts traffic from anyone on the internet. If it is ever compromised,
the attacker has a machine that can send traffic back down the tunnel, but cannot open new
connections into my network. That gap does not make the setup secure. It does limit what
one compromised host can do.

## Why Rathole and not FRP or ngrok?

Experience, mostly. Years ago I tried both Rathole and [FRP](https://github.com/fatedier/frp),
and at the time Rathole performed better. I have never really tried ngrok.

Any tunnel that can forward UDP and is started from inside your network will do the same
job. The README lists the alternatives for that reason.

## Which end of the VPN is the client?

The VPS is the VPN server, and my router is the client. This follows from the same threat
model as [the Rathole choice](#why-a-rathole-tunnel-instead-of-port-forwarding-on-the-vps):
my network opens the connection, and the VPS only answers.

My firewall then blocks any connection that is not already established and that originates
on the VPS, or arrives through it. Replies to connections my network opened get through.
Anything the VPS starts on its own does not.

## Why encrypt the Rathole tunnel with Noise?

Personal preference. Rathole's Noise transport and routing Rathole through the VPN are two
ways of doing the same thing, and neither adds real protection over the other.

Be clear about what either one covers: only the link between the VPS and your network.
Traffic between players and the VPS is not touched, and the game protocol is not encrypted
end to end. The only thing encryption buys here is that your ISP sees less.

## Why split the tunnel?

A fresh install downloads about 7 GB from Steam, and every update downloads more. VPS
providers usually charge for egress or cap it. If the download went through the VPS like
the rest of the game server's traffic, the VPS would receive it from Steam and then send
all of it back out down the tunnel to my network. That second leg is billable egress.

Sending the download out through my own internet connection keeps it off the VPS, and
keeps the VPS bill down. Player traffic is small by comparison, and it is the only traffic
that needs the VPS's public IP.

The `SOCKS_PROXY` option exists for this purpose. See
[Proxying server updates](README.md#proxying-server-updates).

## Why suggest Oracle Cloud on a pay-as-you-go plan?

I know. I dislike Oracle too. But nothing is cheaper than free, and Oracle's Always Free
tier includes an Ampere instance with more than enough capacity to relay a game server.

Pay-as-you-go (PAYG) is how you actually get one. Free-tier accounts often cannot get
Always Free Ampere capacity. Upgrading the account to PAYG usually fixes this, and
resources inside the Always Free limits are still not billed.

The catch is that a PAYG account *can* be billed. If you create something outside the
Always Free limits, you pay for it. Set a budget alert, and check the shape and region
before you provision.

## Why DepotDownloader instead of steamcmd?

Because steamcmd does not work with proxychains, and proxychains is what makes the
[split tunnel](#why-split-the-tunnel) possible.

proxychains works by preloading a library into the program it wraps, so the library must
match the program's architecture. steamcmd is a 32-bit binary, and the stock proxychains
library is 64-bit. In the linked report, a separately compiled 32-bit proxychains still
did not get steamcmd online. See
[proxychains-ng#153](https://github.com/rofl0r/proxychains-ng/issues/153).

[DepotDownloader](https://github.com/SteamRE/DepotDownloader) is a 64-bit (x86-64)
program, so the standard proxychains library works with it. Changing tools also brought a
smaller base image, `debian:trixie-slim` instead of `cm2network/steamcmd`, and existing
steamcmd installs migrate without downloading the game again. See
[Upgrading from a steamcmd-based image](README.md#upgrading-from-a-steamcmd-based-image).

The HTTP proxy variables were not an alternative. DepotDownloader opens a plain-socket
connection to Steam's CM servers that ignores `HTTP_PROXY` and `HTTPS_PROXY`. proxychains
works at the socket level, so it catches that connection as well.

## Why validate the game files on every update?

`VALIDATE_ON_UPDATE` defaults to `true` because it is cheap, and it catches damage that a
plain update misses.

Without validation, DepotDownloader decides whether a file is current from its name and
size alone. A missing file is fetched again, but a file corrupted in place at the same size
is not noticed. With validation, it hashes every installed file and re-downloads only the
chunks that differ. The cost is reading the install from local disk, not downloading it
again. In practice that is quick enough to run on every start.

That is a property of DepotDownloader, not of validation in general. steamcmd's
`app_update ... validate` is much slower, and anyone used to it has good reason to leave
validation off. This image defaults to on because DepotDownloader makes it cheap.

Set it to `false` if you would rather skip the disk read.

## Why Debian?

Because I dislike a lot of things, Ubuntu included. `debian:trixie-slim` is small, stable
and gets out of the way.

I would have used Alpine, but it is built on musl rather than glibc, and making Wine and a
.NET program behave on musl is more pain than a smaller image is worth.
