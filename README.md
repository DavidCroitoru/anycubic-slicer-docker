# Anycubic Slicer Next — in Docker, in your browser

Runs [Anycubic Slicer Next](https://github.com/ANYCUBIC-3D/AnycubicSlicer) (an OrcaSlicer
fork, Ubuntu-24.04-only upstream) inside a container on any Linux host, served over the web
via [KasmVNC](https://www.kasmweb.com/kasmvnc).

Upstream ships an APT repo rather than an AppImage, and its installer script hard-refuses
anything other than Ubuntu 24.04 (`noble`). The image is built on
`ghcr.io/linuxserver/baseimage-kasmvnc:ubuntunoble` so the `.deb` gets exactly the
distribution it expects.

## Quick start

```bash
./install.sh
```

That is the whole thing. The script:

1. detects your distribution, GPU, timezone and UID/GID;
2. installs Docker if it is missing — from your distro's packages, or from Docker's own
   APT repository with its GPG key pinned to a keyring file. It never pipes a remote
   script into a shell;
3. asks how you want the web UI exposed (see below);
4. writes `runtime.env` (mode 600) and `docker-compose.override.yml`;
5. builds the image and starts the container.

Then open the URL it prints. The slicer autostarts into the desktop.

Running on a Proxmox LXC? See **[PROXMOX-LXC.md](PROXMOX-LXC.md)** for the container
options that have to be set on the Proxmox side first.

Non-interactive:

```bash
./install.sh --no-auth                            # loopback only, no password
./install.sh --auth --user david --yes            # random password, LAN-reachable
./install.sh --auth --password 'hunter2' --bind 0.0.0.0
./install.sh --network bridge --port 8080         # isolated netns, no printer discovery
./install.sh --help
```

Re-run it any time to change your mind; it rewrites the config and recreates the container.

## Who can reach it

The web desktop gives whoever opens it **full control of the slicer** — loading and saving
files anywhere the container can reach, and talking to your printers. `install.sh` offers
three postures:

| | Auth | Bound to | Use when |
|---|---|---|---|
| 1 | password | `0.0.0.0` | a server or LXC you browse to from another machine |
| 2 | none | `127.0.0.1` | the browser runs on the same machine as the container |
| 3 | none | `0.0.0.0` | you have accepted that anyone on the LAN can drive it |

Option 3 requires typing `YES` at the prompt. Never port-forward any of them to the
internet.

### What the image hardens

The linuxserver.io base image is built for a trusted LAN, and running it with
`network_mode: host` exposes assumptions that are fine behind a bridge but not on a host
interface. Three things are changed here:

- **Ports 6900 and 6901 are pinned to loopback.** Upstream starts Xvnc with
  `-disableBasicAuth -SecurityTypes None -interface 0.0.0.0` and kclient with
  `http.listen(6900)`. Both hand out the full desktop with no authentication whatsoever,
  and both sit *behind* nginx — so with host networking they were reachable from the LAN
  directly, bypassing the basic-auth gate entirely. The Dockerfile rewrites both listeners at
  build time, with `grep -q` guards that fail the build if an updated base image changes those
  lines. nginx on 3000/3001 is the only front door.
- **nginx honours `BIND_ADDRESS`.** The stock template listens on `0.0.0.0` and `[::]`
  unconditionally; `init-asn-bind` rewrites it.
- **No terminal emulator.** `xterm` is purged from the image and removed from the Openbox
  menu, so the web desktop offers no shell. (`docker exec` from the host still does, which
  is the point.)

The container also runs with `no-new-privileges`, `cap_drop: ALL` and only the six
capabilities s6-overlay needs to drop from root to `PUID` (`CHOWN`, `DAC_OVERRIDE`,
`FOWNER`, `SETGID`, `SETUID`, `KILL`).

`seccomp:unconfined` is still needed — desktop apps regularly trip Docker's default
seccomp profile — and is the one genuine loosening left.

### Host networking, and when to drop it

The default is `network_mode: host`, because the slicer's device scan uses mDNS and UDP
broadcast and those do not cross a bridge. If you do not need discovery, `--network bridge`
puts the container in its own network namespace and publishes only the ports you asked for;
printers can still be added by IP.

## The watchdog

The slicer exits when its (broken, see below) setup wizard is dismissed, which would leave
the browser tab looking at an empty desktop. `/usr/local/bin/asn-watchdog` relaunches it.

- A run shorter than `WATCHDOG_MIN_UPTIME` (20 s) counts as a crash and backs off
  exponentially up to `WATCHDOG_MAX_DELAY` (60 s), so a broken install settles at one
  launch per minute instead of spinning.
- `WATCHDOG_MAX_LAUNCHES=0` means unlimited.
- Every launch and exit is logged to `config/watchdog.log`.

Stop and resume it without restarting anything:

```bash
docker exec anycubic-slicer touch /config/.watchdog-off   # let the app stay closed
docker exec anycubic-slicer rm    /config/.watchdog-off   # resume
```

## GPU acceleration

`install.sh` passes `/dev/dri` through when a render node exists. Confirm it is live:

```bash
docker exec -it anycubic-slicer glxinfo -B | grep -E "OpenGL renderer|OpenGL version"
```

You want a real GPU name (`AMD Radeon Graphics (radeonsi, krackan1, ...)`). `llvmpipe`
means it fell back to software rendering — everything still works, the viewport is just
slow. Slicing speed is unaffected either way; that is pure CPU.

Ubuntu noble ships Mesa 24.0, which predates support for recent AMD iGPUs (Krackan /
gfx115x, i.e. Radeon 840M/860M). The Dockerfile adds the `kisak-mesa` PPA to pull Mesa 25.x
or newer, which fixes that. If you see `llvmpipe` on a machine that should have a GPU:

```bash
docker exec -it anycubic-slicer apt-cache policy libgl1-mesa-dri
```

## Data

| Path | What |
| --- | --- |
| `./config` | `$HOME` inside the container: presets, projects, logins, slicer settings, `watchdog.log` |
| `${MODELS_DIR}` → `/config/models` | your STL/3MF files |

Both are bind mounts, so everything survives image rebuilds. Anything written outside
`/config` does not.

`./config` holds your Anycubic session token in cleartext (in the app's own debug logs). It
is in `.gitignore` for that reason — keep it out of version control.

## Configuration files

| File | Committed | What |
| --- | --- | --- |
| `.env` | no | build/host settings: `ASN_VERSION`, `MODELS_DIR` |
| `runtime.env` | no | container environment: auth, bind address, PUID, watchdog knobs |
| `docker-compose.override.yml` | no | network mode, published ports, GPU devices |
| `.env.example`, `runtime.env.example` | yes | documented templates |

All three generated files are produced by `install.sh`. `runtime.env` is mode 600 because
it holds the password.

Basic auth is enabled **if and only if `PASSWORD` exists** in `runtime.env`. An empty
`PASSWORD=` line still enables it — with an empty password. That is why the environment
lives in its own file rather than in `docker-compose.yml`: "no auth" has to mean the
variable is absent, and compose cannot conditionally omit a key.

## Updating

```bash
docker compose build --no-cache --pull
docker compose up -d
```

This picks up whatever version is current in Anycubic's repo. To pin one, set `ASN_VERSION`
in `.env` (e.g. `1.3.96`) — it becomes an `apt install anycubicslicernext=<version>`.

## ⚠️ Status: the GUI is blocked by an upstream bug

**The container works. The application's first-run dialogs do not.**

On launch, Anycubic Slicer Next opens two modal dialogs — "Setup Wizard" and
"Param Update" — and both render as empty windows (opaque black without a compositor,
fully transparent with one). Because they are modal, the main window ignores all input
until they are dismissed, and closing the Setup Wizard makes the application exit. The
net effect is that the GUI cannot currently be driven to a usable state.

This is **not** caused by containerisation. The same image was run against this host's
native Wayland/XWayland session, with a real compositor and the host GPU, and the dialogs
were identically empty. It matches public reports of Anycubic Slicer Next on Linux, where
users describe being "stuck on the setup wizard screen" and getting past it only by
clicking blindly.

Ruled out by testing, in case you want to pick up the thread:

| Hypothesis | Result |
| --- | --- |
| `WEBKIT_DISABLE_DMABUF_RENDERER` / `..._COMPOSITING_MODE` | No effect, set or unset |
| No X compositor (RGBA windows) | `xcompmgr` turns black into transparent — content still absent |
| Xvnc reporting `0mm x 0mm` → broken DPI | `Xft.dpi`/`xrandr --dpi 96` changes nothing |
| Software vs hardware GL | Same either way |
| WebKit `pages://` MIME bug (reported on the AUR) | Not applicable — this image resolves `.html` to `text/html`; verified with the upstream probe script against WebKitGTK 2.52.3 |
| Bundled fonts (the AUR package deletes them) | Removing `resources/fonts` changes nothing |
| Missing write access to the resource tree | Was a real bug, now fixed in the image — but not the cause |
| Pre-seeding printer presets / `privacy_version` | Wizard still appears |
| Running as root | App does not start at all |

### What does work

Headless slicing through the CLI is fully functional, GPU and all:

```bash
docker exec -u abc -e HOME=/config anycubic-slicer sh -c '
R=/usr/share/AnycubicSlicerNext/resources/profiles/Anycubic
/usr/bin/AnycubicSlicerNext \
  --load-settings "$R/machine/Anycubic Kobra 3 0.4 nozzle.json;$R/process/0.20mm Standard @Anycubic Kobra 3 0.4 nozzle.json" \
  --load-filaments "$R/filament/Anycubic PLA @Anycubic Kobra 3 0.4 nozzle.json" \
  --arrange 1 --slice 0 --outputdir /config/models /config/models/your.stl'
```

Verified end to end: a 20 mm cube produced a valid 100-layer `plate_1.gcode`.
Run `AnycubicSlicerNext --help` in the container for the full option list.

Also confirmed working: the web desktop and its auth, GPU acceleration
(`radeonsi, krackan1`, OpenGL 4.6), the main window and its embedded WebKit views,
`/config` and model-mount persistence.

If you need a working *graphical* slicer for Anycubic printers today, `lscr.io/linuxserver/orcaslicer`
is the same upstream engine with Anycubic profiles and no such bug.

## Notes and caveats

- **The Anycubic APT repo is unsigned.** The Dockerfile adds it with `[trusted=yes]`, exactly
  as [Anycubic's own installer script](https://cdn-universe-slicer.anycubic.com/install/AnycubicSlicerNextInstaller.sh)
  does. Transport is HTTPS, but the packages themselves carry no signature.
- **`seccomp:unconfined` and a 2 GB `/dev/shm`** are both needed. Desktop apps regularly trip
  Docker's default seccomp profile, and WebKit crashes on the default 64 MB shm.
- **`WEBKIT_DISABLE_DMABUF_RENDERER` / `WEBKIT_DISABLE_COMPOSITING_MODE`** are set in the
  image. Without them the embedded WebKitGTK views (login, device panel, store) render as a
  blank white box in a container.
- **Being in the `docker` group is root-equivalent** on the host. `install.sh` says so before
  offering to add you.
- **Right-click the desktop** for an Openbox menu — it relaunches the slicer without
  restarting the container. There is deliberately no terminal entry.
- **`/config/.config/openbox/autostart` and `menu.xml` are seeded once** by the base image and
  then belong to you. `init-asn-autostart` migrates the pre-watchdog versions on upgrade and
  leaves your edits alone afterwards (backups land next to them as `*.bak`).

## Layout

```
install.sh                                    one-shot installer, interactive
Dockerfile                                    image build
docker-compose.yml                            service definition
.env.example / runtime.env.example            config templates
PROXMOX-LXC.md                                Proxmox LXC deployment guide

root/usr/local/bin/asn-watchdog               relaunches the slicer when it exits
root/defaults/autostart                       openbox session -> the watchdog
root/defaults/menu.xml                        openbox menu, no terminal

root/etc/s6-overlay/s6-rc.d/
  init-asn-perms/       fixes resource-tree ownership after the PUID remap
  init-asn-autostart/   migrates stale autostart/menu copies in /config
  init-asn-bind/        applies BIND_ADDRESS to nginx
```

Xvnc's and kclient's listeners are moved onto loopback by `sed` in the Dockerfile rather
than by shipping modified copies of the base image's scripts — the copies would go stale
on every base image update, and the guarded build fails loudly instead.
