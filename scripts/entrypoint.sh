#!/usr/bin/env bash
#
# Container entrypoint for the Icarus dedicated server.
#
# Runs in two stages from a single file. Stage one is PID 1 and root: it fixes up
# the service account, fetches the game, and owns the shutdown signal. It then
# re-invokes this script with --serve through runuser, which drops to an
# unprivileged user *without* clearing the environment, so configuration reaches
# stage two as ordinary exported variables rather than being copied by hand.
#
# Stage one must stay in the foreground as PID 1: the container runtime delivers
# SIGTERM only there, and bash will not run a trap while a foreground child is
# running. Hence the server is backgrounded and waited on, and this script never
# execs into it.

set -uo pipefail

readonly APP_ID=2089300
readonly RUN_AS=steam
readonly GAME_DIR=/home/steam/game-files
readonly SERVER_EXE_NAME='IcarusServer-Win64-Shipping.exe'
readonly SERVER_EXE="${GAME_DIR}/Icarus/Binaries/Win64/${SERVER_EXE_NAME}"

# --------------------------------------------------------------------------
# Output
#
# The colour per level (white info, yellow warning, red error, green success,
# bold cyan heading) follows thijsvanloef/palworld-server-docker (MIT); see
# THIRD-PARTY-NOTICES.md.
# --------------------------------------------------------------------------
_emit() { printf '%b%s\033[0m\n' "$1" "${*:2}"; }
note()  { _emit '\033[1;36m== ' "$@"; }
say()   { _emit '\033[0;37m'   "$@"; }
ok()    { _emit '\033[1;32m'   "$@"; }
warn()  { _emit '\033[1;33m'   "$@" >&2; }
fail()  { _emit '\033[1;31m'   "$@" >&2; }
die()   { fail "$@"; exit 1; }

# --------------------------------------------------------------------------
# Host addresses
#
# The image ships no iproute2, so there is no `ip addr`. hostname(1) is part of
# the Debian base and lists every configured address through getifaddrs; the
# kernel's own local-address table is the fallback for a base that drops it.
#
# Under `network_mode: host` that list also contains every docker and podman
# bridge on the host (172.17.0.1 and friends), which no player can reach. Those
# bridges live on their own subnets, so keeping only the addresses that fall
# inside a connected subnet of the *default route's* interface drops them
# without hardcoding any address range. /proc/net/route stores addresses as
# little-endian hex, hence the byte reversal.
# --------------------------------------------------------------------------
# Multiplication rather than bit shifts: a left-shift operator inside $(( ))
# reads as a here-doc to some syntax highlighters, which then colour the rest
# of the file as string.
_ip2int()  { local IFS=.; local -a o=(${1})
             echo $(( o[0]*16777216 + o[1]*65536 + o[2]*256 + o[3] )); }
_hex2int() { echo $(( 0x${1:6:2}*16777216 + 0x${1:4:2}*65536 + 0x${1:2:2}*256 + 0x${1:0:2} )); }

