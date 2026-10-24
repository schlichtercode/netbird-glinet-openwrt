#!/bin/sh
# Build the opkg package netbird-glinet (.ipk) and a feed index from files/.
#
#   sh packaging/build.sh                → build/feed/netbird-glinet_<ver>_all.ipk, Packages, Packages.gz
#   PKG_VERSION=1.2.3 sh packaging/build.sh   (override the version taken from git tags)
#   OUT=/some/dir sh packaging/build.sh       (output directory, default build/)
#
# No OpenWrt SDK needed: the package is Architecture: all (shell, Lua, JSON,
# JS). The NetBird binary is NOT inside — it is ~46 MB and opkg unpacks via
# /tmp (RAM); postinst downloads it with /usr/sbin/netbird-fetch-binary.
#
# Layout of an OpenWrt .ipk: a gzipped tar with ./debian-binary,
# ./control.tar.gz (control, conffiles, preinst, postinst, prerm) and
# ./data.tar.gz (the file tree). Works with GNU tar (CI) and bsdtar (macOS).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FILES="$ROOT/files"
OUT="${OUT:-$ROOT/build}"
FEED="$OUT/feed"
PKG="netbird-glinet"
ARCH="all"
DEPENDS="curl, lua"

die() { echo "build.sh: $*" >&2; exit 1; }
[ -d "$FILES" ] || die "files/ not found"

# ── version: git tag vX.Y.Z → X.Y.Z-1; otherwise tag+N.g<sha>-1 or 0.0.0+git<sha>-1
if [ -n "${PKG_VERSION:-}" ]; then
    VERSION="$PKG_VERSION"
elif tag=$(git -C "$ROOT" describe --tags --exact-match --match 'v*' 2>/dev/null); then
    VERSION="${tag#v}-1"
elif d=$(git -C "$ROOT" describe --tags --long --match 'v*' 2>/dev/null); then
    # v1.0.0-3-gabc1234 → 1.0.0+3.gabc1234-1  (sorts after 1.0.0, before 1.0.1)
    d="${d#v}"; sha="${d##*-}"; d="${d%-*}"; n="${d##*-}"; base="${d%-*}"
    VERSION="${base}+${n}.${sha}-1"
else
    VERSION="0.0.0+git$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)-1"
fi
case "$VERSION" in [0-9]*) ;; *) die "version '$VERSION' must start with a digit" ;; esac

# ── tar flavour (uid/gid 0, ustar, no macOS metadata)
if tar --version 2>/dev/null | grep -q 'GNU tar'; then
    tar_pack() { tar --format=ustar --owner=0 --group=0 --numeric-owner --sort=name -czf "$1" -C "$2" .; }
else
    tar_pack() { COPYFILE_DISABLE=1 tar --format ustar --uid 0 --gid 0 --uname root --gname root -czf "$1" -C "$2" .; }
fi
md5_of()    { if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | cut -d' ' -f1; else md5 -q "$1"; fi; }
sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
size_of()   { wc -c < "$1" | tr -d ' '; }

STAGE="$OUT/stage/${PKG}_${VERSION}"
DATA="$STAGE/data"
CTRL="$STAGE/control"
rm -rf "$STAGE"; mkdir -p "$DATA" "$CTRL" "$FEED"

