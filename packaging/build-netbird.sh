#!/bin/sh
# Build a patched NetBird client binary for a router (default: GL-SFT1200,
# linux/mipsle softfloat) from the upstream source, applying the patches in
# packaging/patches/. Needs git and Go (the go.mod toolchain is fetched
# automatically). No OpenWrt SDK involved.
#
#   sh packaging/build-netbird.sh [version] [arch] [gomips]
#     version  NetBird tag without "v" (default: NETBIRD_VERSION_MIPS32 from
#              files/usr/share/netbird-glinet/netbird-release)
#     arch     GOARCH (default mipsle); gomips: softfloat|hardfloat (default softfloat)
#
# Output: build/netbird-<version>-<arch>_<gomips>/netbird, plus a copy in
# .cache/<version>-<arch>_<gomips>/netbird so that
#   ./install.sh root@<router> --force
# uploads it instead of the GitHub release (install.sh reuses a cached binary).
#
# Why: NetBird <= 0.81.4 drops remote ICE candidates that arrive before the
# ICE agent exists; on a 500-BogoMIPS router that is nearly always, so peers
# stay on the relay (5 Mbit/s, CPU-bound). The patch buffers them.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
NETBIRD_VERSION_MIPS32=""; . "$ROOT/files/usr/share/netbird-glinet/netbird-release"
VER="${1:-$NETBIRD_VERSION_MIPS32}"; ARCH="${2:-mipsle}"; GOMIPS="${3:-softfloat}"
SRC="$ROOT/build/netbird-src"
OUT="$ROOT/build/netbird-$VER-${ARCH}_$GOMIPS"
command -v go >/dev/null || { echo "go not found" >&2; exit 1; }

if [ ! -d "$SRC/.git" ]; then
    git clone -q --depth 1 --branch "v$VER" https://github.com/netbirdio/netbird.git "$SRC"
else
    git -C "$SRC" fetch -q --depth 1 origin "refs/tags/v$VER:refs/tags/v$VER" && git -C "$SRC" checkout -q "v$VER"
fi
git -C "$SRC" checkout -q -- . && git -C "$SRC" clean -qfd
for p in "$HERE"/patches/netbird-"$VER"-*.patch; do
    [ -f "$p" ] || continue
    echo "applying $(basename "$p")"
    git -C "$SRC" apply --check "$p" && git -C "$SRC" apply "$p"
done
COMMIT=$(git -C "$SRC" rev-parse --short HEAD)
mkdir -p "$OUT"
echo "building netbird $VER for linux/$ARCH ($GOMIPS)…"
( cd "$SRC" && CGO_ENABLED=0 GOOS=linux GOARCH="$ARCH" GOMIPS="$GOMIPS" \
    go build -trimpath -ldflags "-s -w -X github.com/netbirdio/netbird/version.version=$VER -X main.commit=$COMMIT+patched -X main.builtBy=netbird-glinet-openwrt" \
    -o "$OUT/netbird" ./client )
CACHE="$ROOT/.cache/$VER-${ARCH}_$GOMIPS"; mkdir -p "$CACHE"; cp "$OUT/netbird" "$CACHE/netbird"
echo "built $OUT/netbird ($(( $(wc -c < "$OUT/netbird") / 1024 / 1024 )) MB), copied to $CACHE/netbird"
echo "install with: ./install.sh root@<router> --force"
