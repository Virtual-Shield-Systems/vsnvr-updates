#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# VS NVR public installer (non-destructive)
# ═══════════════════════════════════════════════════════════════════
# For a Linux machine; when Docker is missing it offers to install it (Docker's own
# script, https://get.docker.com). On an interactive terminal it also
# offers to mount an EXISTING recording filesystem you select, or to reserve space
# for recordings in a file on the system disk; it NEVER partitions
# or formats a disk, rewrites network config, touches SSH, enables/resets a
# firewall, or creates users. Run non-interactively (piped, no terminal) it makes
# no such offer and instead requires the drive already mounted (--recording-mount),
# preserving the original hands-off behavior.
#
# It runs as root (writes /etc/systemd/system and /etc/fstab, talks to Docker).
# What it can change: the /opt/vs-nvr stack directory, the vs-nvr systemd unit, and
# up to two installer-owned /etc/fstab lines — the recording-parent rshared bind,
# and (only when you pick a drive or reserved space) a mount line for
# /mnt/recordings; reserved space adds its file, /var/lib/vs-nvr/recordings.img.
# If you agree at its prompt, it also keeps a local-time hardware clock in UTC;
# uninstall leaves that in place, as it leaves Docker when the installer installed
# it. Every other host change is recorded verbatim in
# /opt/vs-nvr/install-manifest so uninstall.sh can reverse EXACTLY what was added
# and nothing a user owns; it also
# drops uninstall.sh + factory-reset.sh there (sudo /opt/vs-nvr/uninstall.sh).
#
# Usage (public one-liner):
#   curl -fsSL <install-url> | sudo bash                       # interactive: pick the drive
#   curl -fsSL <install-url> | sudo bash -s -- --recording-mount /mnt/recordings
# or, downloaded and inspected first (the safer form):
#   curl -fsSL <install-url> -o install.sh && sudo bash install.sh [options]
#
# Options: see usage() below, or run with --help.
# ═══════════════════════════════════════════════════════════════════

# One brace group: bash parses it whole before running any of it, so a download
# cut off mid-pipe is a syntax error instead of a partially executed installer.
# Piped, it is not a file on disk, so every stack file comes from the image.
{
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; GRAY='\033[0;90m'; NC='\033[0m'

# On a terminal (FANCY=1) each step is one live status line, the commands' own
# output goes to $LOG_FILE, and its last lines are shown if the install fails.
# Anything else (a pipe, the Windows installer, setup-nvr.sh) gets the plain
# output, whose "== step ==" and "[!] " lines install.ps1 parses.
FANCY=0
LOG_FILE=/var/log/vs-nvr-install.log
STATUS_PID=""; STEP_LABEL=""; STEP_DETAIL=""; STEP_START=0; DL_IF=""; DL_RX=""; DL_TOTAL=""; FAIL_SHOWN=""

say() { # a line for the person installing; in a fancy run it goes above the status line
  if [ "$FANCY" = 1 ]; then
    printf '\r\033[K%b\n' "$1" >&3
    printf '%b\n' "$1" >> "$LOG_FILE"
  else
    echo -e "$1"
  fi
}
log()  { say "${GREEN}[✓]${NC} $1"; }
warn() { say "${YELLOW}[!]${NC} $1"; }
err()  { say "${RED}[✗]${NC} $1" >&2; }
step() {
  if [ "$FANCY" = 1 ]; then
    printf '\n== %s ==\n' "$1"
    STEP_LABEL="$1"; STEP_DETAIL=""; STEP_START=$SECONDS; DL_RX=""; DL_TOTAL=""
    case "$1" in Downloading*) DL_RX="$(rx_bytes)" ;; esac
    status_start
  else
    echo -e "\n${CYAN}== $1 ==${NC}"
  fi
}
abort() {
  if [ "$FANCY" = 1 ] && [ "$BASHPID" = "$$" ]; then status_stop; show_log_tail; fi
  err "$1"; exit 1
}

rx_bytes() { cat "/sys/class/net/${DL_IF:-lo}/statistics/rx_bytes" 2>/dev/null || echo 0; }
# download_size REF — gives the status line a total for this download: the size of
# REF's layers for this machine, from its registry manifest, as install.ps1 reads
# it. Without one the line shows the MB received.
download_size() {
  [ "$FANCY" = 1 ] || return 0
  local arch
  case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; *) return 0 ;; esac
  DL_TOTAL="$(timeout 15 docker manifest inspect -v "$1" 2>/dev/null | awk -v want="$arch" '
    /"architecture":/ { a = $2; gsub(/[",]/, "", a); arch = a }
    /"layers": \[/ { inl = 1; sum = 0; next }
    inl && /^[[:space:]]*]/ { inl = 0; if (!found && (arch == want || arch == "")) { total = sum; found = 1 }; arch = ""; next }
    inl && /"size":/ { n = $2; gsub(/,/, "", n); sum += n }
    END { if (found && total > 0) printf "%.0f\n", total }' || true)"
  case "$DL_TOTAL" in *[!0-9]*) DL_TOTAL="" ;; esac
  status_start
}
# The live status line, redrawn on the terminal until status_stop kills it.
status_loop() {
  set +e
  local cols frame=0 pos i bar text t got pct unpacking
  cols="$(stty size < /dev/tty 2>/dev/null)"; cols="${cols#* }"
  case "$cols" in ''|*[!0-9]*) cols=80 ;; esac
  [ "$cols" -ge 40 ] || cols=80
  printf '\033[?25l' >&3
  while kill -0 $$ 2>/dev/null; do
    got=0; pct=-1; unpacking=0
    if [ -n "$DL_RX" ] && [ -z "$STEP_DETAIL" ]; then
      got=$(($(rx_bytes) - DL_RX)); [ "$got" -ge 0 ] || got=0
      # Once it has all arrived, Docker still unpacks the layers, with no progress to show.
      if [ -n "$DL_TOTAL" ] && [ "$got" -ge "$DL_TOTAL" ]; then
        unpacking=1
      elif [ -n "$DL_TOTAL" ]; then
        pct=$((got * 100 / DL_TOTAL))
      fi
    fi
    # Filled to the share done when it is known, else a block sweeping back and forth.
    pos=$((frame % 32)); [ "$pos" -le 16 ] || pos=$((32 - pos))
    bar=""
    for ((i = 0; i < 20; i++)); do
      if [ "$pct" -ge 0 ]; then
        if [ "$i" -lt $((pct / 5)) ]; then bar+="█"; else bar+="░"; fi
      elif [ "$i" -ge "$pos" ] && [ "$i" -lt $((pos + 4)) ]; then bar+="█"; else bar+="░"; fi
    done
    text=""
    [ "$pct" -lt 0 ] || printf -v text ' %3d%% ' "$pct"
    printf -v t ' %d:%02d  %s' $(((SECONDS - STEP_START) / 60)) $(((SECONDS - STEP_START) % 60)) "$STEP_LABEL"
    text+="$t"
    if [ -n "$STEP_DETAIL" ]; then
      text+=": $STEP_DETAIL"
    elif [ "$unpacking" = 1 ]; then
      text+=": unpacking"
    elif [ "$pct" -ge 0 ]; then
      text+=": $((got / 1000000)) of $((DL_TOTAL / 1000000)) MB"
    elif [ "$got" -ge 1000000 ]; then
      text+=": about $((got / 1000000)) MB received"
    fi
    printf '\r\033[36m%s\033[0m%s\033[K' "$bar" "${text:0:$((cols - 21))}" >&3
    frame=$((frame + 1))
    sleep 0.2
  done
}
status_start() {
  status_stop
  [ "$FANCY" = 1 ] && [ -n "$STEP_LABEL" ] || return 0
  status_loop &
  STATUS_PID=$!
}
# Also before every prompt, which the status line would overwrite.
status_stop() {
  [ -n "$STATUS_PID" ] || return 0
  kill "$STATUS_PID" 2>/dev/null || true
  wait "$STATUS_PID" 2>/dev/null || true
  STATUS_PID=""
  printf '\r\033[K\033[?25h' >&3
}
status_note() { STEP_DETAIL="$1"; [ -z "$STATUS_PID" ] || status_start; }
show_log_tail() {
  FAIL_SHOWN=1
  grep -v '^[[:space:]]*$' "$LOG_FILE" 2>/dev/null | tail -n 15 | while IFS= read -r l; do printf "${GRAY}  %s${NC}\n" "$l" >&3; done
}
# EXIT: stop the status line and, after a failure, show what led to it.
ui_finish() {
  [ "$FANCY" = 1 ] || return 0
  status_stop
  [ "$1" != 0 ] || return 0
  if [ "$1" = 130 ]; then
    err "Cancelled."
  elif [ -z "$FAIL_SHOWN" ]; then
    show_log_tail
    err "The install stopped (exit $1)."
  fi
  printf 'Full output: %s\n' "$LOG_FILE" >&3
}
trap 'ui_finish $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Fixed on purpose: the vs-nvr.service unit references /opt/vs-nvr verbatim, and
# the Compose project identity (and therefore the data volume name) derives from
# this directory's basename. A configurable path would fork both.
INSTALL_DIR="/opt/vs-nvr"
RECORDING_MOUNT_DEFAULT="/mnt/recordings"
# /etc/fstab options for the recording mount. x-vsnvr.owned=1 is an inert ownership
# marker — a userspace "x-" comment option, ignored by mount(8) and the kernel and
# passed through by systemd's fstab generator — so a later install or uninstall can
# positively identify a mount THIS installer created and safely reverse it.
VSNVR_FSTAB_OWN_MARK="x-vsnvr.owned=1"
VSNVR_FSTAB_OPTS="defaults,nofail,x-systemd.device-timeout=10s,${VSNVR_FSTAB_OWN_MARK}"
# A box with no spare drive records to space reserved on the system disk: an ext4
# filesystem in this preallocated file, loop-mounted at the recording mount.
RESERVE_IMAGE=/var/lib/vs-nvr/recordings.img
RESERVE_MIN_GB=40
UPDATE_URL_DEFAULT="https://raw.githubusercontent.com/Virtual-Shield-Systems/vsnvr-updates/main/manifest.json"

