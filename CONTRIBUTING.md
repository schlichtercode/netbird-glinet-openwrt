# Contributing

## Reporting a bug

Please include:

- Router model and firmware: `cat /etc/glversion /etc/openwrt_release`
- NetBird version: `netbird version`
- Output of `netbird-status`
- Watchdog log: `logread -e netbird | tail -30`
- Client log: `tail -50 /var/log/netbird/client.log`

## Rules for changes

### Shell scripts

- Shebang is `#!/bin/sh`. Target is BusyBox ash, not bash.
- Quote every variable expansion.
- Run `sh -n` on every script before committing.
- GL.iNet BusyBox is missing `pkill`, `od`, `xxd` and `file`.
- Available instead: `killall`, `pgrep`, `hexdump`, `timeout`.

### Memory

- Nothing in the web path may start a Go binary.
- A second `netbird` process (46 MB) makes a 128 MB router thrash.
- Status comes from the daemon's JSON gateway on `127.0.0.1:18090`.
- Process ids come from `ubus call service list`, not from `ps`.
- CLI calls are allowed only for user actions: enroll, connect, disconnect, exit node.

### Service

- The procd init script is the only way to start the daemon.
- No `rc.local`, no cron. GL.iNet's crond reads `/tmp/gl_crontabs`, not `/etc/crontabs`.
- State lives in `/etc/netbird/`. `/var/lib/netbird` is a symlink to it.
- Never put large files in `/tmp`. It is RAM.

### Router-side setup logic

- Everything that changes the router after the files are in place lives in
  `files/usr/libexec/netbird/setup-router.sh` (`sysctl` / `install` / `uninstall`).
  `install.sh` calls it over SSH, the opkg package calls it from `postinst` / `prerm`.
  Do not add such steps to `install.sh` or the package scripts directly.
- The NetBird binary is never part of the package; `netbird-fetch-binary`
  downloads it on the router. The pinned version is in
  `files/usr/share/netbird-glinet/netbird-release` (one place for both installers).
- `postinst` may run from the GL panel inside an nginx worker: never restart
  nginx synchronously there (`nginx_restart_later` in setup-router.sh).

### Configuration

- UCI (`/etc/config/netbird`) is the source of truth.
- The template in `files/etc/config/netbird` is installed only when no config exists.
- A new option needs changes in five places:
  - `common.sh` (`nb_load_config`)
  - the Lua `SCHEMA` in `files/usr/lib/oui-httpd/rpc/netbird`
  - the panel view
  - all seven i18n files
  - the README table

### Lua (GL panel RPC)

- Runs inside GL's nginx with Lua 5.1.
- No `goto`, no integer division.
- `os.execute` returns a number.
- Check syntax with `luac -p`.

### Panel view

- Hand-written Vue 2 render function, no build step.
- `node --check` catches syntax errors only.
- Always test on a real device.

### Notes

- Read `notes/` before starting.
- Update `notes/30-status-todo.md` when behaviour changes.

## Building and releasing the opkg package

```bash
sh packaging/build.sh            # → build/feed/netbird-glinet_<ver>_all.ipk, Packages, Packages.gz
sh packaging/check.sh build/feed # unpack + validate without a router
```

The version comes from the git tag (`v1.2.3` → `1.2.3-1`; untagged builds get `<tag>+N.g<sha>-1`).
Releasing: `git tag v1.2.3 && git push origin v1.2.3`. The workflow `.github/workflows/feed.yml`
builds the package, publishes `build/feed/` to GitHub Pages (repository setting
*Pages → Source: GitHub Actions* must be on once) and attaches the `.ipk` to the GitHub release.
Feed URL: `https://schlichtercode.github.io/netbird-glinet-openwrt`.

To test a build on a router without the feed: `scp build/feed/*.ipk root@<router>:/overlay/` (flash, not `/tmp`),
then `opkg install /overlay/netbird-glinet_*.ipk`.

## Testing on a device

Compatibility report only:

```bash
./install.sh root@<router> --probe
```

Redeploy scripts and panel files after edits:

```bash
./install.sh root@<router> --skip-binary
```

Call the RPC object directly on the router:

```bash
ssh root@<router> 'lua -e "ngx={log=function() end}; local M=dofile(\"/usr/lib/oui-httpd/rpc/netbird\"); print(require\"cjson\".encode(M.get_status({})))"'
```
