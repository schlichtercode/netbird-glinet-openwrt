# Upstream bug reports for netbirdio/netbird (drafts)

Two independent client bugs found while running NetBird 0.81.4 on a slow MIPS
router (GL.iNet GL-SFT1200, 128 MB RAM). Together they keep every peer
connection on the relay. Both are fixed by the patches in
[`packaging/patches/`](../packaging/patches/), which this project applies in
its own build (`packaging/build-netbird.sh`). Hostnames and public addresses
below are anonymised.

Suggested: open them as two issues, each with its patch as a PR.

---

## Issue 1 — Remote ICE candidates are dropped when they arrive before the ICE agent exists (slow hosts never get a P2P connection)

**Title:** `client: remote ICE candidates dropped before the agent exists → peers stay on relay on slow hosts`

### Environment

- NetBird client 0.81.4 (official `linux_mipsle_softfloat` release, go1.26.10), kernel WireGuard
- Router: GL.iNet GL-SFT1200, MIPS 24K-class (interAptiv, 531 BogoMIPS/core, 4 logical cores), 128 MB RAM, Linux 4.14.90 (OpenWrt 18.06 based GL.iNet firmware 4.8.3)
- Peers: an exit node (0.81.4, Debian 13, public IP, UDP 51820 open) and a LAN peer (0.81.3)
- Self-hosted management/signal/relay; lazy connections enabled
- Client flags: `--disable-client-routes=false`, `NB_DISABLE_EBPF_WG_PROXY=true`, `NB_SKIP_NFTABLES_CHECK=true`

### Symptom

Every peer connection is `Relayed`, forever. `netbird status` shows no local
ICE candidate type for any peer. Throughput through the exit node is ~5 Mbit/s
with the daemon using ~1.8 CPU cores (relay path in userspace).

### Evidence

Client log at `info` level, repeating for every (re)connection:

```
WARN [peer: ccQZ…] client/internal/peer/worker_ice.go:165: ICE Agent is not initialized yet
WARN [peer: ccQZ…] client/internal/peer/worker_ice.go:165: ICE Agent is not initialized yet
…
INFO [peer: ccQZ…] client/internal/peer/state_dump.go:79: Dump stat: Status: Connected, SentOffer: 6, RemoteOffer: 4, RemoteAnswer: 6, RemoteCandidate: 20, P2PConnected: 0, …
```

20 remote candidates received, 19 warnings — nearly every candidate of a
session is discarded. `grep -c "ICE Agent is not initialized"` over one
evening: 19; `grep -c "connection succeeded"`: 0.

### Root cause

`client/internal/peer/worker_ice.go` (v0.81.4, lines 160–167):

```go
func (w *WorkerICE) OnRemoteCandidate(candidate ice.Candidate, haRoutes route.HAMap) {
	w.muxAgent.Lock()
	defer w.muxAgent.Unlock()
	…
	if w.agent == nil {
		w.log.Warnf("ICE Agent is not initialized yet")
		return
	}
```

The agent is only created in `OnNewOffer`, which runs from the handshaker
goroutine, while candidate messages are dispatched straight from the signal
receive loop. The remote side sends its candidates right after its
offer/answer, so on a slow host the candidates are regularly processed before
the offer and are thrown away. There is no buffer and the remote peer does
not resend them until the next ICE restart, where the race repeats. With
lazy connections the remote side always initiates, so the local side is
always in the losing position.

### Fix (patch attached)

Buffer candidates that arrive while `w.agent == nil` (bounded, 64 entries)
and add them to the agent right after it is created in `OnNewOffer`; clear
the buffer in `Close()`. Patch:
[`netbird-0.81.4-buffer-remote-candidates.patch`](../packaging/patches/netbird-0.81.4-buffer-remote-candidates.patch).

With the patch the log shows

```
INFO [peer: U6U2…] client/internal/peer/worker_ice.go:167: adding 3 remote candidate(s) buffered before the ICE agent existed
DEBG [peer: U6U2…] client/internal/peer/worker_ice.go:460: discovered local candidate udp4 host 172.16.80.155:51820 …
DEBG [peer: U6U2…] client/internal/peer/worker_ice.go:460: discovered local candidate udp4 srflx 198.51.100.81:2033 related 0.0.0.0:51820 …
```