# The image we pull and extract everything from. Defaults to the public :latest
# tag; override with --image (or VS_NVR_IMAGE=) to pin an immutable digest, which
# is the recommended trust anchor for a signed public release. Whatever we pull is
# retagged to COMPOSE_IMAGE_REF below, so the extracted compose/unit/attester and
# the running container all come from ONE image.
VS_NVR_IMAGE="${VS_NVR_IMAGE:-ghcr.io/virtual-shield-systems/vs-nvr@sha256:76c35eb801147317897d1cb590685f71d84ebdc6becbaeccfc34c7b74c5d20b4}"
# The reference the bundled docker-compose.yml names; the pulled image is retagged
# to this so `docker compose` uses exactly the image we extracted from (rather than
# a second `docker compose pull` that could fetch a newer :latest).
COMPOSE_IMAGE_REF="ghcr.io/virtual-shield-systems/vs-nvr:latest"

# The AI-detection sidecar image (amd64-only). Same pull+verify+retag treatment as
# the main image so the whole bundle is pinned coherently. When pinning digests, pin
# this one from the same release as VS_NVR_IMAGE; nothing checks the pairing.
VS_NVR_AIDETECT_IMAGE="${VS_NVR_AIDETECT_IMAGE:-ghcr.io/virtual-shield-systems/vs-nvr-aidetect@sha256:6aa04fddfa1f8e114319a9b30c3da72ac43db78609cb6e892495b7183e468d28}"
COMPOSE_AIDETECT_IMAGE_REF="ghcr.io/virtual-shield-systems/vs-nvr-aidetect:latest"

# The media-plane sidecar image — the WAN-facing WebRTC data-channel peer that
# carries remote playback (docs/media-plane.md). Same pull+verify+retag
# treatment, and like the others a signed release bakes the paired digest here.
VS_NVR_MEDIADC_IMAGE="${VS_NVR_MEDIADC_IMAGE:-ghcr.io/virtual-shield-systems/vs-nvr-mediadc@sha256:869e50f683417a95c2dc21f9fe7db5f2c8d197f2d4a2512cdb49379242cd8375}"
COMPOSE_MEDIADC_IMAGE_REF="ghcr.io/virtual-shield-systems/vs-nvr-mediadc:latest"
# Fixed in docker-compose.yml: the sidecar advertises this port as its ICE host
# candidate, so host and container sides must match. Reported in the closing notes.
MEDIA_DC_PORT=8556

# Every image must carry a keyless cosign signature from the release workflow on a
# vX.Y.Z tag (release.yml signs them before publishing a release); any failure
# aborts. cosign runs from a digest-pinned container, so the host needs only
# Docker. --no-verify is an explicit dev bypass.
COSIGN_IMAGE="ghcr.io/sigstore/cosign/cosign:v3.1.3@sha256:9e5c2f2edc34351160407ca3416c61855bdf9403c3c5936e0f0be7fc261611b8"
COSIGN_IDENTITY_REGEXP='^https://github\.com/Virtual-Shield-Systems/vs-nvr/\.github/workflows/release\.yml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$'
COSIGN_OIDC_ISSUER="https://token.actions.githubusercontent.com"
NO_VERIFY=0
NO_AIDETECT=0            # --no-aidetect: install without the AI-detection sidecar
INSTALL_DOCKER=0         # --install-docker: install Docker Engine without asking when it is missing

RECORDING_MOUNT=""       # set only if --recording-mount was passed
UPDATE_URL_ARG=""        # set only if --update-url was passed
MAX_STORAGE_GB=0         # 0 = size the cap from the recording drive
RETENTION_DAYS=30

usage() {
  cat <<USAGE
VS NVR public installer

Requires: Linux, root (sudo), Docker Engine + Compose plugin (offered when
missing), and a recording drive. On an interactive terminal the installer offers to
mount an existing formatted filesystem you pick (at $RECORDING_MOUNT_DEFAULT), or to
reserve space for recordings on the system disk when it has no spare drive. Run
non-interactively, it instead requires the drive ALREADY mounted at a path whose last
component is "recordings".

Usage: sudo bash install.sh [options]
  --recording-mount PATH   Use this ALREADY-mounted recording directory (default:
                           $RECORDING_MOUNT_DEFAULT); disables the interactive
                           drive picker. Its basename must be exactly "recordings".
  --no-aidetect            Install without the AI-detection sidecar (fresh install
                           only). Default: on (amd64 hosts only; auto-skipped
                           elsewhere). The engine is idle until a camera enables it.
  --aidetect-image REF     AI-detection sidecar image (default: the public :latest
                           tag). Pin a digest for a signed release.
  --update-url URL         Auto-update manifest URL (default: the VS NVR manifest).
  --max-storage-gb N       Recording storage cap, fresh install only (default: sized
                           from the recording drive).
  --retention-days N       Recording retention, fresh install only (default: $RETENTION_DAYS).
  --image REF              Image to pull + extract the stack from (default: the
                           public :latest tag). Pin a digest for a signed release.
  --install-docker         Install Docker Engine without asking when it is missing,
                           with Docker's install script (https://get.docker.com).
  --no-verify             Skip signature verification (explicit dev bypass).
  -h, --help               Show this help.

Never partitions or formats a disk, rewrites network config, touches SSH, enables a
firewall, or creates users. The only disk it will mount is an existing formatted
filesystem you explicitly select from the interactive picker. Reserved space is a
file it creates and formats ($RESERVE_IMAGE).
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --recording-mount) RECORDING_MOUNT="$2"; shift 2 ;;
    --no-aidetect)     NO_AIDETECT=1; shift ;;
    --install-docker)  INSTALL_DOCKER=1; shift ;;
    --aidetect-image)  VS_NVR_AIDETECT_IMAGE="$2"; shift 2 ;;
    --update-url)      UPDATE_URL_ARG="$2"; shift 2 ;;
    --max-storage-gb)  MAX_STORAGE_GB="$2"; shift 2 ;;
    --retention-days)  RETENTION_DAYS="$2"; shift 2 ;;
    --image)           VS_NVR_IMAGE="$2"; shift 2 ;;
    --no-verify)       NO_VERIFY=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) err "Unknown option: $1"; echo; usage; exit 1 ;;
  esac
done

# Validate option values before they reach config.json / .env.
case "$MAX_STORAGE_GB" in ''|*[!0-9]*) abort "--max-storage-gb must be a non-negative integer (got: $MAX_STORAGE_GB)" ;; esac
case "$RETENTION_DAYS" in ''|*[!0-9]*) abort "--retention-days must be a positive integer (got: $RETENTION_DAYS)" ;; esac
if [ -n "$UPDATE_URL_ARG" ]; then
  case "$UPDATE_URL_ARG" in *[[:space:]]*) abort "--update-url must not contain whitespace (got: $UPDATE_URL_ARG)" ;; esac
fi

# primary_ip — this box's address on its default route, empty when there is none.
primary_ip() { ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1 || true; }

if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && [ "$(id -u)" -eq 0 ]; then
  FANCY=1
  (umask 077; : > "$LOG_FILE")
  exec 3>&1 >> "$LOG_FILE" 2>&1
  DL_IF="$(ip route get 1.1.1.1 2>/dev/null | grep -oP ' dev \K\S+' | head -1 || true)"
fi
say ""
say "  VS NVR installer"
say "${CYAN}  ──────────────────────────────────────────────${NC}"
say "  Sets up the VS NVR recorder. About 10 minutes, most of it downloading."

# ── Interactivity: prompt from the controlling terminal, not stdin ──
# Under `curl … | sudo bash` the script itself is on stdin, so prompts must read
# from /dev/tty. When there is no terminal (piped/CI), TTY_OK=0 and the installer
# never prompts — it falls back to flags/defaults, exactly as before.
TTY_OK=0
if [ -r /dev/tty ] && { : < /dev/tty; } 2>/dev/null; then TTY_OK=1; fi

