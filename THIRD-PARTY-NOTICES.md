# Third-party notices

This project is licensed under the GNU General Public License v3 (see [LICENSE](LICENSE)).
Its container image distributes the third-party components below.

---

## DepotDownloader — GPL-2.0

The container image bundles a compiled binary of
[SteamRE/DepotDownloader](https://github.com/SteamRE/DepotDownloader), downloaded during
the build from the release pinned by the `DEPOTDOWNLOADER_VERSION` build argument (see
the [Dockerfile](Dockerfile)). It is used to fetch the dedicated server files from Steam.

DepotDownloader is licensed under the **GNU General Public License, version 2**.

Complete corresponding source for the exact version distributed in this image is
published by its authors at:

> https://github.com/SteamRE/DepotDownloader/releases/tag/DepotDownloader_3.4.0
> (source for any other version: `https://github.com/SteamRE/DepotDownloader/releases/tag/DepotDownloader_<version>`)

**Written offer.** As required by GPL-2.0 section 3(b), the distributor of this image
offers, for a period of three years from the date of distribution, to provide a complete
machine-readable copy of the corresponding source code of DepotDownloader for no more
than the cost of physically performing source distribution. Requests may be sent to the
maintainer of this repository.

The binary is used **unmodified**, exactly as published by its authors — the build
downloads the official release archive and unpacks it without patching, recompiling or
altering it in any way. This is the same relationship the image has with the Debian and
WineHQ packages it installs.

DepotDownloader is invoked as a **separate executable** by `scripts/entrypoint.sh`; it is
not linked into, and does not form a combined work with, the rest of this project. Its
presence in the image is mere aggregation under GPL-2.0 section 2, so it does not alter
the licensing of the remaining contents.

The DepotDownloader binary is self-contained and embeds its own dependencies, including
the .NET runtime (MIT), SteamKit2, protobuf-net, QRCoder and CsWin32. Their notices are
carried in the upstream source above.

---

## palworld-server-docker — MIT

The per-level log colours in `scripts/entrypoint.sh` follow
[thijsvanloef/palworld-server-docker](https://github.com/thijsvanloef/palworld-server-docker):
white for information, bold yellow for warnings, bold red for errors, bold green for
success and bold cyan for section headings, using the same ANSI codes. The functions
around them were written for this project. 

A colour mapping this small may not count as a "substantial portion" under the MIT
licence. Its origin is known, though, so the notice is carried anyway:

```
MIT License

Copyright (c) 2024 Thijs van Loef

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## Wine, and Debian packages

The image installs Wine from [WineHQ](https://dl.winehq.org/) and roughly six hundred
packages from Debian. These retain their own licences — Wine itself is LGPL-2.1-or-later.
As with DepotDownloader, every one of these binaries is installed **unmodified**, exactly
as published, and complete corresponding source for each is available from Debian and
WineHQ through their standard source repositories.

## A note on scope

No image built from this repository is currently published or distributed. The notices
and the written offer above are written as though it were, so that they remain correct
without revision if that ever changes.

## Acknowledgements 

Some ideas used here came from one or more of these repository:
* https://gitlab.com/fred-beauch/icarus-dedicated-server
* https://github.com/mornedhels/icarus-server
* https://github.com/thijsvanloef/palworld-server-docker
* https://github.com/EvilOlaf/scum
