# Running this on a Proxmox LXC

Docker inside an unprivileged LXC container. The slicer ends up reachable at
`http://<lxc-ip>:3000`.

Everything below runs on the **Proxmox host shell** unless it says otherwise.

---

## 1. Sizing

| Resource | Minimum | Comfortable | Why |
|---|---|---|---|
| Cores | 2 | 4–6 | Slicing is CPU-bound and scales with cores |
| RAM | 3 GB | 6 GB | WebKit + the 3D viewport; slicing large plates spikes |
| Disk | 12 GB | 24 GB | ~4.5 GB image, plus models and gcode |
| Swap | 512 MB | 2 GB | |

The container image is ~4.5 GB on disk. A 8 GB rootfs will fail the build.

---

## 2. Create the container

Get an Ubuntu 24.04 template if you do not have one:

```bash
pveam update
pveam available --section system | grep ubuntu-24
pveam download local ubuntu-24.04-standard_24.04-2_amd64.tar.zst
```

Create it. `nesting=1` is what allows Docker to run inside; `keyctl=1` keeps
containerd from failing on kernel keyring calls:

```bash
pct create 210 local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst \
  --hostname anycubic-slicer \
  --cores 4 \
  --memory 6144 \
  --swap 2048 \
  --rootfs local-lvm:24 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --features nesting=1,keyctl=1 \
  --unprivileged 1 \
  --onboot 1 \
  --password
```

Notes:

- **Unprivileged** is the right default. Do not switch to privileged unless GPU
  passthrough refuses to work and you have accepted what that means: a root
  escape inside the container is a root escape on the Proxmox host.
- **`--net0 ... bridge=vmbr0`** puts the container on your LAN directly. That is
  what makes the slicer's mDNS/broadcast printer scan able to see printers. A
  NAT bridge (`vmbr1` style) will break discovery, and you will have to add
  printers by IP.
- If your storage is **ZFS**, Docker cannot use `overlay2`. Either put the
  rootfs on an ext4/LVM storage, or install `fuse-overlayfs` in the container
  and point Docker at it (`/etc/docker/daemon.json`:
  `{"storage-driver": "fuse-overlayfs"}`).

Start it:

```bash
pct start 210
```

---

## 3. GPU passthrough (optional but worth it)

Without it the 3D viewport falls back to `llvmpipe` software rendering: usable,
noticeably sluggish on big models. Slicing speed is unaffected — that is pure
CPU.

Check what the host has:

```bash
ls -l /dev/dri/
getent group render video
```

On **PVE 8.2 and newer**, pass the nodes through by device. `gid=` must be the
group id *inside* the container (Ubuntu 24.04: `render`=104, `video`=44):

```bash
pct set 210 --dev0 /dev/dri/renderD128,gid=104
pct set 210 --dev1 /dev/dri/card0,gid=44
```

On **older PVE**, edit `/etc/pve/lxc/210.conf` by hand instead:

```
lxc.cgroup2.devices.allow: c 226:0 rwm
lxc.cgroup2.devices.allow: c 226:128 rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
```

Restart and verify **inside the container**:

```bash
pct reboot 210
pct exec 210 -- ls -l /dev/dri/
```

`renderD128` must exist and be group-readable. `install.sh` detects it and wires
it into the container automatically; if it is absent the script just warns and
carries on with software rendering.

---

## 4. Install

Everything from here runs **inside the LXC** (`pct enter 210`, or SSH in).

```bash
apt-get update && apt-get install -y git ca-certificates
git clone (https://github.com/DavidCroitoru/anycubic-slicer-docker) /opt/anycubic-slicer
cd /opt/anycubic-slicer
./install.sh
```

The script installs Docker from Docker's official APT repository with its GPG
key pinned to a keyring file, starts the daemon, asks how you want the web UI
exposed, then builds and starts everything. The build takes 5–15 minutes,
mostly downloading the 133 MB slicer package and Mesa.

**Pick option 1 (password, reachable from the LAN).** This is a server on your
network — options 2 and 3 exist for a desktop where the browser is on the same
machine.

Non-interactive, for a provisioning script:

```bash
./install.sh --auth --user david --password "$(openssl rand -base64 18)" --yes
```

---

## 5. Verify

```bash
docker compose ps                       # Up
docker compose logs --tail=50
ss -ltn | grep -E '3000|3001'           # nginx only; 6900/6901 stay on loopback
docker exec anycubic-slicer glxinfo -B | grep "OpenGL renderer"
```

`OpenGL renderer` naming your actual GPU means passthrough worked. `llvmpipe`
means it did not — re-check step 3.

Then open `http://<lxc-ip>:3000`.

---

## 6. Autostart and updates

`--onboot 1` on the container plus `restart: unless-stopped` on the service
means it comes back after a Proxmox host reboot without any extra unit files.

To update the slicer to whatever version Anycubic currently ships:

```bash
cd /opt/anycubic-slicer
docker compose build --no-cache --pull
docker compose up -d
```

Your presets, printers and login live in `./config`, which is a bind mount and
survives rebuilds.

---

## 7. Troubleshooting

| Symptom | Cause |
|---|---|
| `failed to register layer: operation not permitted` | `nesting=1` missing, or ZFS rootfs without `fuse-overlayfs` |
| Container dies at start, `keyctl` in the log | `keyctl=1` missing |
| Build runs out of space | rootfs too small; the image alone is ~4.5 GB |
| `glxinfo` says `llvmpipe` | `/dev/dri` not passed through, or wrong `gid=` |
| Printers not found by the scan | LXC is on a NAT bridge instead of `vmbr0`, or the printers are on another VLAN |
| Web UI unreachable from another machine | `BIND_ADDRESS=127.0.0.1` in `runtime.env` — re-run `./install.sh` and pick option 1 |