tty_say()   { status_stop; printf '%b\n' "$1" > /dev/tty; }
ask_yesno() { # ask_yesno PROMPT — reads y/N from the terminal; 0 = yes
  local ans=""
  status_stop
  printf '%b' "$1" > /dev/tty
  read -r ans < /dev/tty || return 1
  case "$ans" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# may_install_docker — whether Docker Engine may be installed: asks (default yes)
# unless --install-docker was passed, and is false when it may not ask.
may_install_docker() {
  [ "$INSTALL_DOCKER" != 1 ] || return 0
  [ "$TTY_OK" = 1 ] || return 1
  local ans=""
  status_stop
  printf '%b' "Docker Engine isn't installed. Install it from Docker's official packages? [Y/n] " > /dev/tty
  read -r ans < /dev/tty || return 1
  case "$ans" in ''|[yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# install_docker installs Docker Engine with Docker's own install script, which adds
# Docker's package repository: distro packages are often older than Engine 27 or lack
# the Compose plugin. Its output goes to $LOG_FILE.
install_docker() {
  command -v curl >/dev/null 2>&1 || abort "curl not found — it is required to download Docker's install script. Install curl, then re-run."
  step "Installing Docker Engine"
  local script
  script="$(mktemp)"
  curl -fsSL https://get.docker.com -o "$script" || { rm -f "$script"; abort "Could not download Docker's install script from https://get.docker.com."; }
  if ! (umask 077; sh "$script" >> "$LOG_FILE" 2>&1); then
    rm -f "$script"
    [ "$FANCY" = 1 ] || tail -n 15 "$LOG_FILE"
    abort "Docker's install script failed (full output: $LOG_FILE). Install Docker yourself: https://docs.docker.com/engine/install/"
  fi
  rm -f "$script"
  # docker_ready reports a Docker that installed but did not start.
  if command -v systemctl >/dev/null 2>&1; then systemctl enable --now docker >/dev/null 2>&1 || true; fi
  log "Docker Engine installed"
}

docker_ready() {
  docker compose version >/dev/null 2>&1 || abort "The Docker Compose plugin is not installed. Install the 'docker-compose-plugin' package, then re-run."
  docker info >/dev/null 2>&1 || abort "Cannot reach the Docker daemon. Is it running (systemctl start docker)?"
  # 27 is the first Engine that assigns the media sidecar's IPv6 network a subnet itself.
  DOCKER_VERSION="$(docker version --format '{{.Server.Version}}' 2>/dev/null)"
  [ "${DOCKER_VERSION%%.*}" -ge 27 ] 2>/dev/null || abort "Docker Engine 27 or newer is required (found ${DOCKER_VERSION:-unknown}). Upgrade it: https://docs.docker.com/engine/install/"
}

# ── Preflight: check; Docker is the one prerequisite it offers to install ──
step "Checking prerequisites"
[ "$(uname -s)" = "Linux" ] || abort "VS NVR runs on Linux only (this is $(uname -s))."
[ "$(id -u)" -eq 0 ] || abort "Run as root: sudo bash install.sh"
command -v realpath >/dev/null 2>&1 || abort "realpath not found (install coreutils) — it is required to canonicalize the recording path."
# A missing Docker is installed after the recording question, so every question
# comes before the long wait.
DOCKER_MISSING=0
if command -v docker >/dev/null 2>&1; then
  docker_ready
  log "Linux, Docker, and Compose present"
else
  may_install_docker || abort "Docker Engine not found. Install it first (https://docs.docker.com/engine/install/), or re-run with --install-docker."
  DOCKER_MISSING=1
  log "Linux present; Docker Engine will be installed after choosing where to record"
fi

RERUN=false
[ -f "$INSTALL_DIR/.env" ] && RERUN=true

# Sidecar enablement is persisted in .env (COMPOSE_PROFILES); a re-run preserves it.
if [ "$RERUN" = true ] && [ "$NO_AIDETECT" = 1 ]; then
  abort "This box is already installed; --no-aidetect cannot toggle the sidecar on a re-run. Remove the COMPOSE_PROFILES line from $INSTALL_DIR/.env and 'systemctl restart vs-nvr' to disable it."
fi

# has_intel_gpu — the host has an Intel GPU render node, the only kind hardware
# acceleration can use (the image ships Intel's VAAPI drivers; detection runs
# on OpenVINO). A host with only other GPUs installs as if it had none.
has_intel_gpu() {
  local n
  for n in /dev/dri/renderD*; do
    [ -c "$n" ] && [ "$(cat "/sys/class/drm/${n##*/}/device/vendor" 2>/dev/null)" = 0x8086 ] && return 0
  done
  return 1
}

# reserve_max_gb [HEADROOM] — the most a new reservation may take: the system
# disk's free space less 10% of the disk (at least 20 GB) and HEADROOM GB
# (default 10) for VS NVR's images and database. Checked again right before
# allocating with no headroom, as the images are on the disk by then.
reserve_max_gb() {
  local size avail margin headroom="${1:-10}"
  read -r size avail < <(df -P -B1M /var/lib | awk 'NR == 2 {print $2, $4}')
  size=$((size / 1024)); avail=$((avail / 1024))
  margin=$((size / 10)); [ "$margin" -ge 20 ] || margin=20
  echo $((avail - margin - headroom))
}
# kept_image_ok — a reservation an earlier uninstall kept: a plain ext4 file with
# VS NVR's label that nothing has attached.
kept_image_ok() {
  [ -f "$RESERVE_IMAGE" ] && [ ! -L "$RESERVE_IMAGE" ] &&
    [ "$(blkid -o value -s TYPE "$RESERVE_IMAGE" 2>/dev/null)" = ext4 ] &&
    [ "$(blkid -o value -s LABEL "$RESERVE_IMAGE" 2>/dev/null)" = vs-nvr-rec ] &&
    [ -z "$(losetup -j "$RESERVE_IMAGE" 2>/dev/null)" ]
}

# pick_recording_drive — interactive level-B picker: choose an EXISTING formatted
# filesystem to mount at $MOUNT_PATH. Selection + safety checks ONLY; the actual
# mount happens later (after the image is validated). Sets SELECTED_DEV /
# SELECTED_UUID / SELECTED_FSTYPE. Never formats or partitions.
pick_recording_drive() {
  command -v lsblk >/dev/null 2>&1 || abort "lsblk not found (install util-linux) — needed to list drives, or mount the drive yourself and pass --recording-mount."

  local dev type fstype uuid ro mnt size label model row i idx choice yn dup dup_skipped=0
  local -a devs=() uuids=() fstypes=() rows=()
  # Enumerate every block device by full path; query scalar fields ONE at a time
  # (never parse `lsblk -P` with eval — a crafted LABEL could inject). -d = do not
  # recurse, so each query returns a single value for exactly that device.
  while read -r dev type; do
    [ -n "$dev" ] || continue
    fstype="$(lsblk -dprno FSTYPE "$dev" 2>/dev/null)"
    [ -n "$fstype" ] || continue
    # Skip signatures that are not directly-mountable filesystems (level B does not
    # unlock/assemble LUKS, LVM, RAID, ZFS) and swap.
    case "$fstype" in
      swap|crypto_LUKS|LVM2_member|zfs_member|*_raid_member) continue ;;
    esac
    uuid="$(lsblk -dprno UUID "$dev" 2>/dev/null)"
    [ -n "$uuid" ] || continue                       # need a UUID to mount by it
    # A UUID shared by more than one attached device (e.g. a cloned disk) is
    # ambiguous for both `mount -U` and a boot-time `UUID=` fstab entry — skip it.
    dup="$(lsblk -prno UUID 2>/dev/null | grep -cxF "$uuid" || true)"
    if [ "${dup:-0}" -gt 1 ]; then dup_skipped=$((dup_skipped + 1)); continue; fi
    [ "$(lsblk -dprno RO "$dev" 2>/dev/null)" = "1" ] && continue   # read-only device
    mnt="$(lsblk -dprno MOUNTPOINT "$dev" 2>/dev/null)"
    [ -n "$mnt" ] && continue                        # already mounted (excludes / /boot swap)
    size="$(lsblk -dprno SIZE "$dev" 2>/dev/null)"
    label="$(lsblk -dprno LABEL "$dev" 2>/dev/null | tr -cd '[:print:]')"
    model="$(lsblk -dprno MODEL "$dev" 2>/dev/null | tr -cd '[:print:]')"
    devs+=("$dev"); uuids+=("$uuid"); fstypes+=("$fstype")
    rows+=("$(printf '%-14s %-8s %-6s %-16s %s' "$dev" "${size:-?}" "$fstype" "${label:-—}" "${model:-—}")")
  done < <(lsblk -prno NAME,TYPE 2>/dev/null)

  [ "$dup_skipped" -gt 0 ] && tty_say "Note: skipped $dup_skipped drive(s) with a duplicate UUID (e.g. a cloned disk) — they are ambiguous to mount by UUID; give one a fresh UUID or mount it yourself."

  # The last row records to space reserved on the system disk instead: a new
  # reservation, or the one an earlier install's uninstall kept, footage included.
  local reserve="" reserve_max
  reserve_max="$(reserve_max_gb)"
  if kept_image_ok; then
    reserve=kept
    rows+=("Recordings kept from an earlier install ($(($(stat -c %s "$RESERVE_IMAGE") >> 30)) GB, on the system disk)")
  elif [ -e "$RESERVE_IMAGE" ]; then
    tty_say "Note: $RESERVE_IMAGE exists but isn't usable VS NVR recording space, so it can't reserve space on the system disk. Move it away to get that option."
  elif [ "$reserve_max" -ge "$RESERVE_MIN_GB" ]; then
    reserve=new
    rows+=("Reserve space on the system disk (up to $reserve_max GB)")
  fi
  [ "${#rows[@]}" -gt 0 ] || abort "No drive to record to was found, and the system disk doesn't have room to reserve $RESERVE_MIN_GB GB (plus 10% of it, at least 20 GB, left free). Attach and format a drive, or free up space, then re-run. VS NVR never formats a drive for you."

  tty_say ""
  tty_say "Where should VS NVR record? What you pick is mounted at $MOUNT_PATH; a drive is not erased."
  [ "${#devs[@]}" -eq 0 ] || tty_say "$(printf '   %-3s %-14s %-8s %-6s %-16s %s' '#' 'DEVICE' 'SIZE' 'FS' 'LABEL' 'MODEL')"
  i=1
  for row in "${rows[@]}"; do tty_say "$(printf '   %-3s %s' "$i" "$row")"; i=$((i + 1)); done
  tty_say ""

  printf '%b' "Enter a number (1-${#rows[@]}), or blank to cancel: " > /dev/tty
  read -r choice < /dev/tty || abort "No selection — cancelled."
  case "$choice" in ''|*[!0-9]*) abort "No valid selection — cancelled." ;; esac
  { [ "$choice" -ge 1 ] && [ "$choice" -le "${#rows[@]}" ]; } || abort "Selection out of range — cancelled."

  idx=$((choice - 1))
  if [ "$idx" -ge "${#devs[@]}" ]; then
    RESERVE="$reserve"
    SELECTED_DEV="$RESERVE_IMAGE"; SELECTED_FSTYPE=ext4
  else
    SELECTED_DEV="${devs[$idx]}"; SELECTED_UUID="${uuids[$idx]}"; SELECTED_FSTYPE="${fstypes[$idx]}"
  fi

  # A drive already in fstab (by UUID or by target) is likely provisioned for
  # something else — do not add a second, conflicting entry.
  if [ -z "$RESERVE" ] && awk -v u="UUID=$SELECTED_UUID" '$1 !~ /^#/ && $1 == u {f=1} END{exit f?0:1}' /etc/fstab 2>/dev/null; then
    abort "$SELECTED_DEV (UUID=$SELECTED_UUID) already has an /etc/fstab entry. Resolve it and re-run, or mount it yourself and pass --recording-mount."
  fi
  if awk -v t="$MOUNT_PATH" '$1 !~ /^#/ && $2 == t {found=1} END{exit found?0:1}' /etc/fstab 2>/dev/null; then
    abort "/etc/fstab already has an entry for $MOUNT_PATH. Resolve it and re-run."
  fi
  # The mountpoint must be empty/absent so mounting does not shadow existing files.
  if [ -e "$MOUNT_PATH" ] && [ -n "$(ls -A "$MOUNT_PATH" 2>/dev/null)" ]; then
    abort "$MOUNT_PATH already exists and is not empty. Mounting would hide its contents; empty it or pick another path."
  fi

  local ans=""
  if [ "$RESERVE" = new ]; then
    tty_say ""
    tty_say "VS NVR reserves the space now, so other files filling the disk later can't take it."
    tty_say "The size can't change later; uninstalling frees it."
    while :; do
      printf '%b' "How many GB should it reserve ($RESERVE_MIN_GB-$reserve_max)? [$reserve_max] " > /dev/tty
      read -r ans < /dev/tty || abort "No size given — cancelled."
      RESERVE_GB="${ans:-$reserve_max}"
      case "$RESERVE_GB" in *[!0-9]*) ;; *) [ "$RESERVE_GB" -lt "$RESERVE_MIN_GB" ] || [ "$RESERVE_GB" -gt "$reserve_max" ] || break ;; esac
      tty_say "Pick a whole number from $RESERVE_MIN_GB to $reserve_max."
    done
    RESERVE_GB=$((10#$RESERVE_GB))
  fi
  if [ -n "$RESERVE" ]; then
    if [ "$RESERVE" = new ]; then
      printf '%b' "Reserve $RESERVE_GB GB in $RESERVE_IMAGE for recordings? [Y/n] " > /dev/tty
    else
      printf '%b' "Record to the kept space in $RESERVE_IMAGE again, footage included? [Y/n] " > /dev/tty
    fi
    read -r ans < /dev/tty || abort "Not confirmed — cancelled."
    case "$ans" in ''|[yY]|[yY][eE][sS]) return 0 ;; *) abort "Not confirmed — cancelled." ;; esac
  fi

  tty_say ""
  tty_say "About to use: $SELECTED_DEV  ($SELECTED_FSTYPE, UUID=$SELECTED_UUID)"
  tty_say "  • It will be MOUNTED at $MOUNT_PATH and persisted to /etc/fstab (nofail)."
  tty_say "  • It becomes the recording volume; VS NVR writes recordings and PRUNES"
  tty_say "    old ones on it to stay under the storage cap."
  tty_say "  • The drive is NOT erased — but any existing data on it shares the space."
  printf '%b' "Type 'yes' to confirm: " > /dev/tty
  read -r yn < /dev/tty || abort "Not confirmed — cancelled."
  [ "$yn" = "yes" ] || abort "Not confirmed — cancelled."
}

# stage_mount_adoption — the recording drive is ALREADY mounted at $MOUNT_PATH on a
# fresh install. If a PRIOR VS NVR install left the /etc/fstab entry that auto-mounts
# it, re-claim that mount into THIS install's manifest so a future uninstall can
# reverse it — without this, an uninstall/reinstall cycle orphans the fstab line
# forever. Selection only: sets MOUNT_PLAN=adopt + ADOPT_UUID + ADOPT_FSTAB_LINE and
# defers the manifest write to the commit point. A drive the operator mounted
# themselves (no fstab line carrying the ownership marker) is left unclaimed.
stage_mount_adoption() {
  local src uuid dup n line opts
  src="$(findmnt -no SOURCE --mountpoint "$MOUNT_PATH" 2>/dev/null || true)"
  [ -n "$src" ] || return 0
  uuid="$(lsblk -dprno UUID "$src" 2>/dev/null || true)"
  [ -n "$uuid" ] || return 0
  # A UUID shared by more than one attached device is ambiguous to unmount by — skip.
  dup="$(lsblk -prno UUID 2>/dev/null | grep -cxF "$uuid" || true)"
  [ "${dup:-0}" = 1 ] || return 0
  # Exactly one uncommented fstab line mounting THIS drive (by UUID) at $MOUNT_PATH.
  n="$(awk -v t="$MOUNT_PATH" -v u="UUID=$uuid" '$1 !~ /^#/ && $2==t && $1==u {c++} END{print c+0}' /etc/fstab 2>/dev/null || echo 0)"
  [ "$n" = 1 ] || return 0
  line="$(awk -v t="$MOUNT_PATH" -v u="UUID=$uuid" '$1 !~ /^#/ && $2==t && $1==u {print; exit}' /etc/fstab 2>/dev/null || true)"
  [ -n "$line" ] || return 0
  opts="$(printf '%s\n' "$line" | awk '{print $4}')"
  case ",${opts}," in
    *",${VSNVR_FSTAB_OWN_MARK},"*) ;;
    *) return 0 ;;
  esac
  MOUNT_PLAN=adopt
  ADOPT_UUID="$uuid"
  ADOPT_FSTAB_LINE="$line"
  log "Will adopt the existing VS NVR recording mount at $MOUNT_PATH into this install's manifest"
}

