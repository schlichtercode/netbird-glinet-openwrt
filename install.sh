#!/bin/sh
# netbird-glinet-openwrt — install NetBird on a GL.iNet router from your computer.
#
#   ./install.sh [root@192.168.8.1] [https://netbird.example.com:443]
#
# Options (env or flags):
#   --probe            only print the compatibility report, change nothing
#   --skip-binary      do not (re)install the NetBird binary
#   --force            reinstall the binary even if the version matches
#   --version X.Y.Z    NetBird release to install (default: files/usr/share/netbird-glinet/netbird-release)
#   --arch NAME        override the release arch, e.g. mipsle_softfloat
#   SSH_OPTS="..."     extra ssh options
#
# What it does (idempotent, re-run any time):
#   1. probes the router (CPU/endianness, RAM, flash, modules, web stack)
#   2. pushes files/ (service, watchdog, panel page, helpers) and applies
#      the sysctl tuning (overcommit must precede the binary test)
#   3. downloads the matching release tarball + checksum on THIS machine and
#      streams the binary straight into /usr/bin on the router (never via
#      /tmp, which is RAM on OpenWrt)
#   4. creates the UCI config if missing, then runs the router-side setup
#      (/usr/libexec/netbird/setup-router.sh install): small-router UCI
#      defaults, old-layout cleanup, switch hook, GL VPN-client wrapper,
#      service enable/restart, nginx restart if the panel object changed
#
# Alternative without this script: the opkg feed (README, "Install via opkg
# feed") — its postinst runs the same setup-router.sh on the router.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
FILES="$HERE/files"
CACHE="$HERE/.cache"
[ -d "$FILES" ] || { echo "ERROR: files/ directory not found next to install.sh" >&2; exit 1; }

# Pinned NetBird releases (one place, shared with netbird-fetch-binary on the
# router). Env NETBIRD_VERSION_MIPS32 / NETBIRD_VERSION override them.
ENV_MIPS32="${NETBIRD_VERSION_MIPS32:-}"
NETBIRD_VERSION_DEFAULT=""; NETBIRD_VERSION_MIPS32=""
. "$FILES/usr/share/netbird-glinet/netbird-release"
[ -n "$ENV_MIPS32" ] && NETBIRD_VERSION_MIPS32="$ENV_MIPS32"
NETBIRD_VERSION="${NETBIRD_VERSION:-}"
ROUTER=""
MGMT_URL=""
PROBE_ONLY=0
SKIP_BINARY=0
FORCE=0
ARCH_OVERRIDE="${NETBIRD_ARCH:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --probe) PROBE_ONLY=1 ;;
        --skip-binary) SKIP_BINARY=1 ;;
        --force) FORCE=1 ;;
        --version) NETBIRD_VERSION="$2"; shift ;;
        --arch) ARCH_OVERRIDE="$2"; shift ;;
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) if [ -z "$ROUTER" ]; then ROUTER="$1"; elif [ -z "$MGMT_URL" ]; then MGMT_URL="$1"; else echo "too many arguments" >&2; exit 2; fi ;;
    esac
    shift
done
ROUTER="${ROUTER:-root@192.168.8.1}"
case "$ROUTER" in *@*) ;; *) ROUTER="root@$ROUTER" ;; esac

CTRL="${TMPDIR:-/tmp}/netbird-install-$$.sock"
# RSA-only dropbear on GL.iNet 18.06 firmware needs the legacy host-key alg.
SSH_BASE="-o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa -o ControlMaster=auto -o ControlPath=$CTRL -o ControlPersist=180 -o ConnectTimeout=10 ${SSH_OPTS:-}"

