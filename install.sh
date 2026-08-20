#!/usr/bin/env bash
#
# Installs Anycubic Slicer Next as a web-accessible container.
#
# Works on a normal Linux box, a VM, or a Proxmox LXC (see PROXMOX-LXC.md for
# the container options that have to be set on the Proxmox side first).
#
#   ./install.sh                 interactive
#   ./install.sh --no-auth       no password, loopback-only (safe default)
#   ./install.sh --auth          random password, reachable on the LAN
#   ./install.sh --auth --password 'hunter2' --bind 0.0.0.0
#   ./install.sh --network bridge --port 8080
#
# Docker is installed from the distribution's own packages, or from Docker's
# official repository with its GPG key pinned. This script never pipes a
# remote script into a shell.

set -euo pipefail

readonly REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

# ---------------------------------------------------------------- output ---
if [[ -t 1 ]]; then
    B=$'\033[1m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; N=$'\033[0m'
else
    B=''; R=''; G=''; Y=''; N=''
fi
info()  { printf '%s==>%s %s\n' "$G" "$N" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$Y" "$N" "$*" >&2; }
die()   { printf '%s[x]%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
head1() { printf '\n%s%s%s\n' "$B" "$*" "$N"; }

# ------------------------------------------------------------------ args ---
AUTH=""              # yes | no
PASSWORD=""
WEB_USER="${SUDO_USER:-${USER:-slicer}}"
BIND=""              # 127.0.0.1 | 0.0.0.0
NETWORK="host"       # host | bridge
PORT=3000
HTTPS_PORT=3001
ASSUME_YES=0
SKIP_DOCKER=0
SKIP_BUILD=0

usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//;$d'; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --auth)         AUTH=yes ;;
        --no-auth)      AUTH=no ;;
        --password)     PASSWORD="${2:?--password needs a value}"; AUTH=yes; shift ;;
        --user)         WEB_USER="${2:?--user needs a value}"; shift ;;
        --bind)         BIND="${2:?--bind needs a value}"; shift ;;
        --network)      NETWORK="${2:?--network needs host|bridge}"; shift ;;
        --port)         PORT="${2:?--port needs a value}"; shift ;;
        --https-port)   HTTPS_PORT="${2:?--https-port needs a value}"; shift ;;
        -y|--yes)       ASSUME_YES=1 ;;
        --skip-docker)  SKIP_DOCKER=1 ;;
        --skip-build)   SKIP_BUILD=1 ;;
        -h|--help)      usage ;;
        *)              die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

[[ "$NETWORK" == host || "$NETWORK" == bridge ]] || die "--network must be host or bridge"

# ------------------------------------------------------------- privileges ---
if [[ $EUID -eq 0 ]]; then
    SUDO=""
elif command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
else
    SUDO=""
    warn "not root and no sudo -- Docker installation will be skipped"
    SKIP_DOCKER=1
fi

ask() {  # ask <prompt> <default:y|n>
    local prompt="$1" def="${2:-n}" reply
    if [[ $ASSUME_YES -eq 1 ]]; then
        [[ "$def" == y ]] && return 0 || return 1
    fi
    local hint="[y/N]"; [[ "$def" == y ]] && hint="[Y/n]"
    read -r -p "$prompt $hint " reply </dev/tty || reply=""
    reply="${reply:-$def}"
    [[ "${reply,,}" == y* ]]
}

# ------------------------------------------------------------ environment ---
head1 "1/6  Checking the host"

OS_ID=""; OS_VERSION_CODENAME=""
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_VERSION_CODENAME="${VERSION_CODENAME:-}"
fi
info "distribution: ${PRETTY_NAME:-unknown}"

IN_LXC=0
if [[ -r /proc/1/environ ]] && grep -qa 'container=lxc' /proc/1/environ 2>/dev/null; then
    IN_LXC=1
elif systemd-detect-virt --container >/dev/null 2>&1; then
    IN_LXC=1
fi
if [[ $IN_LXC -eq 1 ]]; then
    info "running inside an LXC/system container"
    if [[ ! -e /dev/kmsg ]] && [[ ! -e /dev/console ]]; then
        warn "no /dev/kmsg -- some Docker versions log-spam without it; see PROXMOX-LXC.md"
    fi
fi

# GPU: only wire /dev/dri through if it is actually there, otherwise the
# container fails to start instead of falling back to software rendering.
GPU=0
DRINODE=""
if [[ -d /dev/dri ]]; then
    for node in /dev/dri/renderD*; do
        [[ -e "$node" ]] || continue
        GPU=1; DRINODE="$node"; break
    done
fi
if [[ $GPU -eq 1 ]]; then
    info "GPU render node: $DRINODE (hardware OpenGL)"
else
    warn "no /dev/dri render node -- the 3D viewport will use llvmpipe (software, slow)"
fi

HOST_UID="$(id -u "${SUDO_USER:-$USER}" 2>/dev/null || id -u)"
HOST_GID="$(id -g "${SUDO_USER:-$USER}" 2>/dev/null || id -g)"
TZ_VALUE="$(cat /etc/timezone 2>/dev/null || readlink -f /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||' || echo UTC)"
info "PUID/PGID: ${HOST_UID}/${HOST_GID}   TZ: ${TZ_VALUE}"

