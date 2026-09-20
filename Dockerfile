# Overridable so alternative bases can be trialled, e.g.
#   make build BASE_IMAGE=dhi.io/debian-base:trixie-debian13-dev
# Any replacement must be Debian trixie with apt, i386 multiarch and a shell.
ARG BASE_IMAGE=debian:trixie-slim
FROM --platform=linux/amd64 ${BASE_IMAGE}

# Hardened bases commonly default to a nonroot UID. The build installs packages
# and the entrypoint remaps UID/GID at runtime, so both need root; it drops to
# the steam user itself via runuser.
USER root

# https://github.com/SteamRE/DepotDownloader/releases
ARG DEPOTDOWNLOADER_VERSION=3.4.0
ARG UID=1000
ARG GID=1000

# WineHQ development branch, pinned. winehq-devel Depends strictly on the matching
# wine-devel/-amd64/-i386, so pinning this pins the whole chain.
ARG WINE_VERSION=11.18~trixie-1
ARG WINE_BRANCH=devel

LABEL org.opencontainers.image.title="Icarus Dedicated Server" \
      org.opencontainers.image.description="Icarus dedicated server under Wine" \
      org.opencontainers.image.source="https://github.com/akrauze/Another-Icarus-Dedicated-Server-Docker" \
      org.opencontainers.image.authors="AK <rigorous.juice10@mailx.net>" \
      org.opencontainers.image.licenses="GPL-3.0-only"

RUN dpkg --add-architecture i386 && \
    mkdir -pm755 /etc/apt/keyrings && \
    apt-get update && apt-get install -y --no-install-recommends ca-certificates curl locales unzip && \
    curl -fsSL -o /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key && \
    curl -fsSL -o /etc/apt/sources.list.d/winehq-trixie.sources https://dl.winehq.org/wine-builds/debian/dists/trixie/winehq-trixie.sources && \
    apt-get update && apt-get install -y --no-install-recommends winehq-${WINE_BRANCH}=${WINE_VERSION} && \
    apt-get install -y --no-install-recommends \
    proxychains4 \
    procps \
    xauth \
    xvfb \
    && sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen \
    && dpkg-reconfigure --frontend=noninteractive locales \
    && apt-get upgrade -y \
    && apt-get dist-upgrade -y \
    && apt-get autoremove -y \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Unprivileged user the server runs as. Both the uid and gid are pinned so the
# identity is fixed at build time rather than left to useradd's next-free pick;
# -o tolerates a base image that already occupies these ids. The entrypoint still
# remaps to UID/GID at runtime for hosts whose volume is owned differently.
RUN groupadd -o -g "${GID}" steam && \
    useradd -o -u "${UID}" -g "${GID}" -m steam && \
    chown -R steam:steam /home/steam/

# DepotDownloader fetches the Windows server depot; the linux-x64 build is
# self-contained, so no .NET runtime is needed in the image
RUN curl -fsSL -o /tmp/depotdownloader.zip \
    "https://github.com/SteamRE/DepotDownloader/releases/download/DepotDownloader_${DEPOTDOWNLOADER_VERSION}/DepotDownloader-linux-x64.zip" && \
    mkdir -p /opt/depotdownloader && \
    unzip -q /tmp/depotdownloader.zip -d /opt/depotdownloader && \
    rm /tmp/depotdownloader.zip && \
    chmod +x /opt/depotdownloader/DepotDownloader && \
    ln -s /opt/depotdownloader/DepotDownloader /usr/local/bin/DepotDownloader

# Required, not merely defensive: libicu used to arrive transitively via winbind,
# which is no longer installed. Without this, the self-contained .NET binary
# fails to start on a base that ships no ICU.
ENV DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1

ENV HOME=/home/steam \
    PORT=17777 \
    QUERY_PORT=27015 \
    STEAM_SERVER_NAME=icarus-server \
    MAX_PLAYERS=8 \
    MULTIHOME="" \
    UPDATE_ON_START=true \
    VALIDATE_ON_UPDATE=true \
    SOCKS_PROXY=""

COPY ./scripts /home/steam/server/

RUN mkdir -p /home/steam/game-files && \
    chmod +x /home/steam/server/*.sh

# Uncommentelines below to install iproute2 and tcpdump for network troubleshooting. 
#RUN apt-get update && apt-get install -y --no-install-recommends iproute2 tcpdump && \
#    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /home/steam/server

# Healthy only while the game process itself is up, found the same way the
# shutdown handler finds it. Matching any "wine" process would also count
# wineserver or the xvfb-run wrapper after the game had died. The start period
# covers a first-run download of the full depot.
HEALTHCHECK --interval=30s --timeout=10s --start-period=15m --retries=3 \
    CMD ["/home/steam/server/entrypoint.sh", "--health"]

ENTRYPOINT ["/home/steam/server/entrypoint.sh"]