# shellcheck disable=SC2086
rssh() { ssh $SSH_BASE "$ROUTER" "$@"; }
cleanup() { ssh -o ControlPath="$CTRL" -O exit "$ROUTER" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

say()  { printf '\033[1;36m>>\033[0m %s\n' "$*"; }
ok()   { printf '   \033[1;32m✔\033[0m %s\n' "$*"; }
warn() { printf '   \033[1;33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ── 1. Probe ──────────────────────────────────────────────────────────────────
say "Connecting to $ROUTER (you may be asked for the router password once)…"
PROBE=$(rssh 'sh -s' <<'REMOTE'
echo "MACHINE=$(uname -m)"
echo "KERNEL=$(uname -r)"
elf=$(hexdump -n 8 -C /bin/busybox 2>/dev/null | head -1 | awk '{print $6}')
[ -z "$elf" ] && elf=$(od -An -tx1 -j5 -N1 /bin/busybox 2>/dev/null | tr -d ' ')
echo "ELF_DATA=$elf"
echo "FPU=$(grep -m1 -oE 'FPU V[0-9.]+' /proc/cpuinfo | tr -d ' ')"
echo "MEM_TOTAL_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo)"
echo "MEM_AVAIL_KB=$(awk '/MemAvailable/{print $2}' /proc/meminfo)"
echo "SWAP_KB=$(awk '/SwapTotal/{print $2}' /proc/meminfo)"
echo "OVERLAY_FREE_KB=$(df -k /overlay 2>/dev/null | awk 'NR==2{print $4}')"
echo "ROOT_FREE_KB=$(df -k / | awk 'NR==2{print $4}')"
echo "HAS_TUN=$([ -c /dev/net/tun ] && echo 1 || echo 0)"
if lsmod 2>/dev/null | grep -q '^wireguard'; then echo "WG=loaded"; elif ls /lib/modules/*/wireguard.ko >/dev/null 2>&1; then echo "WG=available"; else echo "WG=missing"; fi
echo "IPSET_MOD=$(lsmod 2>/dev/null | grep -q '^ip_set ' && echo 1 || echo 0)"
echo "XT_SET=$(lsmod 2>/dev/null | grep -q '^xt_set' && echo 1 || echo 0)"
echo "DISTRIB=$(. /etc/openwrt_release 2>/dev/null; echo "$DISTRIB_RELEASE $DISTRIB_TARGET")"
echo "GL_VERSION=$(cat /etc/glversion 2>/dev/null)"
echo "MODEL=$(cat /tmp/sysinfo/model 2>/dev/null)"
echo "OUI=$([ -d /usr/share/oui/menu.d ] && [ -d /www/views ] && [ -d /usr/lib/oui-httpd/rpc ] && echo 1 || echo 0)"
echo "NGINX=$(command -v nginx >/dev/null 2>&1 && echo 1 || echo 0)"
for b in iptables ipset curl timeout pgrep killall lua hexdump; do echo "BIN_$b=$(command -v $b >/dev/null 2>&1 && echo 1 || echo 0)"; done
echo "NETBIRD_CUR=$(/usr/bin/netbird version 2>/dev/null || echo none)"
echo "SVC=$([ -x /etc/init.d/netbird ] && echo 1 || echo 0)"
echo "OLD_UPSTREAM=$({ [ -f /etc/nginx/gl-conf.d/netbird.conf ] || [ -f /usr/share/oui/menu.d/netbirdview.json ]; } && echo 1 || echo 0)"
REMOTE
) || die "SSH to $ROUTER failed"
pv() { printf '%s\n' "$PROBE" | sed -n "s/^$1=//p" | head -1; }

MACHINE=$(pv MACHINE); KERNEL=$(pv KERNEL); ELF=$(pv ELF_DATA)
MEM_TOTAL=$(pv MEM_TOTAL_KB); MEM_AVAIL=$(pv MEM_AVAIL_KB); SWAP=$(pv SWAP_KB)
OVERLAY_FREE=$(pv OVERLAY_FREE_KB); [ -n "$OVERLAY_FREE" ] || OVERLAY_FREE=$(pv ROOT_FREE_KB)
WG=$(pv WG); OUI=$(pv OUI); CUR=$(pv NETBIRD_CUR)
: "${MEM_TOTAL:=0}" "${MEM_AVAIL:=0}" "${SWAP:=0}" "${OVERLAY_FREE:=0}"

case "$MACHINE" in
    mips)    [ "$ELF" = 01 ] && ARCH=mipsle_softfloat || ARCH=mips_softfloat ;;
    mips64)  [ "$ELF" = 01 ] && ARCH=mips64le_softfloat || ARCH=mips64_softfloat ;;
    aarch64) ARCH=arm64 ;;
    armv7l|armv6l|armv8l) ARCH=armv6 ;;
    x86_64)  ARCH=amd64 ;;
    i?86)    ARCH=386 ;;
    *)       ARCH="" ;;
esac
[ -n "$ARCH_OVERRIDE" ] && ARCH="$ARCH_OVERRIDE"
if [ -z "$NETBIRD_VERSION" ]; then
    case "$ARCH" in
        mips_*|mipsle_*) NETBIRD_VERSION="$NETBIRD_VERSION_MIPS32" ;;
        *) NETBIRD_VERSION="$NETBIRD_VERSION_DEFAULT" ;;
    esac
fi

echo
echo "┌─ Router ────────────────────────────────────────────────────────"
printf '│ %-18s %s\n' "model"          "$(pv MODEL) (GL.iNet $(pv GL_VERSION), OpenWrt $(pv DISTRIB))"
printf '│ %-18s %s\n' "kernel / cpu"   "$KERNEL, $MACHINE, ELF byte5=$ELF ($([ "$ELF" = 01 ] && echo little || echo big)-endian), $(pv FPU)"
printf '│ %-18s %s\n' "netbird arch"   "${ARCH:-UNKNOWN}  → release $NETBIRD_VERSION"
printf '│ %-18s %s\n' "RAM"            "$((MEM_TOTAL/1024)) MB total, $((MEM_AVAIL/1024)) MB available, swap $((SWAP/1024)) MB"
printf '│ %-18s %s\n' "flash free"     "$((OVERLAY_FREE/1024)) MB (overlay)"
printf '│ %-18s %s\n' "tun / wireguard" "tun=$(pv HAS_TUN) wireguard=$WG ipset=$(pv IPSET_MOD) xt_set=$(pv XT_SET)"
printf '│ %-18s %s\n' "tools"          "iptables=$(pv BIN_iptables) ipset=$(pv BIN_ipset) curl=$(pv BIN_curl) timeout=$(pv BIN_timeout) lua=$(pv BIN_lua)"
printf '│ %-18s %s\n' "GL panel (oui)" "$OUI   nginx=$(pv NGINX)"
printf '│ %-18s %s\n' "netbird now"    "$CUR (service script: $(pv SVC), old upstream layout: $(pv OLD_UPSTREAM))"
echo "└─────────────────────────────────────────────────────────────────"
echo

[ -n "$ARCH" ] || die "could not map '$MACHINE' to a NetBird release — pass --arch"
[ "$(pv HAS_TUN)" = 1 ] || warn "/dev/net/tun missing — NetBird needs kmod-tun"
[ "$WG" = missing ] && warn "no WireGuard kernel module — NetBird will fall back to wireguard-go (more RAM/CPU)"
[ "$(pv BIN_lua)" = 1 ] || warn "no 'lua' on the router — DNS forwarding for LAN clients needs it"
[ "$OUI" = 1 ] || warn "GL.iNet SDK4 panel not detected — the admin-panel page will not appear (service still works)"
[ "$MEM_AVAIL" -lt 40000 ] && warn "only $((MEM_AVAIL/1024)) MB RAM available — watch 'logread -e netbird' for rss=, consider netbird-setup-swap on a USB stick"
[ "$PROBE_ONLY" = 1 ] && { say "Probe only — nothing changed."; exit 0; }

# ── 2. Files + sysctl (overcommit must precede the binary test) ──────────────
say "Installing service, watchdog, admin-panel page and helpers…"
rssh 'mkdir -p /usr/libexec/netbird /usr/lib/oui-httpd/rpc /usr/share/gl-validator.d /usr/share/oui/menu.d /usr/share/netbird-glinet /www/views /www/i18n /etc/netbird /etc/sysctl.d /var/log/netbird'
( cd "$FILES" && COPYFILE_DISABLE=1 tar --format ustar --uid 0 --gid 0 --uname root --gname root -cf - \
    --exclude='./etc/config/netbird' --exclude='./www/views/*.js' --exclude='.DS_Store' --exclude='._*' . ) \
    | rssh 'tar -C / -xf -' || die "file upload failed"
gzip -9 -c "$FILES/www/views/gl-sdk4-ui-netbird.common.js" | rssh 'cat > /www/views/gl-sdk4-ui-netbird.common.js.gz; rm -f /www/views/gl-sdk4-ui-netbird.common.js'
rssh 'chmod 755 /usr/libexec/netbird/setup-router.sh; sh /usr/libexec/netbird/setup-router.sh sysctl'
ok "files in place"

# ── 3. Download ───────────────────────────────────────────────────────────────
TARBALL="netbird_${NETBIRD_VERSION}_linux_${ARCH}.tar.gz"
SUMS="netbird_${NETBIRD_VERSION}_checksums.txt"
BASE="https://github.com/netbirdio/netbird/releases/download/v${NETBIRD_VERSION}"
BINDIR="${CACHE:?}/${NETBIRD_VERSION:?}-${ARCH:?}"
BIN="$BINDIR/netbird"

need_binary=1
if [ "$SKIP_BINARY" = 1 ]; then
    need_binary=0
elif [ "$FORCE" = 0 ] && [ "$CUR" = "$NETBIRD_VERSION" ]; then
    ok "netbird $NETBIRD_VERSION already installed on the router (use --force to reinstall)"
    need_binary=0
fi

if [ "$need_binary" = 1 ]; then
    mkdir -p "$BINDIR"
    if [ ! -x "$BIN" ]; then
        say "Downloading $TARBALL…"
        curl -fL --retry 3 --progress-bar -o "$BINDIR/$TARBALL" "$BASE/$TARBALL" || die "download failed ($BASE/$TARBALL)"
        curl -fsSL --retry 3 -o "$BINDIR/$SUMS" "$BASE/$SUMS" || die "checksum download failed"
        ( cd "$BINDIR" && grep " $TARBALL\$" "$SUMS" | { if command -v sha256sum >/dev/null 2>&1; then sha256sum -c - ; else shasum -a 256 -c - ; fi; } >/dev/null ) \
            || die "SHA256 mismatch for $TARBALL"
        ok "checksum verified"
        tar -xzf "$BINDIR/$TARBALL" -C "$BINDIR" netbird || die "extract failed"
        rm -f "${BINDIR:?}/${TARBALL:?}"
    fi
    SIZE_KB=$(( $(wc -c < "$BIN") / 1024 ))
    ok "binary ready: $BIN ($((SIZE_KB/1024)) MB)"

    # ── 4. Push binary ──────────────────────────────────────────────────────
    say "Stopping NetBird on the router (if running)…"
    rssh '[ -x /etc/init.d/netbird ] && /etc/init.d/netbird stop >/dev/null 2>&1; killall -q netbird 2>/dev/null; sleep 1; rm -f /var/run/netbird.sock; true'
    if [ "$OVERLAY_FREE" -lt $((SIZE_KB + 3072)) ]; then
        if [ "$CUR" != none ]; then
            warn "not enough flash for a side-by-side upgrade — removing the old binary first"
            rssh 'rm -f /usr/bin/netbird'
            OVERLAY_FREE=$(rssh "df -k /overlay 2>/dev/null | awk 'NR==2{print \$4}'")
        fi
        [ "$OVERLAY_FREE" -ge $((SIZE_KB + 2048)) ] || die "only $((OVERLAY_FREE/1024)) MB free on the router, need $((SIZE_KB/1024 + 2)) MB"
    fi
    say "Uploading binary ($((SIZE_KB/1024)) MB) — about a minute on a MIPS router…"
    rssh 'cat > /usr/bin/netbird.new && chmod 755 /usr/bin/netbird.new && mv /usr/bin/netbird.new /usr/bin/netbird' < "$BIN" \
        || die "upload failed"
    GOT=$(rssh '/usr/bin/netbird version 2>&1' || true)
    case "$GOT" in
        "$NETBIRD_VERSION"*) ok "router runs netbird $GOT (architecture confirmed)" ;;
        *) die "binary does not run on the router ('$GOT'). Wrong architecture (--arch mips_softfloat / mipsle_hardfloat)? If it is a plain 'Segmentation fault' on a small router, check that vm.overcommit_memory=1 took effect, or try --version 0.77.1" ;;
    esac
fi

# ── 5. UCI config: create only if missing (keeps existing settings / credentials)
if rssh 'uci -q get netbird.settings >/dev/null 2>&1'; then
    ok "existing /etc/config/netbird kept"
else
    rssh 'cat > /etc/config/netbird' < "$FILES/etc/config/netbird"
    ok "UCI config created"
fi

# ── 6. Router-side setup (shared with the opkg package's postinst) ───────────
say "Running setup-router.sh on the router…"
set -- install --no-fetch
[ -n "$MGMT_URL" ] && set -- "$@" --management-url "$MGMT_URL"
rssh "sh /usr/libexec/netbird/setup-router.sh $*" || warn "setup-router.sh reported an error — check: ssh $ROUTER logread -e netbird"

HOST=${ROUTER#*@}
echo
echo "────────────────────────────────────────────────────────────────"
echo " Done. Open the GL.iNet admin panel → VPN → NetBird"
echo "   http://$HOST/#/netbird"
echo " Enter your management URL (with port) and a reusable setup key."
echo
echo " SSH helpers:  netbird-status        overview + memory"
echo "               logread -e netbird   watchdog / memory log"
echo "               netbird-setup-swap   USB swap (if RAM gets tight)"
echo "────────────────────────────────────────────────────────────────"
