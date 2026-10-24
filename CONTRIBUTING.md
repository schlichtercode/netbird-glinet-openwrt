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