# ── Refuse to run alongside another VS NVR stack ───────────────────
# The compose file pins fixed container names (vs-nvr, vs-nvr-aidetect), which are
# global per host. A container by those names that this install does not own (a
# `deploy:dev` stack, another project, or a raw `docker run`) would collide at
# `docker compose create` — but only AFTER fstab/files/unit were changed. Detect
# it here, before any mutation. "Ours" requires BOTH compose ownership labels to
# match: project name AND canonicalized working directory (project alone or dir
# alone can be spoofed by a foreign `-p`/`--project-directory` combination).
canon() { realpath -m -- "$1" 2>/dev/null || printf '%s' "$1"; }
install_dir_canon="$(canon "$INSTALL_DIR")"

check_stack_conflicts() {
  local existing_names existing_vols name labels proj wd
  # Fail CLOSED: use one authoritative listing that aborts on a daemon/API error
  # rather than per-name `inspect || continue`, which would read any error (not just
  # "absent") as "no conflict" and fall through into the mutations. docker info
  # passed above, but the daemon can fail after it.
  if ! existing_names="$(docker ps -a --format '{{.Names}}')"; then
    abort "Could not list Docker containers to check for a conflicting VS NVR stack (Docker daemon error)."
  fi
  for name in vs-nvr vs-nvr-aidetect; do
    printf '%s\n' "$existing_names" | grep -qxF "$name" || continue
    # Present per the listing above, so a failed inspect here is an error (or a
    # just-removed container), not proof of absence — abort rather than assume ours.
    if ! labels="$(docker inspect --type container -f '{{ index .Config.Labels "com.docker.compose.project" }}|{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$name" 2>/dev/null)"; then
      abort "A container named '$name' exists but could not be inspected to verify ownership — refusing to proceed."
    fi
    proj="${labels%%|*}"; wd="${labels#*|}"
    [ "$proj" = "<no value>" ] && proj=""
    [ "$wd" = "<no value>" ] && wd=""
    if [ "$proj" != "vs-nvr" ] || [ "$(canon "$wd")" != "$install_dir_canon" ]; then
      abort "A container named '$name' already exists and is not this installer's (project='${proj:-<none>}', dir='${wd:-<none>}'). VS NVR pins fixed container names, so it cannot run alongside another stack. Remove it first — 'docker compose down' from that stack's directory for a Compose stack, or 'docker rm -f $name' for a plain container you have confirmed is disposable — or install on a clean machine."
    fi
  done

  # A leftover data volume from a prior /opt/vs-nvr install with no .env is
  # ambiguous: a "fresh" install would silently adopt its old database. Only guard
  # when this is NOT a recognized re-run (RERUN=true means the .env intends reuse).
  # Fail closed on a list error, same as the container check.
  if [ "$RERUN" = false ]; then
    if ! existing_vols="$(docker volume ls --format '{{.Name}}')"; then
      abort "Could not list Docker volumes to check for leftover VS NVR data (Docker daemon error)."
    fi
    if printf '%s\n' "$existing_vols" | grep -qxF vs-nvr_vs-nvr-data; then
      abort "The data volume 'vs-nvr_vs-nvr-data' exists but $INSTALL_DIR/.env does not, so this is neither a clean install nor a recognized re-run. Restore the prior .env to re-run, or 'docker volume rm vs-nvr_vs-nvr-data' for a genuinely fresh install."
    fi
  fi
}
if [ "$DOCKER_MISSING" = 0 ]; then check_stack_conflicts; fi

# ── Recording mount: resolve a plan (no host mutation here) ────────
# Non-mutating: decide WHERE to record and, if interactive, WHICH drive to mount —
# but do not mount or write /etc/fstab yet. The actual mount is deferred until
# after the image is pulled and validated, so a bad image aborts having touched
# nothing on the host.
step "Choosing where to record"

# env_value KEY FILE — read .env as attest-mount.sh and Compose do: last assignment
# wins, then a trailing " # comment" and one layer of quotes are stripped.
env_value() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$2" | tail -n1 \
    | sed -e 's/[[:space:]]#.*$//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

# ── Install manifest: records ONLY what THIS installer changes on the host ──
# uninstall.sh reverses exactly these records and nothing else. Fresh install only
# (a re-run keeps the original), written as each change succeeds. A caller may
# have seeded it with its own changes (setup-nvr.sh's recording drive), so it is
# appended to, never truncated. A fresh install always writes one, so one with no
# records tells uninstall.sh there is nothing to reverse.
MANIFEST_FILE="$INSTALL_DIR/install-manifest"
MANIFEST_STARTED=""
[ -f "$MANIFEST_FILE" ] && MANIFEST_STARTED=1
manifest_start() { # fresh install only
  [ "$RERUN" = false ] && [ -z "$MANIFEST_STARTED" ] || return 0
  mkdir -p "$INSTALL_DIR"
  {
    echo "# VS NVR install manifest — host changes THIS installer made."
    echo "# uninstall.sh reverses ONLY what is recorded here. Do not edit."
    echo "SCHEMA=1"
  } > "$MANIFEST_FILE"
  MANIFEST_STARTED=1
}
manifest_add() { # manifest_add RECORD — append one verbatim record (fresh install only)
  [ "$RERUN" = true ] && return 0
  manifest_start
  printf '%s\n' "$1" >> "$MANIFEST_FILE"
}

MOUNT_PLAN=none          # none = already mounted / rerun; mount = picker mounts; adopt = re-claim an existing VS NVR mount
SELECTED_DEV=""; SELECTED_UUID=""; SELECTED_FSTYPE=""
RESERVE=""; RESERVE_GB=""; NEW_IMAGE=""   # RESERVE: new | kept, when recording to reserved space
ADOPT_UUID=""; ADOPT_FSTAB_LINE=""

if [ "$RERUN" = true ]; then
  # Preserve the existing recording location; an explicit change is a migration
  # this installer does not perform (it would strand the prior binding).
  RECORDING_PATH="$(env_value RECORDING_PATH "$INSTALL_DIR/.env")"
  [ -n "$RECORDING_PATH" ] || abort "Existing $INSTALL_DIR/.env has no RECORDING_PATH; refusing to guess."
  MOUNT_PATH="${RECORDING_PATH%/}/recordings"
  if [ -n "$RECORDING_MOUNT" ]; then
    req="$(realpath "$RECORDING_MOUNT" 2>/dev/null || echo "$RECORDING_MOUNT")"
    [ "$req" = "$MOUNT_PATH" ] || \
      abort "This install already records at $MOUNT_PATH. Changing the recording mount is not supported here; reinstall fresh to move it."
  fi
else
  MOUNT_PATH="$(realpath "${RECORDING_MOUNT:-$RECORDING_MOUNT_DEFAULT}" 2>/dev/null || echo "${RECORDING_MOUNT:-$RECORDING_MOUNT_DEFAULT}")"
  [ "$(basename "$MOUNT_PATH")" = "recordings" ] || \
    abort "The recording mount's last path component must be exactly 'recordings' (got: $MOUNT_PATH). Mount the drive at e.g. $RECORDING_MOUNT_DEFAULT."
  RECORDING_PATH="$(dirname "$MOUNT_PATH")"
fi