and ICE proceeds to `Checking` (it then still failed because of Issue 2).

---

## Issue 2 — `CheckFwmarkSupport()` uses a 100 ms dial timeout; slow hosts silently fall back to legacy routing, which breaks P2P through an active exit node

**Title:** `client: fwmark capability probe times out on slow hosts (100 ms) → legacy routing → ICE checks routed into the tunnel`

### Environment

Same as Issue 1.

### Symptom

At every start:

```
WARN client/net/env_linux.go:88: failed to dial with fwmark: dial udp 127.0.0.1:9: i/o timeout
WARN client/net/env_linux.go:66: system doesn't support required routing features, falling back to legacy routing
INFO client/internal/routemanager/systemops/systemops_linux.go:101: Using legacy routing setup
```

The kernel supports `SO_MARK` and policy rules fine (see below). Once an exit
node is selected (`0.0.0.0/1` + `128.0.0.0/1` via `wt0` in legacy mode) the
client's own ICE connectivity checks towards the exit node's public candidate
are routed into the tunnel, so every ICE attempt ends in

```
DEBG … worker_ice.go:617: ICE ConnectionState has changed to Checking
DEBG … worker_ice.go:460: discovered local candidate udp4 host 172.16.80.155:51820 …
DEBG … worker_ice.go:460: discovered local candidate udp4 srflx 198.51.100.81:2033 …
DEBG … worker_ice.go:617: ICE ConnectionState has changed to Failed
DEBG … worker_ice.go:304: failed to dial the remote peer: connecting canceled by caller
```

(remote candidates received: `host 203.0.113.21:51820`, `srflx 203.0.113.21:51820` — a directly reachable public exit node.)

### Root cause

`client/net/env_linux.go`, `CheckFwmarkSupport()`:

```go
	dialer := NewDialer()
	dialer.Timeout = 100 * time.Millisecond
	conn, err := dialer.Dial("udp", "127.0.0.1:9")
	if err != nil {
		log.Warnf("failed to dial with fwmark: %v", err)
		return false
	}
```

On a 531-BogoMIPS CPU that is starting the daemon (GC under `GOMEMLIMIT`,
interface setup, management connection in parallel) the marked UDP dial does
not complete within 100 ms. The probe reports "unsupported" and the client
silently degrades to legacy routing for the whole run.

### Fix (patch attached)

Raise the dial timeout and write deadline to 3 s:
[`netbird-0.81.4-fwmark-probe-timeout.patch`](../packaging/patches/netbird-0.81.4-fwmark-probe-timeout.patch).
A capability probe should not be time-critical; alternatively make it
retry once, or expose an env override (`NB_FORCE_ADVANCED_ROUTING`) the
way `NB_USE_LEGACY_ROUTING` exists.

### Result with both patches on the same router

```
INFO client/net/env_linux.go:70: system supports advanced routing
INFO [peer: U6U2…] client/internal/peer/worker_ice.go:360: connection succeeded with offer session: 1eb7ec198c
INFO [peer: U6U2…] client/internal/peer/conn.go:437: set ICE to active connection
INFO [peer: U6U2…] client/internal/peer/conn.go:472: configure WireGuard endpoint to: 203.0.113.21:51820
INFO [peer: U6U2…] client/internal/peer/wg_watcher.go:101: first wg handshake detected within: 0.74sec
```

`ip rule` now has `105: from all lookup main suppress_prefixlength 0` and
`110: not from all fwmark 0x1bd00 lookup netbird`; both peers show
`P2P` in `netbird status`. A 20 MB download through the exit node went from
5.2 Mbit/s (relay, daemon at ~1.8 cores) to 20.9 Mbit/s (daemon at ~1 % CPU,
limit is now the router's 2.4 GHz uplink).

---

## Side observations (not filed)

- `client/iface/udpmux/universal.go:90: error while reading packet: No decoder for layer type DNS` appeared a few times on the shared raw socket for the WireGuard port.
- `client/internal/peer/guard/ice_monitor.go:65: Failed to check ICE changes: wait for gathering timed out` once, while peer agents gathered fine.
- Idle daemon CPU is ~39 % of one core with `GOGC=50 GOMEMLIMIT=32MiB` and 22 MB RSS; probably GC pressure from the tight limit.