# ── data: files/ 1:1, view gzipped (as install.sh does), strict permissions
( cd "$FILES" && COPYFILE_DISABLE=1 tar -cf - --exclude='.DS_Store' --exclude='._*' --exclude='./www/views/*.js' . ) | tar -xf - -C "$DATA"
gzip -9 -n -c "$FILES/www/views/gl-sdk4-ui-netbird.common.js" > "$DATA/www/views/gl-sdk4-ui-netbird.common.js.gz"
find "$DATA" -type d -exec chmod 755 {} +
find "$DATA" -type f -exec chmod 644 {} +
chmod 755 "$DATA"/etc/init.d/* "$DATA"/usr/libexec/netbird/*.sh "$DATA"/usr/sbin/*
# sanity: every shell script parses
for f in "$DATA"/etc/init.d/* "$DATA"/usr/libexec/netbird/*.sh "$DATA"/usr/sbin/* "$HERE"/ipkg/*; do
    case "$(head -1 "$f")" in '#!/bin/sh'*) sh -n "$f" || die "syntax error in $f" ;; esac
done
tar_pack "$STAGE/data.tar.gz" "$DATA"
INSTALLED_SIZE=$(size_of "$STAGE/data.tar.gz")

# ── control
cat > "$CTRL/control" <<CONTROL
Package: $PKG
Version: $VERSION
Depends: $DEPENDS
Section: net
Priority: optional
Architecture: $ARCH
Installed-Size: $INSTALLED_SIZE
Maintainer: netbird-glinet-openwrt <https://github.com/schlichtercode/netbird-glinet-openwrt>
Source: https://github.com/schlichtercode/netbird-glinet-openwrt
License: MIT
Description: NetBird client integration for GL.iNet routers
 procd service with watchdog and memory guard, NetBird page in the GL.iNet
 admin panel (VPN -> NetBird, 7 languages), VPN indicator and dashboard card,
 hardware-switch hook, LAN DNS forwarding and a GL firewall zone.
 The NetBird binary itself (~46 MB) is downloaded from GitHub by postinst
 (netbird-fetch-binary) and verified by SHA256 - it is not in this package.
CONTROL
echo "/etc/config/netbird" > "$CTRL/conffiles"
cp "$HERE/ipkg/preinst" "$HERE/ipkg/postinst" "$HERE/ipkg/prerm" "$CTRL/"
chmod 644 "$CTRL/control" "$CTRL/conffiles"; chmod 755 "$CTRL/preinst" "$CTRL/postinst" "$CTRL/prerm"
tar_pack "$STAGE/control.tar.gz" "$CTRL"
echo "2.0" > "$STAGE/debian-binary"

# ── .ipk (outer tar.gz, OpenWrt ipkg-build layout)
IPK_NAME="${PKG}_${VERSION}_${ARCH}.ipk"
IPK="$FEED/$IPK_NAME"
rm -f "$FEED"/${PKG}_*.ipk
if tar --version 2>/dev/null | grep -q 'GNU tar'; then
    tar --format=ustar --owner=0 --group=0 --numeric-owner -czf "$IPK" -C "$STAGE" ./debian-binary ./control.tar.gz ./data.tar.gz
else
    COPYFILE_DISABLE=1 tar --format ustar --uid 0 --gid 0 --uname root --gname root -czf "$IPK" -C "$STAGE" ./debian-binary ./control.tar.gz ./data.tar.gz
fi

# ── feed index: control fields + Filename/Size/MD5Sum/SHA256sum (opkg format)
{
    grep -v '^Installed-Size:' "$CTRL/control" | sed -n '1,/^Description:/{/^Description:/!p;}'
    echo "Installed-Size: $INSTALLED_SIZE"
    echo "Filename: $IPK_NAME"
    echo "Size: $(size_of "$IPK")"
    echo "MD5Sum: $(md5_of "$IPK")"
    echo "SHA256sum: $(sha256_of "$IPK")"
    sed -n '/^Description:/,$p' "$CTRL/control"
    echo
} > "$FEED/Packages"
gzip -9 -n -c "$FEED/Packages" > "$FEED/Packages.gz"

# ── small landing page for GitHub Pages
cat > "$FEED/index.html" <<HTML
<!doctype html><meta charset="utf-8"><title>netbird-glinet opkg feed</title>
<style>body{font:15px/1.5 system-ui,sans-serif;max-width:48em;margin:3em auto;padding:0 1em}pre{background:#f4f4f4;padding:.8em;overflow:auto}</style>
<h1>netbird-glinet — opkg feed</h1>
<p>NetBird for GL.iNet routers. Source and documentation:
<a href="https://github.com/schlichtercode/netbird-glinet-openwrt">github.com/schlichtercode/netbird-glinet-openwrt</a></p>
<p>Add this feed in the GL.iNet panel (Applications → Software packages → Sources) or in <code>/etc/opkg/customfeeds.conf</code>:</p>
<pre>src/gz netbird_glinet https://schlichtercode.github.io/netbird-glinet-openwrt</pre>
<pre>opkg update &amp;&amp; opkg install netbird-glinet</pre>
<p>Current package: <a href="$IPK_NAME">$IPK_NAME</a> · <a href="Packages">Packages</a> · <a href="Packages.gz">Packages.gz</a></p>
HTML

echo "built $IPK ($(size_of "$IPK") bytes)"
echo "index $FEED/Packages, $FEED/Packages.gz"