# Guards applied to BOTH paths, so a preserved .env value gets the same scrutiny
# as a flag. Reject a root parent (a self-bind of / is far too broad) and any
# whitespace (an fstab bind entry is whitespace-delimited and cannot represent it).
[ "$RECORDING_PATH" != "/" ] || abort "The recording mount cannot sit directly under / (got: $MOUNT_PATH). Use e.g. $RECORDING_MOUNT_DEFAULT."
case "$MOUNT_PATH" in
  *[[:space:]]*|*'\'*) abort "The recording path must not contain whitespace or backslashes (got: $MOUNT_PATH) — a boot-time fstab bind entry cannot represent it. Mount the drive somewhere without them." ;;
esac

if findmnt --mountpoint "$MOUNT_PATH" >/dev/null 2>&1; then
  # Already mounted (a rerun, the operator mounted it themselves, or a prior VS NVR
  # install's fstab entry auto-mounted it): use as-is, never mounting anything. On a
  # fresh install, re-adopt a mount a prior VS NVR install left behind.
  log "Recording drive is already mounted at $MOUNT_PATH (parent: $RECORDING_PATH)"
  if [ "$RERUN" = false ]; then stage_mount_adoption; fi
elif [ "$RERUN" = false ] && [ "$TTY_OK" = 1 ] && [ -z "$RECORDING_MOUNT" ]; then
  # Nothing mounted at the default target and we have a terminal: offer the picker.
  # It selects + safety-checks a drive; the mount itself is deferred (see below).
  pick_recording_drive
  # Read-only parent-suitability precheck, so we never mount then abort in the
  # rshared step below (which refuses a separate, non-shared parent mount).
  if mountpoint -q "$RECORDING_PATH" 2>/dev/null && ! findmnt -no PROPAGATION --target "$RECORDING_PATH" 2>/dev/null | grep -q shared; then
    abort "$RECORDING_PATH is itself a separate mounted filesystem without shared propagation; a recording drive mounted under it cannot be made live-recovery-safe. Use a plain parent directory (e.g. under /mnt)."
  fi
  MOUNT_PLAN=mount
  case "$RESERVE" in
    new)  log "Will reserve $RESERVE_GB GB on the system disk after the downloads" ;;
    kept) log "Will record to the kept space on the system disk after the downloads" ;;
    *)    log "Will mount $SELECTED_DEV at $MOUNT_PATH after the downloads" ;;
  esac
else
  abort "$MOUNT_PATH is not a mounted drive. Mount your recording drive there first, then re-run — or run interactively (from a terminal) to pick a drive. (A public install that records nothing is worse than a clear stop.)"
fi

if [ "$DOCKER_MISSING" = 1 ]; then
  install_docker
  docker_ready
  check_stack_conflicts
fi

# ── AI-detection sidecar enablement ────────────────────────────────
# Auto-on by default: per-camera detection defaults OFF and the sidecar is
# request-driven, so it stays idle (RAM only) until a camera enables AI. amd64-only
# image. Fresh: --no-aidetect or a non-amd64 host disables it. Re-run: preserve
# whatever the existing .env's COMPOSE_PROFILES says (reconfig is a manual edit).
AIDETECT_ENABLED=0
if [ "$RERUN" = true ]; then
  # Exact, comma-delimited match so a value like "not-aidetect" does not count.
  case ",$(env_value COMPOSE_PROFILES "$INSTALL_DIR/.env")," in
    *,aidetect,*) AIDETECT_ENABLED=1 ;;
  esac
elif [ "$NO_AIDETECT" = 0 ]; then
  if [ "$(uname -m)" = "x86_64" ]; then
    AIDETECT_ENABLED=1
  else
    warn "The AI-detection sidecar is amd64-only; skipping it on this $(uname -m) host."
  fi
fi

# A pinned bundle must pin EVERY image from the same release. Warn if the main image
# is digest-pinned but a sidecar is left on a mutable tag (a mismatch risk); a
# hosted signed install bakes all paired digests. See docs/public-install.md.
case "$VS_NVR_IMAGE" in
  *@sha256:*)
    if [ "$AIDETECT_ENABLED" = 1 ]; then
      case "$VS_NVR_AIDETECT_IMAGE" in
        *@sha256:*) ;;
        *) warn "Main image is digest-pinned but the sidecar image is a mutable tag ($VS_NVR_AIDETECT_IMAGE). Pin BOTH from the same release (--aidetect-image ...@sha256:) to avoid a mismatched bundle." ;;
      esac
    fi
    case "$VS_NVR_MEDIADC_IMAGE" in
      *@sha256:*) ;;
      *) warn "Main image is digest-pinned but the media-plane sidecar image is a mutable tag ($VS_NVR_MEDIADC_IMAGE). Pin it from the same release (VS_NVR_MEDIADC_IMAGE=...@sha256:)." ;;
    esac ;;
esac

# resolve_repo_digest <image-ref> <repo-digests> — the canonical repo@sha256 ref
# cosign verifies, picked from the SAME inspect that yields the run identity
# (passed in, not re-read). If <image-ref> is already digest-pinned, use it;
# otherwise select the entry whose repository matches by EXACT prefix (not a
# substring), rejecting zero/ambiguous.
resolve_repo_digest() {
  local image_ref="$1" digests="$2"
  case "$image_ref" in
    *@sha256:*) printf '%s' "$image_ref"; return 0 ;;
  esac
  local repo last d match="" count=0
  repo="${image_ref%@*}"
  last="${repo##*/}"
  # Strip a tag only when the colon is in the last path segment, so a registry
  # port (host:5000/ns/image) is not mistaken for a tag.
  case "$last" in *:*) repo="${repo%:*}" ;; esac
  for d in $digests; do
    case "$d" in "${repo}@sha256:"*) match="$d"; count=$((count + 1)) ;; esac
  done
  [ "$count" = 1 ] || return 1
  printf '%s' "$match"
}

# verify_image <image-ref> <repo-digests> — enforce the image signature unless
# --no-verify. Fails CLOSED; the bypass warns loudly so an unverified install is
# never silent. The digest verified is resolved from the caller's single inspect,
# so it is bound to the same image that create/tag runs.
verify_image() {
  local image_ref="$1" repo_digests="$2"
  # The download is done; the rest of the step shows no byte count.
  DL_RX=""
  if [ "$NO_VERIFY" = 1 ]; then
    warn "Signature verification DISABLED via --no-verify — trusting $image_ref UNVERIFIED."
    return 0
  fi
  local ref
  ref="$(resolve_repo_digest "$image_ref" "$repo_digests")" || abort "Could not resolve a unique repo@digest for $image_ref to verify."
  status_note "checking its signature"
  docker run --rm "$COSIGN_IMAGE" verify \
    --certificate-identity-regexp "$COSIGN_IDENTITY_REGEXP" \
    --certificate-oidc-issuer "$COSIGN_OIDC_ISSUER" "$ref" >/dev/null \
    || abort "Signature verification FAILED for $ref — refusing to install."
  echo "Verified the signature of $ref"
  status_note ""
}

# ── Pull + verify + extract + validate the stack files BEFORE any host mutation ──
# Before the fstab/parent-bind changes, so a bad image aborts having touched nothing
# on the host — only Docker's local image/tag state, which is benign and reversible.
COSIGN_PRESENT=0
docker image inspect "$COSIGN_IMAGE" >/dev/null 2>&1 && COSIGN_PRESENT=1
step "Downloading VS NVR"
download_size "$VS_NVR_IMAGE"
docker pull "$VS_NVR_IMAGE" || abort "Failed to pull $VS_NVR_IMAGE."
# ONE inspect binds the run identity (IMAGE_ID) and the verified digest to the SAME
# image, so a concurrent pull can't retarget the tag between verify and create/tag.
# Everything downstream — verify, create, extract, retag — uses this captured pair.
img_info="$(docker inspect -f '{{.Id}}|{{range .RepoDigests}}{{.}} {{end}}' "$VS_NVR_IMAGE" 2>/dev/null)" || img_info=""
IMAGE_ID="${img_info%%|*}"
REPO_DIGESTS="${img_info#*|}"
[ -n "$IMAGE_ID" ] || abort "Could not resolve the pulled image ID for $VS_NVR_IMAGE."
# Verify the captured digest's signature before extracting from or running the image.
verify_image "$VS_NVR_IMAGE" "$REPO_DIGESTS"
EXTRACT_DIR="$(mktemp -d)"
cid=""
# Trap set before `docker create` so even a failed create cleans up the temp dir.
cleanup_extract() {
  [ -n "${cid:-}" ] && docker rm -f "$cid" >/dev/null 2>&1 || true
  rm -rf "${EXTRACT_DIR:-}" 2>/dev/null || true
  return 0
}
trap 'rc=$?; cleanup_extract; ui_finish $rc' EXIT
cid="$(docker create "$IMAGE_ID")" || abort "Could not create a temporary container to extract the stack files."
docker cp "$cid:/app/docker-compose.yml" "$EXTRACT_DIR/docker-compose.yml" || abort "Could not extract docker-compose.yml — not a valid VS NVR image?"
docker cp "$cid:/app/attest-mount.sh"    "$EXTRACT_DIR/attest-mount.sh"    || abort "Could not extract attest-mount.sh — not a valid VS NVR image?"
docker cp "$cid:/app/vs-nvr.service"     "$EXTRACT_DIR/vs-nvr.service"     || abort "Could not extract vs-nvr.service — not a valid VS NVR image?"
docker cp "$cid:/app/uninstall.sh"       "$EXTRACT_DIR/uninstall.sh"       || abort "Could not extract uninstall.sh — not a valid VS NVR image?"
docker cp "$cid:/app/factory-reset.sh"   "$EXTRACT_DIR/factory-reset.sh"   || abort "Could not extract factory-reset.sh — not a valid VS NVR image?"
docker cp "$cid:/app/mediadc-egress-firewall.sh" "$EXTRACT_DIR/mediadc-egress-firewall.sh" || abort "Could not extract mediadc-egress-firewall.sh — not a valid VS NVR image?"
docker rm -f "$cid" >/dev/null 2>&1 || true
cid=""
# The retag below aims the compose reference at this image, so the vs-nvr service
# must actually resolve to that reference. Resolve it structurally (not a raw
# substring, which a comment or another service could satisfy) — else a rogue
# --image could run a different image than the one we pulled and validated.
svc_image="$(docker compose -f "$EXTRACT_DIR/docker-compose.yml" config --images vs-nvr 2>/dev/null)" || svc_image=""
[ "$svc_image" = "$COMPOSE_IMAGE_REF" ] || \
  abort "The image's compose runs service vs-nvr from '${svc_image:-<unresolved>}', not $COMPOSE_IMAGE_REF — refusing (unexpected image)."