# ---------------------------------------------------------------- docker ---
head1 "2/6  Docker"

install_docker_official_apt() {
    # Docker's own repo, key pinned to a keyring file -- no curl|sh anywhere.
    local codename="${OS_VERSION_CODENAME:-}" distro="$OS_ID"
    [[ "$distro" == linuxmint || "$distro" == pop ]] && distro=ubuntu
    [[ -n "$codename" ]] || die "cannot determine the APT codename for this system"

    $SUDO install -m 0755 -d /etc/apt/keyrings
    $SUDO apt-get update
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl
    $SUDO curl -fsSL --proto '=https' --tlsv1.2 \
        "https://download.docker.com/linux/${distro}/gpg" \
        -o /etc/apt/keyrings/docker.asc
    $SUDO chmod a+r /etc/apt/keyrings/docker.asc
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
        "$(dpkg --print-architecture)" "$distro" "$codename" \
        | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
    $SUDO apt-get update
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_docker() {
    case "$OS_ID" in
        debian|ubuntu|linuxmint|pop|raspbian)
            install_docker_official_apt ;;
        arch|endeavouros|manjaro|cachyos)
            $SUDO pacman -Sy --needed --noconfirm docker docker-compose docker-buildx ;;
        fedora|rhel|centos|rocky|almalinux)
            $SUDO dnf -y install dnf-plugins-core
            $SUDO dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo || true
            $SUDO dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin ;;
        opensuse*|sles)
            $SUDO zypper --non-interactive install docker docker-compose ;;
        alpine)
            $SUDO apk add --no-cache docker docker-cli-compose ;;
        *)
            die "unsupported distribution '$OS_ID' -- install Docker manually, then re-run with --skip-docker" ;;
    esac
}

if command -v docker >/dev/null 2>&1; then
    info "docker present: $(docker --version)"
elif [[ $SKIP_DOCKER -eq 1 ]]; then
    die "docker is missing and installation was skipped"
else
    warn "docker is not installed"
    ask "Install Docker now?" y || die "aborted -- Docker is required"
    install_docker
fi

if ! docker info >/dev/null 2>&1; then
    info "starting the Docker daemon"
    if command -v systemctl >/dev/null 2>&1; then
        $SUDO systemctl enable --now docker || true
    elif command -v rc-service >/dev/null 2>&1; then
        $SUDO rc-update add docker default || true
        $SUDO rc-service docker start || true
    fi
fi
docker info >/dev/null 2>&1 || {
    if [[ -n "${SUDO_USER:-}" || $EUID -ne 0 ]] && ! id -nG | tr ' ' '\n' | grep -qx docker; then
        warn "your user is not in the 'docker' group"
        # Membership in 'docker' is equivalent to root on this host. Say so.
        warn "adding a user to 'docker' grants them root-equivalent access to this machine"
        if ask "Add ${SUDO_USER:-$USER} to the docker group?" n; then
            $SUDO usermod -aG docker "${SUDO_USER:-$USER}"
            warn "log out and back in (or run: newgrp docker), then re-run this script"
            exit 0
        fi
    fi
    die "cannot talk to the Docker daemon"
}

DC=(docker compose)
docker compose version >/dev/null 2>&1 || {
    command -v docker-compose >/dev/null 2>&1 || die "docker compose plugin not found"
    DC=(docker-compose)
}

# ------------------------------------------------------------------ auth ---
head1 "3/6  Web access"

if [[ -z "$AUTH" ]]; then
    cat <<'EXPLAIN'
The web desktop gives whoever opens it full control of the slicer: loading and
saving files anywhere the container can reach, and talking to your printers.

  1) Password, reachable from the LAN        (recommended for a server/LXC)
  2) No password, this machine only          (loopback 127.0.0.1)
  3) No password, reachable from the LAN     (anyone on your network can use it)

EXPLAIN
    choice=""
    while [[ ! "$choice" =~ ^[123]$ ]]; do
        read -r -p "Choose 1, 2 or 3 [1]: " choice </dev/tty || choice=1
        choice="${choice:-1}"
    done
    case "$choice" in
        1) AUTH=yes; BIND="${BIND:-0.0.0.0}" ;;
        2) AUTH=no;  BIND="${BIND:-127.0.0.1}" ;;
        3) AUTH=no;  BIND="${BIND:-0.0.0.0}" ;;
    esac
fi

# Fill in whichever half the flags left unset, erring towards the closed door.
[[ -n "$BIND" ]] || { [[ "$AUTH" == yes ]] && BIND=0.0.0.0 || BIND=127.0.0.1; }

if [[ "$AUTH" == no && "$BIND" == "0.0.0.0" ]]; then
    warn "NO PASSWORD + REACHABLE FROM THE LAN"
    warn "Every device on your network will be able to open the slicer, browse the"
    warn "container's filesystem through its file dialogs, and control your printers."
    warn "Never port-forward this to the internet."
    if [[ $ASSUME_YES -eq 0 ]]; then
        read -r -p "Type YES to accept: " confirm </dev/tty || confirm=""
        [[ "$confirm" == "YES" ]] || die "aborted"
    fi
