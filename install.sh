#!/bin/sh
# netbird-glinet-openwrt — install NetBird on a GL.iNet router from your computer.
#
#   ./install.sh [root@192.168.8.1] [https://netbird.example.com:443]
#
# Options (env or flags):
#   --probe            only print the compatibility report, change nothing
#   --skip-binary      do not (re)install the NetBird binary
#   --force            reinstall the binary even if the version matches
#   --version X.Y.Z    NetBird release to install (default: 0.81.4)
#   --arch NAME        override the release arch, e.g. mipsle_softfloat
#   SSH_OPTS="..."     extra ssh options
#
# What it does (idempotent, re-run any time):
#   1. probes the router (CPU/endianness, RAM, flash, modules, web stack)
#   2. downloads the matching release tarball + checksum on THIS machine
#   3. streams the binary straight into /usr/bin on the router (never via /tmp,
#      which is RAM on OpenWrt)
#   4. installs the procd service, watchdog, GL admin-panel page (7 languages),
#      UCI config, sysctl tuning; removes leftovers of the old upstream layout
#   5. enables + starts the service and reloads nginx so the panel shows NetBird
set -eu

# NetBird releases built with Go 1.26 (0.78.0+) carry a ~35 MB .noptrbss
# segment. With the kernel's default overcommit heuristic a 128 MB router
# refuses that mapping at exec time → instant "Segmentation fault". We set
# vm.overcommit_memory=1 before installing the binary (see sysctl below).
# NETBIRD_VERSION_MIPS32 exists as an escape hatch: set it to 0.77.1 (last
# Go-1.25 release) if you prefer to keep overcommit at its default.
NETBIRD_VERSION_DEFAULT="0.81.4"
NETBIRD_VERSION_MIPS32="${NETBIRD_VERSION_MIPS32:-0.81.4}"
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

HERE="$(cd "$(dirname "$0")" && pwd)"
FILES="$HERE/files"
CACHE="$HERE/.cache"
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

[ -d "$FILES" ] || die "files/ directory not found next to install.sh"

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

# ── sysctl (must precede the binary test: see overcommit note above) ─────────
write_sysctl() {
    rssh 'mkdir -p /etc/sysctl.d && cat > /etc/sysctl.d/90-netbird.conf <<SYS
# NetBird on a small router — installed by netbird-glinet-openwrt
# Keep the management gRPC stream alive through CGNAT/NAT timeouts:
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=3
net.ipv4.ip_forward=1
# Go 1.26 binaries reserve a ~35 MB zero-filled BSS at exec time. With the
# default heuristic (0) the kernel rejects that on a 128 MB box and the
# process dies with SIGSEGV before main() runs. "Always overcommit" lets the
# mapping succeed; the pages are only backed when actually touched.
vm.overcommit_memory=1
SYS
sysctl -p /etc/sysctl.d/90-netbird.conf >/dev/null 2>&1 || true'
}
write_sysctl
ok "sysctl tuning written to /etc/sysctl.d/90-netbird.conf (keepalive, ip_forward, overcommit=1)"

# ── 2. Download ───────────────────────────────────────────────────────────────
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

    # ── 3. Push binary ──────────────────────────────────────────────────────
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

# ── 4. Files ──────────────────────────────────────────────────────────────────
say "Installing service, watchdog and admin-panel page…"
rssh 'mkdir -p /usr/libexec/netbird /usr/lib/oui-httpd/rpc /usr/share/gl-validator.d /usr/share/oui/menu.d /www/views /www/i18n /etc/netbird /var/log/netbird'
( cd "$FILES" && COPYFILE_DISABLE=1 tar --format ustar --uid 0 --gid 0 --uname root --gname root -cf - \
    --exclude='./etc/config/netbird' --exclude='./www/views/*.js' --exclude='.DS_Store' --exclude='._*' . ) \
    | rssh 'tar -C / -xf -' || die "file upload failed"
gzip -9 -c "$FILES/www/views/gl-sdk4-ui-netbird.common.js" | rssh 'cat > /www/views/gl-sdk4-ui-netbird.common.js.gz; rm -f /www/views/gl-sdk4-ui-netbird.common.js'
rssh 'chmod 755 /etc/init.d/netbird /usr/libexec/netbird/*.sh /usr/sbin/netbird-status /usr/sbin/netbird-setup-swap; chmod 644 /usr/lib/oui-httpd/rpc/netbird /usr/share/gl-validator.d/netbird.lua /usr/share/oui/menu.d/netbird.json /www/i18n/gl-sdk4-ui-netbird.*.json /www/views/gl-sdk4-ui-netbird.common.js.gz'
ok "files in place"