log "Downloaded VS NVR"

# ── Pull + verify the AI-detection sidecar (tagged after the quiesce below) ──
# amd64-only; pulled/verified/retagged exactly like the main image so the bundle is
# pinned coherently, then compose create (--pull never) finds it locally. The
# COMPOSE_PROFILES line written into .env below is what actually brings it up.
if [ "$AIDETECT_ENABLED" = 1 ]; then
  step "Downloading the AI-detection sidecar"
  download_size "$VS_NVR_AIDETECT_IMAGE"
  docker pull "$VS_NVR_AIDETECT_IMAGE" || abort "Failed to pull $VS_NVR_AIDETECT_IMAGE."
  ai_info="$(docker inspect -f '{{.Id}}|{{range .RepoDigests}}{{.}} {{end}}' "$VS_NVR_AIDETECT_IMAGE" 2>/dev/null)" || ai_info=""
  AIDETECT_IMAGE_ID="${ai_info%%|*}"
  AIDETECT_REPO_DIGESTS="${ai_info#*|}"
  [ -n "$AIDETECT_IMAGE_ID" ] || abort "Could not resolve the pulled image ID for $VS_NVR_AIDETECT_IMAGE."
  verify_image "$VS_NVR_AIDETECT_IMAGE" "$AIDETECT_REPO_DIGESTS"
  log "Downloaded the AI-detection sidecar"
fi

# ── Pull + verify the media-plane sidecar ──────────────────────────
# Not optional: it is the only transport for remote playback, so a failed pull
# aborts the install rather than shipping a box that cannot serve footage remotely.
step "Downloading the media sidecar"
download_size "$VS_NVR_MEDIADC_IMAGE"
docker pull "$VS_NVR_MEDIADC_IMAGE" || abort "Failed to pull $VS_NVR_MEDIADC_IMAGE."
dc_info="$(docker inspect -f '{{.Id}}|{{range .RepoDigests}}{{.}} {{end}}' "$VS_NVR_MEDIADC_IMAGE" 2>/dev/null)" || dc_info=""
MEDIADC_IMAGE_ID="${dc_info%%|*}"
MEDIADC_REPO_DIGESTS="${dc_info#*|}"
[ -n "$MEDIADC_IMAGE_ID" ] || abort "Could not resolve the pulled image ID for $VS_NVR_MEDIADC_IMAGE."
verify_image "$VS_NVR_MEDIADC_IMAGE" "$MEDIADC_REPO_DIGESTS"
# Only the install checks signatures, so the checker it pulled goes again.
[ "$COSIGN_PRESENT" = 1 ] || docker image rm "$COSIGN_IMAGE" >/dev/null 2>&1 || true
log "Downloaded the media sidecar"

# ── Quiesce a running install before touching it (re-run only) ─────
# The in-app update and reset helpers run their own `docker compose` against this
# stack; two concurrent recreates collide on compose's temporary container names
# and leave the stack half-renamed. Let any helper finish, then stop the stack so
# the NVR cannot launch another one until the final restart below.
HELPERS="vs-nvr-update-helper vs-nvr-reset-helper"
running_helper() { # echo the first running helper; status 2 on a daemon error
  local names h
  names="$(docker ps --format '{{.Names}}')" || return 2
  for h in $HELPERS; do
    if printf '%s\n' "$names" | grep -qxF "$h"; then printf '%s' "$h"; return 0; fi
  done
}
wait_for_helpers() { # 0 once none runs, 1 after 15 minutes, 2 on a daemon error
  local helper waited=0
  while :; do
    helper="$(running_helper)" || return 2
    [ -n "$helper" ] || return 0
    [ "$waited" -ge 900 ] && return 1
    [ "$waited" -eq 0 ] && log "Waiting for the in-progress $helper to finish…"
    sleep 5; waited=$((waited + 5))
  done
}
HELPER_CHECK_FAILED="Could not list Docker containers to check for an in-progress update (Docker daemon error)."
check_helpers() { # abort unless no helper is running (waiting for one first)
  local rc=0
  wait_for_helpers || rc=$?
  [ "$rc" -ne 2 ] || abort "$HELPER_CHECK_FAILED"
  [ "$rc" -eq 0 ] || abort "An in-app update or reset is still running after 15 minutes; let it finish, then re-run."
}
STACK_STOPPED=false
restart_stack() { # EXIT hook: never leave a stopped install down after an abort
  [ "$STACK_STOPPED" = true ] || return 0
  STACK_STOPPED=false
  # A helper that slipped in may bring the stack back or fail first; start after it,
  # and leave the start to the operator if its state can't be confirmed.
  if ! wait_for_helpers; then
    warn "Install did not finish, and an in-app update or reset may still be running. Once it is done, run: sudo systemctl start vs-nvr"
    return 0
  fi
  warn "Install did not finish; starting the stack again."
  systemctl start vs-nvr.service || warn "Could not start it. Run: sudo systemctl start vs-nvr"
}
# A reservation this run made but never recorded in the manifest goes again.
discard_new_image() {
  [ -n "$NEW_IMAGE" ] || return 0
  if [ -n "$(losetup -j "$NEW_IMAGE" 2>/dev/null)" ] && ! umount "$MOUNT_PATH" 2>/dev/null && mountpoint -q "$MOUNT_PATH"; then
    warn "Left $NEW_IMAGE in place: it is still mounted at $MOUNT_PATH. Unmount that, then delete the file."
    return 0
  fi
  rm -f "$NEW_IMAGE"
  rmdir "${NEW_IMAGE%/*}" 2>/dev/null || true
}
trap 'rc=$?; cleanup_extract; restart_stack; discard_new_image; ui_finish $rc' EXIT
if [ "$RERUN" = true ]; then
  step "Stopping the running stack"
  check_helpers
  STACK_STOPPED=true
  systemctl stop vs-nvr.service
  (cd "$INSTALL_DIR" && docker compose --env-file .env stop)
  helper="$(running_helper)" || abort "$HELPER_CHECK_FAILED"
  [ -z "$helper" ] || abort "An in-app update or reset started while stopping the stack; let it finish, then re-run."
  log "Stack stopped"
fi

# Tag only now: an update helper retags these same names, so tagging before the
# quiesce could let one that finished in between swap the images under us.
docker tag "$IMAGE_ID" "$COMPOSE_IMAGE_REF"
if [ "$AIDETECT_ENABLED" = 1 ]; then docker tag "$AIDETECT_IMAGE_ID" "$COMPOSE_AIDETECT_IMAGE_REF"; fi
docker tag "$MEDIADC_IMAGE_ID" "$COMPOSE_MEDIADC_IMAGE_REF"

# ── Mount the selected recording drive (first host mutation) ───────
# Deferred to here on purpose: the image is pulled + validated above, so a bad
# image aborts before we mount anything or touch /etc/fstab.
if [ "$MOUNT_PLAN" = mount ]; then
  MOUNT_OWNER_OPTS=""
  if [ "$RESERVE" = new ]; then
    step "Reserving $RESERVE_GB GB for recordings"
    [ "$(reserve_max_gb 0)" -ge "$RESERVE_GB" ] || abort "The system disk no longer has room to reserve $RESERVE_GB GB and still leave space free. Re-run and pick a smaller size."
    [ ! -e "$RESERVE_IMAGE" ] || abort "$RESERVE_IMAGE appeared during the install. Move it away, then re-run."
    install -d -m 0700 "${RESERVE_IMAGE%/*}"
    NEW_IMAGE="$RESERVE_IMAGE"
    (umask 077; : > "$RESERVE_IMAGE")
    # On btrfs: no copy-on-write, so overwriting old footage stays in the reserved space.
    chattr +C "$RESERVE_IMAGE" 2>/dev/null || true
    fallocate -l "${RESERVE_GB}G" "$RESERVE_IMAGE" || abort "Could not reserve $RESERVE_GB GB in $RESERVE_IMAGE."
    # Discarding free blocks, or zeroing inode tables and the journal lazily after
    # mounting, would punch holes in the file and give that space back.
    mkfs.ext4 -q -F -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 -L vs-nvr-rec "$RESERVE_IMAGE" || abort "Could not format $RESERVE_IMAGE."
    [ $(($(stat -c '%b * %B' "$RESERVE_IMAGE"))) -ge $((RESERVE_GB << 30)) ] ||
      abort "The system disk's filesystem can't reserve space ($RESERVE_IMAGE came out sparse). Record to a drive instead."
    log "Reserved $RESERVE_GB GB in $RESERVE_IMAGE"
  elif [ "$RESERVE" = kept ]; then
    step "Mounting the kept recording space"
  else
    step "Mounting the recording drive"
  fi
  mkdir -p "$MOUNT_PATH"
  if [ -n "$RESERVE" ]; then
    SELECTED_UUID="$(blkid -o value -s UUID "$RESERVE_IMAGE" 2>/dev/null || true)"
    [ -n "$SELECTED_UUID" ] || abort "Could not read the filesystem UUID of $RESERVE_IMAGE."
    mount -o loop "$RESERVE_IMAGE" "$MOUNT_PATH" || abort "Failed to mount $RESERVE_IMAGE at $MOUNT_PATH."
    # lsblk reads the new loop device's UUID from udev.
    udevadm settle 2>/dev/null || true
  else
    # These filesystems have no Unix ownership; the mount sets it, for the app's uid.
    case "$SELECTED_FSTYPE" in vfat|exfat|ntfs|ntfs3) MOUNT_OWNER_OPTS="uid=65531,gid=65531" ;; esac
    mount -U "$SELECTED_UUID" ${MOUNT_OWNER_OPTS:+-o "$MOUNT_OWNER_OPTS"} "$MOUNT_PATH" || abort "Failed to mount $SELECTED_DEV (UUID=$SELECTED_UUID) at $MOUNT_PATH."
  fi
  # Past this point the drive IS mounted; a failed check unmounts it before aborting,
  # so a botched install never leaves a half-mounted target behind.
  abort_unmount() { umount "$MOUNT_PATH" 2>/dev/null || warn "Could not unmount $MOUNT_PATH during rollback — unmount it manually."; abort "$1"; }
  findmnt --mountpoint "$MOUNT_PATH" >/dev/null 2>&1 || abort_unmount "$MOUNT_PATH did not become a mountpoint after mount — aborting."
  # Verify the mounted source is the drive we picked (by UUID), not just "something
  # is mounted here", then confirm the recorder can actually write to it.
  mounted_src="$(findmnt -no SOURCE --mountpoint "$MOUNT_PATH" 2>/dev/null || true)"
  mounted_uuid="$(lsblk -dprno UUID "$mounted_src" 2>/dev/null || true)"
  [ "$mounted_uuid" = "$SELECTED_UUID" ] || abort_unmount "Mounted filesystem at $MOUNT_PATH is UUID='${mounted_uuid:-?}', expected $SELECTED_UUID — aborting."
  # Atomic, randomly-named probe (mktemp uses O_EXCL) so a pre-planted symlink on the
  # drive cannot trick root into truncating an arbitrary host file.
  probe="$(mktemp "$MOUNT_PATH/.vsnvr-write-test.XXXXXX" 2>/dev/null)" || abort_unmount "$MOUNT_PATH is not writable — the recorder needs write access. Check the filesystem and permissions."
  rm -f -- "$probe" 2>/dev/null || true
  # Record that the installer mounted this drive, so uninstall.sh may unmount it.
  # An operator-supplied (already-mounted) drive never reaches here, so uninstall
  # leaves it mounted. MOUNT_UUID is this drive's stable identity — uninstall uses
  # it to tell a swapped drive from this one before unmounting or clearing markers.
  manifest_add "CREATED_MOUNT=$MOUNT_PATH"
  manifest_add "MOUNT_UUID=$SELECTED_UUID"
  if [ -n "$RESERVE" ]; then
    manifest_add "CREATED_IMAGE=$RESERVE_IMAGE"
    NEW_IMAGE=""
    # X-fstrim.notrim: the weekly fstrim would otherwise hand the reserved free
    # blocks back to the system disk.
    FSTAB_MOUNT_LINE="$RESERVE_IMAGE $MOUNT_PATH ext4 loop,nofail,X-fstrim.notrim,$VSNVR_FSTAB_OWN_MARK 0 0"
  else
    # Persist by UUID (kernel device name is irrelevant). nofail + a bounded
    # device-timeout so an absent drive never blocks boot (attest-mount fails closed).
    FSTAB_MOUNT_LINE="UUID=$SELECTED_UUID $MOUNT_PATH $SELECTED_FSTYPE $VSNVR_FSTAB_OPTS${MOUNT_OWNER_OPTS:+,$MOUNT_OWNER_OPTS} 0 2"
  fi
  if grep -qxF "$FSTAB_MOUNT_LINE" /etc/fstab 2>/dev/null; then
    log "Mounted $SELECTED_DEV at $MOUNT_PATH (fstab entry already present)"
  elif printf '%s\n' "$FSTAB_MOUNT_LINE" >> /etc/fstab; then
    manifest_add "FSTAB_LINE=$FSTAB_MOUNT_LINE"
    log "Mounted $SELECTED_DEV at $MOUNT_PATH and persisted it to /etc/fstab"
  else
    warn "Mounted $SELECTED_DEV at $MOUNT_PATH, but could NOT persist to /etc/fstab — it will not auto-mount on reboot. Add manually: $FSTAB_MOUNT_LINE"
  fi
