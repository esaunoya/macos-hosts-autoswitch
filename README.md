# hosts-autoswitch

![platform: macOS](https://img.shields.io/badge/platform-macOS-blue)
![license: MIT](https://img.shields.io/badge/license-MIT-green)

> **macOS only.** This tool uses `launchd`, `dscacheutil`, and `mDNSResponder`,
> so it does not run on Linux or Windows. The detection approach is portable if
> you want to adapt it, but this repo ships macOS tooling only.

Use **one short hostname** to reach a machine whether you're at home or away —
fast on the LAN, seamless over your VPN/overlay network, and unbothered by a
full-tunnel VPN that hijacks DNS.

`hosts-autoswitch` keeps a single line in your Mac's `/etc/hosts` pointing at:

- the host's **LAN IP** when you're on your home/trusted network (a raw,
  full-speed local path), and
- the host's **remote IP** (e.g. a [Tailscale](https://tailscale.com) `100.x`
  address) everywhere else.

A tiny LaunchDaemon re-evaluates this on every network change.

## The problem it solves

Connecting to a home server by name is surprisingly fragile:

- **mDNS / `.local` / your router's DNS** stop resolving the moment a
  full-tunnel VPN (Proton VPN, corporate VPN, etc.) captures your DNS queries.
- A **static `/etc/hosts` entry** fixes that — but it's unconditional, so a
  hardcoded LAN IP is simply wrong when you're away from home.
- Pointing the name at your **Tailscale IP** works everywhere, but at home it
  rides the WireGuard overlay instead of the raw LAN, costing throughput — and
  if local peer discovery is blocked it can fall back to a relay and leave your
  network entirely.

There's no single static answer, so this tool makes the one `/etc/hosts` line
**location-aware**: LAN IP at home, remote IP away, recomputed automatically.

## How it works

- On every network change (and at boot), a root LaunchDaemon runs a small shell
  script.
- The script probes the configured **LAN IP** with `ssh-keyscan` and compares
  the host key it gets back to a **pinned fingerprint**.
  - **Match** → you're home → write `LAN_IP  <host>`.
  - **No match / unreachable** → write `REMOTE_IP  <host>`.
- It rewrites only that one line in `/etc/hosts`, atomically and with
  validation (see [Safety](#safety)).

### Why host-key identity, not subnet matching?

Plenty of networks use `192.168.x.x`, and *something* may answer at "your"
LAN IP on a café or office network. Matching on subnet (or even a successful
ping) could silently connect you to a stranger's device. A host's **SSH host
key is unique to that host**, so requiring the pinned key means the LAN path is
trusted only when the *real* machine is actually there. If it isn't, the tool
fails safe to the remote IP.

### Why `/etc/hosts`?

`/etc/hosts` is consulted *before* DNS, so it keeps resolving your hostname even
when a full-tunnel VPN has taken over DNS — the exact case where `.local`/mDNS
breaks.

## Requirements

- **macOS** (uses `launchd`, `dscacheutil`, `mDNSResponder`).
- **Root** to install (edits `/etc/hosts` and installs a LaunchDaemon).
- The host runs **SSH** (only its host key is read; no login happens).
- A **stable remote-reachable IP** for the host. Tailscale is the easy path;
  ZeroTier, a WireGuard peer IP, or a static WAN IP + port-forward also work.
  > If you use Tailscale, it must be installed and logged in for the remote IP
  > to be reachable — keep that in mind when setting up a brand-new machine.

## Installation

```sh
git clone https://github.com/esaunoya/macos-hosts-autoswitch.git
cd macos-hosts-autoswitch

# 1. Create your config from the template.
cp config.example config

# 2. Capture the host's SSH host-key fingerprint (run against any IP/name that
#    reaches the host right now — Tailscale is fine; the key is the same on the
#    LAN). Copy the printed SHA256:... value into HOST_KEY_FP in `config`.
./capture-fingerprint.sh <host-or-ip>

# 3. Edit the rest of config: MANAGED_HOST, LAN_IP, REMOTE_IP.
$EDITOR config

# 4. Install + start the daemon.
sudo ./install.sh
```

That's the whole thing: set three values, paste one auto-captured fingerprint,
run one script. The installer backs up `/etc/hosts`, installs the script to
`/usr/local/sbin`, your config to `/usr/local/etc` (mode `600`), generates and
loads the LaunchDaemon, and runs it once so the entry is correct immediately.

### Verify

```sh
# What did it decide?
tail -n 5 /var/log/hosts-autoswitch.log

# The managed line right now:
grep <MANAGED_HOST> /etc/hosts

# End to end:
ping -c1 <MANAGED_HOST>
```

When you change networks (or toggle your VPN), it re-runs automatically; check
the log to watch it flip between `home/LAN` and `remote`.

## Configuration reference

All settings live in `config` (git-ignored). See `config.example`.

| Key             | Required | Default   | Meaning                                                        |
|-----------------|----------|-----------|----------------------------------------------------------------|
| `MANAGED_HOST`  | yes      | —         | Hostname managed in `/etc/hosts` (the name you type).          |
| `LAN_IP`        | yes      | —         | Host's IP on your home/trusted LAN.                            |
| `REMOTE_IP`     | yes      | —         | Host's remote-reachable IP (e.g. Tailscale `100.x`).           |
| `HOST_KEY_FP`   | yes      | —         | Pinned SSH host-key fingerprint (`SHA256:...`).                |
| `HOST_KEY_TYPE` | no       | `ed25519` | Host-key type to probe/pin.                                    |
| `SSH_PORT`      | no       | `22`      | Host's SSH port.                                               |
| `PROBE_TIMEOUT` | no       | `3`       | Seconds to wait for the LAN host-key probe.                    |

## Use cases

- **Home server / NAS** reachable by one name from home and on the road.
- **Working over a full-tunnel VPN** (Proton VPN, etc.) that breaks mDNS/`.local`.
- **Same-name access** for SSH, SMB shares, web UIs, backups — anything that
  takes a hostname.
- **Full LAN throughput at home** (large media/backup transfers) without giving
  up remote reachability.

## Why not split-horizon DNS?

The conventional way to serve different IPs for one name by location is
[split-horizon DNS](https://en.wikipedia.org/wiki/Split-horizon_DNS): run a
resolver (e.g. [Pi-hole](https://pi-hole.net) + `dnsmasq`, or Tailscale's
[Split DNS](https://tailscale.com/kb/1054/dns)) that hands LAN clients the LAN
IP and remote clients the remote IP. `dnsmasq` can even return the address
matching the querying interface's subnet (`localise-queries`).

If you already run a resolver like Pi-hole, that may be the better fit — it
applies network-wide, to every device at once, not just one Mac.

`hosts-autoswitch` exists for the cases split-horizon DNS doesn't cover well:

- **No infrastructure.** No DNS server to run, secure, and keep alive — it's a
  ~60-line script and a LaunchDaemon on the one machine that needs it.
- **Survives full-tunnel VPNs.** A VPN like Proton that captures DNS on the
  client means your split-horizon resolver never sees the query, so the name
  stops resolving. `/etc/hosts` is read *before* DNS, so this keeps working —
  it's the exact scenario this tool was built for.
- **Per-device, not network-wide.** Give one laptop this behavior without
  touching anything else on the network.

Rule of thumb: **split-horizon DNS** for one network-wide rule when you already
run a resolver; **hosts-autoswitch** for a per-device, server-less setup that
keeps working behind a full-tunnel VPN.

## Safety

Editing `/etc/hosts` as root deserves care; this tool is deliberately
conservative:

- It rewrites **only the line for your managed host** — every other entry is
  passed through untouched.
- It writes to a temp file, then **validates** the result is non-empty and
  still contains `127.0.0.1 localhost` before swapping it in. If validation
  fails, the live file is left **unchanged**.
- The swap is an **atomic rename** within `/etc`, so there's no window where
  `/etc/hosts` is half-written.
- The `ssh-keyscan` probe runs with a **hard timeout**, so it can't stall
  network transitions.
- The worst-case failure mode is "the name points at a stale IP" — recoverable,
  and never something that can break general networking or `localhost`.

A one-time backup is saved to `/etc/hosts.bak.hosts-autoswitch` on first install.

## Uninstall

```sh
sudo ./uninstall.sh
```

Removes the daemon, script, and config. It prints the command to restore your
original `/etc/hosts` from the backup if you want it.

## Notes & limitations

- **macOS only.** The detection logic is portable, but the LaunchDaemon and DNS
  cache flush are macOS-specific.
- **Host-key rotation:** if the host is rebuilt and its SSH host key changes,
  re-run `./capture-fingerprint.sh`, update `HOST_KEY_FP`, and reinstall.
  Until then it fails safe to the remote IP.
- **One host per install.** Managing several hosts means several configs and
  daemons; this is intentionally kept simple.
- **Canonical name only.** The tool manages the `/etc/hosts` line where your
  host is the *canonical* (first) name — i.e. `<ip>  MANAGED_HOST`. Don't also
  list `MANAGED_HOST` as a trailing alias on some other line; such a line is
  left untouched and would shadow the managed entry.
- **Triggering:** it reacts to network changes via `WatchPaths` on
  `resolv.conf`. If you want a periodic safety net, add a `StartInterval` to the
  plist template — left out by default to avoid probing strange networks on a
  timer.

## License

MIT — see [LICENSE](LICENSE).