# UCI config: create only if missing (keeps existing settings / credentials)
if rssh 'uci -q get netbird.settings >/dev/null 2>&1'; then
    ok "existing /etc/config/netbird kept"
else
    rssh 'cat > /etc/config/netbird' < "$FILES/etc/config/netbird"
    ok "UCI config created"
fi
[ -n "$MGMT_URL" ] && rssh "uci set netbird.connection.management_url='$MGMT_URL' && uci commit netbird" && ok "management URL set to $MGMT_URL"
if [ "$MEM_TOTAL" -lt 262144 ]; then
    rssh 'cur=$(uci -q get netbird.settings.gomemlimit); case "$cur" in ""|48MiB) uci set netbird.settings.gomemlimit=32MiB; uci commit netbird ;; esac'
    ok "low-memory router: GOMEMLIMIT=32MiB, GOGC=50"
fi
KMAJ=${KERNEL%%.*}
[ "$KMAJ" -lt 5 ] && rssh 'uci set netbird.settings.disable_ebpf_proxy=1; uci commit netbird' && ok "kernel $KERNEL: eBPF proxy disabled"


# ── 5. Remove leftovers of the old upstream layout (nginx CGI UI, cron, rc.local) ──
rssh 'sh -s' <<'REMOTE'
for f in /etc/nginx/gl-conf.d/netbird.conf /www/cgi-bin/netbird-api /www/cgi-bin/netbird-ui \
         /usr/share/oui/menu.d/netbirdview.json /www/views/gl-sdk4-ui-netbirdview.common.js.gz \
         /usr/libexec/netbird-watchdog.sh /usr/libexec/netbird-cleanup.sh /usr/libexec/netbird-toggle-exit.sh /usr/libexec/netbird-setup-api.sh; do
    [ -e "$f" ] && { rm -f "$f"; echo "   removed old $f"; }
done
rm -f /www/i18n/gl-sdk4-ui-netbirdview.*.json
[ -d /www/netbird ] && { rm -rf /www/netbird; echo "   removed old /www/netbird"; }
if [ -f /etc/crontabs/root ] && grep -q netbird-watchdog /etc/crontabs/root; then
    sed -i '/netbird-watchdog/d' /etc/crontabs/root; echo "   removed old cron line"
fi
if grep -qi netbird /etc/rc.local 2>/dev/null; then
    cp /etc/rc.local /etc/rc.local.pre-netbird
    grep -vi netbird /etc/rc.local > /etc/rc.local.new && mv /etc/rc.local.new /etc/rc.local && chmod +x /etc/rc.local
    echo "   removed NetBird lines from /etc/rc.local (backup: /etc/rc.local.pre-netbird)"
fi
exit 0
REMOTE

# ── 6. Enable + start, reload nginx (panel picks up the RPC object + menu) ────
say "Enabling and starting the service…"
rssh '/etc/init.d/netbird enable; /etc/init.d/netbird restart' >/dev/null 2>&1 || warn "service restart returned an error — check: ssh $ROUTER logread -e netbird"
rssh 'command -v nginx >/dev/null 2>&1 && (nginx -s reload 2>/dev/null || /etc/init.d/nginx reload 2>/dev/null); true'
sleep 3
STATE=$(rssh '. /usr/libexec/netbird/common.sh; nb_load_config; echo "daemon=$(nb_daemon_count) mgmt=$(nb_mgmt_state) wg=$(nb_wg_mode) rss=$(nb_daemon_rss_kb)kB avail=$(nb_mem_available_kb)kB"' 2>/dev/null || true)
ok "service state: $STATE"

HOST=${ROUTER#*@}
echo
echo "────────────────────────────────────────────────────────────────"
echo " Done. Open the GL.iNet admin panel → Applications → NetBird"
echo "   http://$HOST/#/netbird"
echo " Enter your management URL (with port) and a reusable setup key."
echo
echo " SSH helpers:  netbird-status        overview + memory"
echo "               logread -e netbird   watchdog / memory log"
echo "               netbird-setup-swap   USB swap (if RAM gets tight)"
echo "────────────────────────────────────────────────────────────────"