elif [ "$MOUNT_PLAN" = adopt ]; then
  # Re-claim a prior VS NVR mount at the SAME commit point a freshly-created mount is
  # recorded (after image validation). No mount/fstab mutation: the drive is already
  # mounted and its fstab line already exists — we only record ownership so uninstall
  # reverses it.
  step "Adopting the existing recording mount"
  manifest_add "CREATED_MOUNT=$MOUNT_PATH"
  manifest_add "MOUNT_UUID=$ADOPT_UUID"
  manifest_add "FSTAB_LINE=$ADOPT_FSTAB_LINE"
  log "Recorded the existing $MOUNT_PATH mount as installer-owned (uninstall will reverse it)"
fi

# ── Recover a drive that is unplugged and plugged back in ──────────
# On a yank the NVR still holds files open, so systemd's umount of the dead drive
# fails busy, and a nofail fstab mount is only started at boot: the reconnected
# drive was never mounted. Lazy unmount detaches the dead filesystem at once; the
# drive's device unit wanting the mount mounts it again (after fsck) when it
# reappears. Only for a mount the manifest owns (picker, adopted, or setup-nvr.sh),
# and rewritten on a rerun so an existing install gets it too, but not for
# reserved space, which can't be unplugged. uninstall.sh removes both drop-ins
# with the mount.
if grep -qxF "CREATED_MOUNT=$MOUNT_PATH" "$MANIFEST_FILE" 2>/dev/null && ! grep -q '^CREATED_IMAGE=' "$MANIFEST_FILE"; then
  replug_uuid="$(lsblk -dprno UUID "$(findmnt -no SOURCE --mountpoint "$MOUNT_PATH")" 2>/dev/null || true)"
  mount_unit="$(systemd-escape --path --suffix=mount "$MOUNT_PATH")"
  mount_dropin="/etc/systemd/system/$mount_unit.d"
  device_dropin="/etc/systemd/system/$(systemd-escape --path --suffix=device "/dev/disk/by-uuid/$replug_uuid").d"
  if [ -n "$replug_uuid" ] && mkdir -p "$mount_dropin" "$device_dropin" &&
    printf '[Mount]\nLazyUnmount=yes\n' > "$mount_dropin/vs-nvr.conf" &&
    printf '[Unit]\nWants=%s\n' "$mount_unit" > "$device_dropin/vs-nvr.conf"; then
    log "A reconnected recording drive will be mounted again automatically"
  else
    warn "Could not set up automatic remounting; a recording drive that is unplugged and reconnected will need a reboot."
  fi
fi

# ── Recording-parent rshared bind (for live drive recovery) ────────
# Bind the PARENT with rshared so a drive remount propagates into the running
# container. systemd already makes / shared and children inherit it, so a
# self-bind onto an already-shared parent double-mounts — self-bind only when the
# propagation is missing, and drop a stale installer-owned self-bind otherwise.
step "Preparing $RECORDING_PATH for drive recovery"
FSTAB_LINE="$RECORDING_PATH $RECORDING_PATH none bind,rshared 0 0"
if findmnt -no PROPAGATION --target "$RECORDING_PATH" 2>/dev/null | grep -q shared; then
  if grep -qxF "$FSTAB_LINE" /etc/fstab 2>/dev/null; then
    # awk (not grep -v): filtering out every line still exits 0, while a real read
    # error exits non-zero so the && skips mv and never truncates fstab.
    awk -v drop="$FSTAB_LINE" '$0 != drop' /etc/fstab > /etc/fstab.vsnvr.tmp && mv /etc/fstab.vsnvr.tmp /etc/fstab
    log "Removed a stale self-bind of $RECORDING_PATH (parent already propagates shared)"
  else
    log "$RECORDING_PATH already propagates shared"
  fi
elif mountpoint -q "$RECORDING_PATH"; then
  # The parent is itself a separate mount and does not propagate shared. rshared
  # cannot be persisted for it without editing the user's own fstab entry (which
  # the non-destructive contract forbids), and a self-bind line would collide with
  # that mount at boot. Refuse rather than write a fstab entry that breaks boot.
  abort "$RECORDING_PATH is itself a separate mounted filesystem that does not propagate shared. Mount the recording drive under a plain directory (e.g. $RECORDING_MOUNT_DEFAULT), not nested under another mount, then re-run."
else
  mount --bind "$RECORDING_PATH" "$RECORDING_PATH"
  mount --make-rshared "$RECORDING_PATH"
  # The installer created this self-bind, so uninstall.sh may remove it (the
  # "already shared" branch above creates nothing and records nothing). Record the
  # fstab line ONLY when we actually append it, so a pre-existing identical line is
  # never claimed for removal.
  if grep -qxF "$FSTAB_LINE" /etc/fstab 2>/dev/null; then
    :
  else
    printf '%s\n' "$FSTAB_LINE" >> /etc/fstab
    manifest_add "FSTAB_LINE=$FSTAB_LINE"
  fi
  manifest_add "CREATED_SELFBIND=$RECORDING_PATH"
  log "Established rshared self-bind on $RECORDING_PATH (persisted to /etc/fstab)"
fi

# ── Install the validated stack files (extracted + checked above) ──
step "Installing VS NVR into $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
manifest_start
cp "$EXTRACT_DIR/docker-compose.yml" "$INSTALL_DIR/docker-compose.yml"
cp "$EXTRACT_DIR/attest-mount.sh"    "$INSTALL_DIR/attest-mount.sh"
# Host lifecycle helpers, extracted from the image so the appliance can be reset
# or removed later with no network access and no second script to trust.
cp "$EXTRACT_DIR/uninstall.sh"       "$INSTALL_DIR/uninstall.sh"
cp "$EXTRACT_DIR/factory-reset.sh"   "$INSTALL_DIR/factory-reset.sh"
# Egress firewall for the isolated mediadc sidecar bridge; vs-nvr.service applies it
# via ExecStartPost (a no-op until Docker has created the bridge).
cp "$EXTRACT_DIR/mediadc-egress-firewall.sh" "$INSTALL_DIR/mediadc-egress-firewall.sh"
chmod +x "$INSTALL_DIR/attest-mount.sh" "$INSTALL_DIR/uninstall.sh" "$INSTALL_DIR/factory-reset.sh" "$INSTALL_DIR/mediadc-egress-firewall.sh"
cp "$EXTRACT_DIR/vs-nvr.service"     /etc/systemd/system/vs-nvr.service
systemctl daemon-reload
# Holds the VS hardware key of a recorder VS sold, bound read-only into the
# container. An existing key is never touched; uninstall.sh keeps one.
install -d -m 0755 "$INSTALL_DIR/vs-hardware"

# ── .env ───────────────────────────────────────────────────────────
# Minimal by design. No SITE_MANAGER_URL (compiled in) and NEVER
# RECORDING_VOLUME_ATTESTED (see docker-compose.yml).

# The isolated mediadc sidecar advertises the box's reachable IP as its WebRTC host
# candidate (it sees only the container IP from its bridge). Detect the primary
# source IP. Off-LAN viewers get the router's external IP from the UPnP/NAT-PMP
# mapping; without one, forward UDP 8556 and set this to the public IP instead.
detect_advertise_ip() {
  local ip
  ip="$(primary_ip)"
  [ -n "$ip" ] || warn "Could not detect this box's IP. The mediadc sidecar (remote playback) will not start until MEDIA_DC_ADVERTISE_IP is set in $INSTALL_DIR/.env." >&2
  printf '%s' "$ip"
}

if [ "$RERUN" = false ]; then
  MEDIA_DC_ADVERTISE_IP_DETECTED="$(detect_advertise_ip)"
  cat > "$INSTALL_DIR/.env" <<EOF