lan_ips() {
    local raw ip dflt='' v net msk
    local iface dest gw flags refcnt use metric mask rest
    local -a ips=() keep=()

    raw=$(hostname -I 2>/dev/null | tr '\n' ' ') || raw=''
    [[ -z ${raw// /} ]] && raw=$(awk '/32 host/ { print f } { f = $2 }' \
        /proc/net/fib_trie 2>/dev/null | grep -v '^127\.' | sort -u | tr '\n' ' ')
    read -r -a ips <<<"${raw}"

    while read -r iface dest gw flags refcnt use metric mask rest; do
        [[ ${dest} == 00000000 && ${mask} == 00000000 ]] && { dflt=${iface}; break; }
    done < /proc/net/route

    for ip in "${ips[@]}"; do
        [[ -n ${dflt} && ${ip} =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
        v=$(_ip2int "${ip}")
        while read -r iface dest gw flags refcnt use metric mask rest; do
            [[ ${iface} == "${dflt}" && ${mask} != 00000000 ]] || continue
            net=$(_hex2int "${dest}"); msk=$(_hex2int "${mask}")
            (( (v & msk) == net )) && { keep+=("${ip}"); break; }
        done < /proc/net/route
    done

    # No default route, or nothing matched: better to over-report than to
    # print nothing at all.
    printf '%s' "${keep[*]:-${ips[*]}}"
}

# --------------------------------------------------------------------------
# Locating the running server
#
# Under new-WoW64 Wine there is no wine-preloader process to look for, and the
# exe path appears in the argv of the xvfb-run wrapper and of Wine's start.exe
# launcher as well as the game. Signalling those would tear down the X server
# before the game could save, so only a process whose argv[0] *is* the
# executable counts.
# --------------------------------------------------------------------------
server_pids() {
    local pid argv0
    for pid in $(pgrep -f "${SERVER_EXE_NAME}" 2>/dev/null); do
        [[ -r /proc/${pid}/cmdline ]] || continue   # may exit while we look
        argv0=$(tr '\0' '\n' < "/proc/${pid}/cmdline" 2>/dev/null | head -1)
        [[ ${argv0} == *"${SERVER_EXE_NAME}" ]] && printf '%s\n' "${pid}"
    done
}

server_running() { [[ -n $(server_pids) ]]; }

# Ask the server to exit and wait for it. Returns non-zero if it outlives the
# deadline, which is kept below the runtime's stop grace period so that the
# fallback still has room to act.
stop_server() {
    local deadline=${SHUTDOWN_TIMEOUT:-25} waited=0 pids
    pids=$(server_pids) || true

    if [[ -z ${pids} ]]; then
        warn 'No running server found to stop'
        return 1
    fi

    note "Stopping server (pid $(tr '\n' ' ' <<< "${pids}"))"
    # Unquoted on purpose: there may legitimately be more than one pid.
    # shellcheck disable=SC2086
    kill -TERM ${pids} 2>/dev/null

    while (( waited < deadline )) && server_running; do
        sleep 1
        (( waited++ ))
    done

    if server_running; then
        warn "Server still running after ${deadline}s"
        return 1
    fi

    ok "Server stopped cleanly in ${waited}s"
}

# Safe to call unconditionally; does nothing when the server has already gone.
kill_server() {
    local pids
    pids=$(server_pids) || true
    if [[ -n ${pids} ]]; then
        warn "Killing server (pid $(tr '\n' ' ' <<< "${pids}"))"
        # shellcheck disable=SC2086
        kill -KILL ${pids} 2>/dev/null
    fi
}

# --------------------------------------------------------------------------
# Fetching the game
# --------------------------------------------------------------------------

# Render SOCKS_PROXY into a proxychains config and echo its path. Accepts
# socks5://[user:pass@]host:port, socks4://..., or a bare host:port.
write_proxy_config() {
    local spec=$1 conf=$2 kind=socks5 creds='' hostport host port

    case ${spec} in
        socks5://*) hostport=${spec#socks5://} ;;
        socks4://*) kind=socks4; hostport=${spec#socks4://} ;;
        *://*)      fail "Unsupported SOCKS_PROXY scheme: ${spec%%://*}"; return 1 ;;
        *)          hostport=${spec} ;;
    esac

    if [[ ${hostport} == *@* ]]; then
        creds=${hostport%@*}
        hostport=${hostport##*@}
        creds="${creds%%:*} ${creds#*:}"
    fi

    host=${hostport%:*}
    port=${hostport##*:}
    if [[ -z ${host} || -z ${port} || ${host} == "${port}" ]]; then
        fail "SOCKS_PROXY needs a port, e.g. socks5://10.0.0.2:1080 (got: ${spec})"
        return 1
    fi

    ( umask 077; cat > "${conf}" ) <<-EOF
	strict_chain
	proxy_dns
	remote_dns_subnet 224
	tcp_read_time_out 15000
	tcp_connect_time_out 8000
	[ProxyList]
	${kind} ${host} ${port} ${creds}
	EOF
}

# Hide any credentials before a proxy spec reaches the log
redact() {
    local spec=$1
    [[ ${spec} == *@* ]] || { printf '%s' "${spec}"; return; }
    case ${spec} in
        *://*) printf '%s://***@%s' "${spec%%://*}" "${spec##*@}" ;;
        *)     printf '***@%s' "${spec##*@}" ;;
    esac
}

fetch_game() {
    local -a cmd=(DepotDownloader -app "${APP_ID}" -os windows -osarch 64 -dir "${GAME_DIR}")
    local conf=/tmp/proxychains.conf

    note "Fetching Icarus dedicated server (app ${APP_ID})"

    # Without -validate, DepotDownloader trusts filename and size, which misses a
    # file corrupted in place at the same length. -validate re-hashes every file
    # and re-fetches only the chunks that differ.
    if [[ ${VALIDATE_ON_UPDATE:-true} == true ]]; then
        say 'Verifying checksums of existing files'
        cmd+=(-validate)
    fi

    # proxychains intercepts connect() in libc, so it covers the Steam CM socket
    # as well as the HTTPS content downloads. HTTP_PROXY only reaches the latter.
    if [[ -n ${SOCKS_PROXY:-} ]]; then
        write_proxy_config "${SOCKS_PROXY}" "${conf}" || return 1
        if [[ -n ${HTTP_PROXY:-}${HTTPS_PROXY:-}${http_proxy:-}${https_proxy:-} ]]; then
            warn 'Both SOCKS_PROXY and HTTP(S)_PROXY set; downloads will traverse two proxies'
        fi
        say "Routing downloads via $(redact "${SOCKS_PROXY}")"
        say "Public IP as seen by clients: $(curl -s https://ifconfig.me || echo 'unavailable')"
        say "Public IP as seen by steam: $(proxychains4 -q -f "${conf}" curl -s https://ifconfig.me || echo 'unavailable')"
        cmd=(proxychains4 -q -f "${conf}" "${cmd[@]}")
    fi

    if ! "${cmd[@]}"; then
        fail 'Download failed; continuing with whatever is already installed'
        return 1
    fi
    ok 'Server files are up to date'
}

# --------------------------------------------------------------------------
# Stage two: run the server as the unprivileged user
# --------------------------------------------------------------------------
serve() {
    local prefix=${WINEPREFIX:-${HOME}/.wine}

    [[ -f ${SERVER_EXE} ]] || {
        fail "Server executable missing: ${SERVER_EXE}"
        fail 'Set UPDATE_ON_START=true, or check the game-files volume.'
        exit 1
    }

    # Documented defaults from wine(1): the prefix location, a 64-bit prefix, and
    # FIXME chatter silenced. dwmapi=n,b is this project's choice, not Wine's.
    export WINEPREFIX=${prefix}
    export WINEARCH=${WINEARCH:-win64}
    export WINEDEBUG=${WINEDEBUG:-fixme-all}
    export WINEDLLOVERRIDES=${WINEDLLOVERRIDES:-dwmapi=n,b}

    if [[ ! -f ${prefix}/system.reg ]]; then
        note 'Creating Wine prefix'
        wineboot --init >/dev/null 2>&1
        say "Wine ready: $(wine --version 2>/dev/null)"
    fi

    # Built as an array so values containing spaces need no quoting gymnastics
    # and nothing has to pass through eval. Flags follow the order and spelling
    # of the "Command Line Args" list in the RocketWerkz wiki
    # (Server-Config-&-Launch-Parameters). -MaxPlayers is not in that list, so
    # it goes last.
    local -a argv=(
        xvfb-run --auto-servernum
        wine "${SERVER_EXE}"
        "-SteamServerName=${STEAM_SERVER_NAME}"
    )

    [[ -n ${USER_DIR:-}         ]] && argv+=("-UserDir=${USER_DIR}")
    [[ -n ${SAVED_DIR_SUFFIX:-} ]] && argv+=("-saveddirsuffix=${SAVED_DIR_SUFFIX}")
    [[ -n ${LOG:-}              ]] && argv+=("-LOG=${LOG}")
    [[ -n ${ABSLOG:-}           ]] && argv+=("-ABSLOG=${ABSLOG}")
    argv+=("-PORT=${PORT}" "-QueryPort=${QUERY_PORT}")
    [[ -n ${MULTIHOME:-}        ]] && argv+=("-MULTIHOME=${MULTIHOME}")
    [[ -n ${RESUME_PROSPECT:-}  ]] && argv+=(-ResumeProspect)
    [[ -n ${LOAD_PROSPECT:-}    ]] && argv+=("-LoadProspect=${LOAD_PROSPECT}")
    [[ -n ${CREATE_PROSPECT:-}  ]] && argv+=("-CreateProspect=${CREATE_PROSPECT}")
    argv+=("-MaxPlayers=${MAX_PLAYERS}")

    local lan
    lan=$(lan_ips)

    note "Launching ${STEAM_SERVER_NAME} on ${PORT}/udp (query ${QUERY_PORT}/udp)"
    say "Public IP: $(curl -s https://ifconfig.me || echo 'unavailable')"
    say "LAN IP: ${lan:-unavailable}"
    cd "${GAME_DIR}" || exit 1
    exec "${argv[@]}"
}

# --------------------------------------------------------------------------
# Stage one: PID 1, root
# --------------------------------------------------------------------------
on_term() {
    note 'Shutdown requested'
    stop_server || kill_server
    # Let the backgrounded child finish reaping before PID 1 returns
    tail --pid="${child}" -f /dev/null 2>/dev/null
}

apply_defaults() {
    export PORT=${PORT:-17777}
    export QUERY_PORT=${QUERY_PORT:-27015}
    export STEAM_SERVER_NAME=${STEAM_SERVER_NAME:-icarus-server}
    export MAX_PLAYERS=${MAX_PLAYERS:-8}
}

align_service_account() {
    local want_uid=${UID:-1000} want_gid=${GID:-1000}
    local have_uid have_gid
    have_uid=$(id -u "${RUN_AS}") || die "No ${RUN_AS} account in this image"
    have_gid=$(id -g "${RUN_AS}")

    if [[ ${have_gid} != "${want_gid}" ]]; then
        say "Moving ${RUN_AS} group to ${want_gid}"
        groupmod -o -g "${want_gid}" "${RUN_AS}" || die 'groupmod failed'
    fi
    if [[ ${have_uid} != "${want_uid}" ]]; then
        say "Moving ${RUN_AS} user to ${want_uid}"
        usermod -o -u "${want_uid}" "${RUN_AS}" || die 'usermod failed'
    fi

    # The bind-mounted game directory carries the host's ownership, so this has
    # to happen every start, not at build time.
    chown -R "${want_uid}:${want_gid}" /home/steam
}

main() {
    apply_defaults

    (( EUID == 0 )) || die 'This entrypoint expects to start as root'
    align_service_account

    if [[ ${UPDATE_ON_START:-true} == true ]]; then
        runuser -u "${RUN_AS}" -- "$0" --fetch || warn 'Continuing despite download failure'
    else
        say 'UPDATE_ON_START is false; leaving server files untouched'
    fi

    trap on_term TERM INT

    runuser -u "${RUN_AS}" -- "$0" --serve &
    child=$!
    wait "${child}"
}

case ${1:-} in
    --serve)  serve ;;
    --health) server_running ;;
    --fetch)  fetch_game ;;
    '')       main ;;
    *)        die "Unknown argument: $1" ;;
esac