fi

if [[ "$AUTH" == yes && -z "$PASSWORD" ]]; then
    if command -v openssl >/dev/null 2>&1; then
        PASSWORD="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
    else
        PASSWORD="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-20)"
    fi
    GENERATED_PASSWORD=1
fi

# ----------------------------------------------------------------- files ---
head1 "4/6  Configuration"

MODELS_DIR="${MODELS_DIR:-./models}"
mkdir -p config models

umask 077
{
    echo "# Generated by install.sh on $(date -Is). Container-side environment."
    echo "PUID=${HOST_UID}"
    echo "PGID=${HOST_GID}"
    echo "TZ=${TZ_VALUE}"
    echo
    if [[ "$AUTH" == yes ]]; then
        echo "# nginx basic auth. Removing these two lines disables it entirely;"
        echo "# an empty PASSWORD= would enable auth with an empty password."
        echo "CUSTOM_USER=${WEB_USER}"
        echo "PASSWORD=${PASSWORD}"
    else
        echo "# No basic auth: CUSTOM_USER/PASSWORD are deliberately absent."
    fi
    echo
    echo "BIND_ADDRESS=${BIND}"
    [[ "$PORT" != 3000 ]]        && echo "CUSTOM_PORT=${PORT}"
    [[ "$HTTPS_PORT" != 3001 ]]  && echo "CUSTOM_HTTPS_PORT=${HTTPS_PORT}"
    echo
    [[ $GPU -eq 1 ]] && echo "DRINODE=${DRINODE}"
    echo
    echo "WATCHDOG_MIN_UPTIME=20"
    echo "WATCHDOG_MAX_DELAY=60"
    echo "WATCHDOG_MAX_LAUNCHES=0"
} > runtime.env
chmod 600 runtime.env
info "wrote runtime.env (mode 600)"

[[ -f .env ]] || { printf 'ASN_VERSION=\nMODELS_DIR=%s\n' "$MODELS_DIR" > .env; }

{
    echo "# Generated by install.sh on $(date -Is). Do not edit -- re-run the script."
    echo "services:"
    echo "  anycubic-slicer:"
    if [[ "$NETWORK" == bridge ]]; then
        echo "    network_mode: bridge"
        echo "    ports:"
        if [[ "$BIND" == "0.0.0.0" ]]; then
            echo "      - \"${PORT}:3000\""
            echo "      - \"${HTTPS_PORT}:3001\""
        else
            echo "      - \"${BIND}:${PORT}:3000\""
            echo "      - \"${BIND}:${HTTPS_PORT}:3001\""
        fi
    fi
    if [[ $GPU -eq 1 ]]; then
        echo "    devices:"
        echo "      - /dev/dri:/dev/dri"
    fi
} > docker-compose.override.yml
info "wrote docker-compose.override.yml (network: ${NETWORK}, gpu: $([[ $GPU -eq 1 ]] && echo yes || echo no))"

# ----------------------------------------------------------------- build ---
head1 "5/6  Build and start"

if [[ $SKIP_BUILD -eq 0 ]]; then
    "${DC[@]}" build
fi
"${DC[@]}" up -d --force-recreate

# --------------------------------------------------------------- summary ---
head1 "6/6  Ready"

if [[ "$BIND" == "127.0.0.1" ]]; then
    URL_HOST="localhost"
else
    # `hostname -I` does not exist on inetutils systems (Arch, Alpine).
    URL_HOST="$(ip -4 -o addr show scope global 2>/dev/null | awk 'NR==1{split($4,a,"/"); print a[1]}')"
    URL_HOST="${URL_HOST:-$(hostname 2>/dev/null || echo localhost)}"
fi

echo
printf '  %sURL%s        http://%s:%s\n' "$B" "$N" "$URL_HOST" "$PORT"
printf '             https://%s:%s  (self-signed certificate)\n' "$URL_HOST" "$HTTPS_PORT"
if [[ "$AUTH" == yes ]]; then
    printf '  %sUser%s       %s\n' "$B" "$N" "$WEB_USER"
    printf '  %sPassword%s   %s\n' "$B" "$N" "$PASSWORD"
    [[ "${GENERATED_PASSWORD:-0}" == 1 ]] && \
    printf '             (generated; it is stored in runtime.env, mode 600)\n'
else
    printf '  %sAuth%s       none\n' "$B" "$N"
fi
printf '  %sBound to%s   %s\n' "$B" "$N" "$BIND"
echo
echo "  Models directory   ${MODELS_DIR}  ->  /config/models in the slicer"
echo "  Logs               ${DC[*]} logs -f"
echo "  Watchdog log       config/watchdog.log"
echo "  Stop respawning    docker exec anycubic-slicer touch /config/.watchdog-off"
echo "  Reconfigure        ./install.sh"
echo