# Parent bound into the container as /mnt (rshared); the recording drive mounts
# beneath it at /mnt/recordings. Never add RECORDING_VOLUME_ATTESTED here: it is
# recomputed on every start (see docker-compose.yml).
RECORDING_PATH=$RECORDING_PATH
HOST_COMPOSE_DIR=$INSTALL_DIR
UPDATE_URL=${UPDATE_URL_ARG:-$UPDATE_URL_DEFAULT}
# Box IP the isolated mediadc sidecar advertises as its WebRTC host candidate.
MEDIA_DC_ADVERTISE_IP=$MEDIA_DC_ADVERTISE_IP_DETECTED
EOF
  if has_intel_gpu; then
    # Lets AI decode and detection use the GPU (Settings > Hardware turns it off).
    printf '\n# GPU passthrough for AI decode and detection.\nAIDETECT_DRI_DEVICE=/dev/dri\n' >> "$INSTALL_DIR/.env"
  fi
  if [ "$AIDETECT_ENABLED" = 1 ]; then
    # Activates the aidetect compose profile for every stack command that passes
    # --env-file .env (systemd unit, updater) and for `docker compose` run from
    # this dir (install create). Removing this line + restart disables the sidecar.
    printf '\n# AI-detection sidecar (auto-on). Remove to disable, then restart.\nCOMPOSE_PROFILES=aidetect\n' >> "$INSTALL_DIR/.env"
  fi
  log "Wrote $INSTALL_DIR/.env"
else
  # Preserve the operator's .env; only fill in a missing or empty
  # MEDIA_DC_ADVERTISE_IP (the sidecar fails fast without one; never clobber an
  # override) and, if asked, update the update URL.
  if [ -z "$(env_value MEDIA_DC_ADVERTISE_IP "$INSTALL_DIR/.env")" ]; then
    ip="$(detect_advertise_ip)"
    if [ -n "$ip" ] && grep -qE '^[[:space:]]*MEDIA_DC_ADVERTISE_IP[[:space:]]*=' "$INSTALL_DIR/.env"; then
      sed -i "s/^[[:space:]]*MEDIA_DC_ADVERTISE_IP[[:space:]]*=.*/MEDIA_DC_ADVERTISE_IP=$ip/" "$INSTALL_DIR/.env"
    elif [ -n "$ip" ]; then
      printf '\n# Box IP the isolated mediadc sidecar advertises as its WebRTC host candidate.\nMEDIA_DC_ADVERTISE_IP=%s\n' "$ip" >> "$INSTALL_DIR/.env"
    fi
  fi
  if [ -n "$UPDATE_URL_ARG" ]; then
    # Delete any existing UPDATE_URL line(s), then append via printf. The sed
    # pattern holds no user input; the value goes through printf, so a URL with
    # sed-significant chars (& | \) cannot corrupt the rewrite.
    sed -i '/^[[:space:]]*UPDATE_URL[[:space:]]*=/d' "$INSTALL_DIR/.env"
    printf 'UPDATE_URL=%s\n' "$UPDATE_URL_ARG" >> "$INSTALL_DIR/.env"
  fi
  log "Preserved existing $INSTALL_DIR/.env"
fi
# Docker can't create the media sidecar's IPv6 network on a kernel booted without
# IPv6, and the whole stack would fail to start.
if [ ! -d /proc/sys/net/ipv6 ] && [ -z "$(env_value MEDIA_DC_IPV6 "$INSTALL_DIR/.env")" ]; then
  printf '\n# This kernel has no IPv6, so the media sidecar network is IPv4 only.\nMEDIA_DC_IPV6=false\n' >> "$INSTALL_DIR/.env"
fi
host_tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
if [ -n "$host_tz" ] && [ -z "$(env_value HOST_TIME_ZONE "$INSTALL_DIR/.env")" ]; then
  printf '\n# Used until a time zone is chosen in Settings.\nHOST_TIME_ZONE=%s\n' "$host_tz" >> "$INSTALL_DIR/.env"
fi

# ── config.json (Tier-1 user values); recording_dir omitted so the compose
# RECORDING_DIR=/mnt/recordings override stays in force. Seeded once; preserved
# on re-run. ──────────────────────────────────────────────────────────
if [ ! -f "$INSTALL_DIR/config.json" ]; then
  cat > "$INSTALL_DIR/config.json" <<EOF
{
  "max_storage_gb": $MAX_STORAGE_GB,
  "recording_retention_days": $RETENTION_DAYS
}
EOF
  log "Wrote $INSTALL_DIR/config.json"
fi

# ── Seed config into the data volume before first start ────────────
# The image is already pulled and retagged above, so compose create uses exactly
# that image (no second `docker compose pull` that could fetch a newer :latest).
# The entrypoint writes its default config only when /app/data/config.json is
# absent, so create the container (which creates the volume) and seed only if unset.
step "Creating the containers"
(
  cd "$INSTALL_DIR"
  # --pull never: the image is already pulled + retagged above, so create must use
  # that exact local image and never re-pull (which a future pull_policy could).
  docker compose create --pull never
  probe="$(mktemp)"
  if ! docker compose cp vs-nvr:/app/data/config.json "$probe" >/dev/null 2>&1; then
    docker compose cp config.json vs-nvr:/app/data/config.json
    echo "seeded config.json into the data volume"
  fi
  rm -f "$probe"
)

# ── Host clock: recordings are stamped with it ─────────────────────
# vs-nvr.service waits up to 90s for network time at each start. A hardware clock
# kept in local time boots hours off, so offer to keep it in UTC — only once
# synced, because the switch writes the current system time into it.
CLOCK_SYNCED=false
if [ -e /run/systemd/timesync/synchronized ] || [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ]; then
  CLOCK_SYNCED=true
else
  warn "The system clock is not synchronized to network time. Recordings are stamped with this box's clock, and each start waits up to 90s for sync. Enable it with: sudo timedatectl set-ntp true"
fi
if [ "$(timedatectl show -p LocalRTC --value 2>/dev/null)" = yes ]; then
  if [ "$CLOCK_SYNCED" = true ] && [ "$TTY_OK" = 1 ]; then
    if ask_yesno "This box keeps its hardware clock in local time, so it boots with the wrong time until network sync corrects it. Keep it in UTC instead? Answer no if it dual-boots Windows. [y/N] "; then
      if timedatectl set-local-rtc 0; then
        log "Hardware clock now kept in UTC"
      else
        warn "Could not switch the hardware clock to UTC. Run: sudo timedatectl set-local-rtc 0"
      fi
    else
      warn "Hardware clock left in local time. Each boot waits up to 90s for network time before recording."
    fi
  else
    warn "The hardware clock is kept in local time, so this box boots with the wrong time. Once the clock is correct, fix it with: sudo timedatectl set-local-rtc 0"
  fi
fi

# ── Hand the lifecycle to systemd ──────────────────────────────────
# restart (not enable --now): on a re-run the oneshot+RemainAfterExit unit is
# already active, so `enable --now` would no-op and ExecStart would never re-run.
# ExecStartPre runs attest-mount.sh before the stack binds, so a drive-missing
# start comes up unbound rather than binding the OS disk.
step "Starting VS NVR"
systemctl enable vs-nvr.service
systemctl restart vs-nvr.service
STACK_STOPPED=false
log "vs-nvr.service enabled and started"

# ── Report: server liveness and recording-volume readiness, separately ──
# curl is only needed for this end-of-run report, not for the install itself, so a
# missing curl degrades the report rather than aborting.
LIVE=false
if command -v curl >/dev/null 2>&1; then
  status_note "waiting for it to answer"
  echo "Waiting up to a minute for http://localhost:8080/api/health"
  health_deadline=$((SECONDS + 60))
  while [ "$SECONDS" -lt "$health_deadline" ]; do
    if curl -sf --max-time 5 http://localhost:8080/api/health >/dev/null 2>&1; then LIVE=true; break; fi
    sleep 2
  done
  status_note ""
else
  warn "curl not found — skipping the liveness check; verify manually at http://localhost:8080"
fi
if [ "$LIVE" = true ]; then
  log "Server is up (http://localhost:8080)"
else
  warn "Server did not answer /api/health yet — check: docker compose -f $INSTALL_DIR/docker-compose.yml logs -f"
fi

# Recording-volume readiness is best-effort from THIS container start's logs (the
# gate snapshot API needs an authenticated capability we do not have at install).
# Scope to the current start so a prior container's 'ready' is never reported as now.
started_at="$(docker inspect -f '{{.State.StartedAt}}' vs-nvr 2>/dev/null || true)"
gate_line=""
if [ -n "$started_at" ]; then
  gate_line="$(docker logs --since "$started_at" vs-nvr 2>&1 | grep -E 'recording volume gate (ready|blocking)' | tail -n1 || true)"
fi
if [ "$LIVE" = true ] && printf '%s' "$gate_line" | grep -q 'gate ready'; then
  log "Recording volume: READY — recording is active."
elif printf '%s' "$gate_line" | grep -q 'blocking'; then
  state="$(printf '%s' "$gate_line" | grep -oE 'state=[a-z_]+' | head -n1)"
  warn "Recording volume: ${state:-not ready} — not recording yet. If the drive is connected, open the web UI and choose \"Set up recording here\"."
else
  # No current-start gate line, or the gate said ready but the server isn't
  # answering — report unknown rather than a possibly-stale READY.
  warn "Recording volume: could not confirm readiness — check the web UI's storage status (and that the server is up)."
fi

STEP_LABEL=""
status_stop
lan_ip="$(primary_ip)"; lan_ip="${lan_ip:-<IP address>}"
say ""
if [ "$LIVE" = true ]; then say "${GREEN}  VS NVR is running.${NC}"; else say "${YELLOW}  VS NVR is installed, but isn't answering yet.${NC}"; fi
say "    On this computer:  http://localhost:8080"
say "    Other devices:     http://$lan_ip:8080"
say ""
say "  Remote playback uses UDP port $MEDIA_DC_PORT, which VS NVR opens on the router with"
say "  UPnP or NAT-PMP. If the router has neither, forward that port to this computer"
say "  and set MEDIA_DC_ADVERTISE_IP in $INSTALL_DIR/.env to your public IP."
say ""
say "${GRAY}  To remove it later: sudo $INSTALL_DIR/uninstall.sh${NC}"
if [ "$FANCY" = 1 ]; then
  printf -v took '%d:%02d' $((SECONDS / 60)) $((SECONDS % 60))
  say "${GRAY}  Installed in $took. Full output: $LOG_FILE${NC}"
fi
}
