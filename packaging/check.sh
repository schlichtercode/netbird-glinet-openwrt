#!/bin/sh
# Validate a built feed directory without a router:
#   sh packaging/check.sh build/feed
# Unpacks the .ipk (outer tar.gz → control.tar.gz / data.tar.gz), checks the
# control file, maintainer scripts, conffiles, file modes, and that the
# Packages index matches the .ipk (Filename/Size/MD5Sum/SHA256sum).
set -eu
FEED="${1:-build/feed}"
die() { echo "check.sh: FAIL: $*" >&2; exit 1; }
md5_of()    { if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | cut -d' ' -f1; else md5 -q "$1"; fi; }
sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

IPK=$(ls "$FEED"/netbird-glinet_*_all.ipk 2>/dev/null | head -1)
[ -n "$IPK" ] || die "no netbird-glinet_*_all.ipk in $FEED"
[ -f "$FEED/Packages" ] && [ -f "$FEED/Packages.gz" ] || die "Packages / Packages.gz missing"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
tar -xzf "$IPK" -C "$T" || die "ipk is not a gzipped tar"
for f in debian-binary control.tar.gz data.tar.gz; do [ -f "$T/$f" ] || die "$f missing in ipk"; done
[ "$(cat "$T/debian-binary")" = "2.0" ] || die "debian-binary must be 2.0"
mkdir "$T/c" "$T/d"
tar -xzf "$T/control.tar.gz" -C "$T/c"
tar -xzf "$T/data.tar.gz" -C "$T/d"

# control
for k in Package Version Architecture Depends Description Installed-Size; do
    grep -q "^$k:" "$T/c/control" || die "control lacks $k"
done
[ "$(sed -n 's/^Package: //p' "$T/c/control")" = netbird-glinet ] || die "wrong Package name"
[ "$(sed -n 's/^Architecture: //p' "$T/c/control")" = all ] || die "Architecture must be all"
grep -q '^Depends: curl, lua$' "$T/c/control" || die "Depends must be 'curl, lua'"
[ "$(cat "$T/c/conffiles")" = "/etc/config/netbird" ] || die "conffiles must list /etc/config/netbird"
for s in preinst postinst prerm postrm; do
    [ -x "$T/c/$s" ] || die "$s missing or not executable"
    sh -n "$T/c/$s" || die "$s has a syntax error"
done
grep -q 'setup-router.sh install' "$T/c/postinst" || die "postinst does not call setup-router.sh install"
grep -q 'setup-router.sh uninstall --keep-files' "$T/c/prerm" || die "prerm does not call setup-router.sh uninstall"

# data
for f in etc/init.d/netbird etc/config/netbird etc/sysctl.d/90-netbird.conf \
         usr/libexec/netbird/setup-router.sh usr/libexec/netbird/common.sh usr/sbin/netbird-fetch-binary \
         usr/share/netbird-glinet/netbird-release usr/lib/oui-httpd/rpc/netbird \
         usr/share/oui/menu.d/netbird.json www/views/gl-sdk4-ui-netbird.common.js.gz \
         www/i18n/gl-sdk4-ui-netbird.en.json www/i18n/gl-sdk4-ui-netbird.de.json; do
    [ -f "$T/d/$f" ] || die "data lacks $f"
done
[ -f "$T/d/www/views/gl-sdk4-ui-netbird.common.js" ] && die "plain view .js must not be packaged (only .gz)"
[ -f "$T/d/usr/bin/netbird" ] && die "the NetBird binary must not be in the package"
for f in etc/init.d/netbird usr/libexec/netbird/setup-router.sh usr/sbin/netbird-fetch-binary usr/sbin/netbird-status; do
    [ -x "$T/d/$f" ] || die "$f is not executable"
done
gzip -t "$T/d/www/views/gl-sdk4-ui-netbird.common.js.gz" || die "view .gz corrupt"
# tar entries must be ./-prefixed with uid/gid 0 (opkg installs them as root)
# (GNU tar prints "root/root" or "0/0", bsdtar prints "0 root   root")
tar -tvzf "$T/data.tar.gz" | grep -vE ' (root/root|0/0|[0-9]+ +root +root) ' | grep -q . && die "data.tar.gz has non-root owners"
tar -tzf "$T/data.tar.gz" | grep -qv '^\./' && die "data.tar.gz entries must start with ./"

# index ↔ ipk
name=$(basename "$IPK")
idx_file=$(sed -n 's/^Filename: //p' "$FEED/Packages"); [ "$idx_file" = "$name" ] || die "Packages Filename '$idx_file' != $name"
idx_size=$(sed -n 's/^Size: //p' "$FEED/Packages"); [ "$idx_size" = "$(wc -c < "$IPK" | tr -d ' ')" ] || die "Packages Size mismatch"
[ "$(sed -n 's/^MD5Sum: //p' "$FEED/Packages")" = "$(md5_of "$IPK")" ] || die "Packages MD5Sum mismatch"
[ "$(sed -n 's/^SHA256sum: //p' "$FEED/Packages")" = "$(sha256_of "$IPK")" ] || die "Packages SHA256sum mismatch"
[ "$(sed -n 's/^Version: //p' "$FEED/Packages")" = "$(sed -n 's/^Version: //p' "$T/c/control")" ] || die "Packages Version != control Version"
gzip -dc "$FEED/Packages.gz" | cmp -s - "$FEED/Packages" || die "Packages.gz does not match Packages"
# exactly one stanza, terminated by a blank line, no stray blank lines inside
[ "$(grep -c '^Package:' "$FEED/Packages")" = 1 ] || die "Packages must contain exactly one stanza"
[ "$(tail -c 1 "$FEED/Packages" | od -An -c | tr -d ' ')" = '\n' ] || die "Packages must end with a newline"

echo "check.sh: OK — $name ($idx_size bytes), version $(sed -n 's/^Version: //p' "$T/c/control")"
tar -tzf "$T/data.tar.gz" | grep -v '/$' | sed 's|^\./|  |'
