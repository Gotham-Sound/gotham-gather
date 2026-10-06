# Running Gotham Gather as an Unraid container

The image `gotham-gather:latest` is already built on this server. These steps add it
as a **managed Unraid container** (editable in the UI, auto-starts on boot).

## Step 0 — remove the test container
The test instance is holding the name `gotham-gather` and port 8787. Remove it first
(terminal, the `>_` icon):
```
docker rm -f gotham-gather
```

## Step 1 — Docker tab → Add Container
Unraid web UI → **Docker** tab → bottom → **Add Container**. Flip the toggle at the
top-right to **Advanced View** (needed for Extra Parameters). Fill in:

| Field | Value |
|---|---|
| **Name** | `gotham-gather` |
| **Repository** | `gotham-gather:latest` |
| **Network Type** | **Host**  ← important (see why below) |
| **Console shell command** | `bash` |
| **WebUI** | `http://[IP]:8787/` |
| **Extra Parameters** | `--cap-add SYS_ADMIN --security-opt apparmor=unconfined` |
| **Icon URL** | *(optional)* |

> **Local-image note:** because this image was built here (not pulled from a registry),
> when you click **Apply** Unraid may print a "pull failed / not found" warning — that's
> expected. It then creates the container from the **local** image and starts normally.

## Step 2 — add the Paths (click "Add another Path, Port, Variable…")
Add three **Path** mappings:

| Config Type | Name | Container Path | Host Path | Access |
|---|---|---|---|---|
| Path | isos | `/data/isos` | `/mnt/user/isos` | **Read/Write** |
| Path | rclone | `/root/.config/rclone` | `/root/.config/rclone` | **Read/Write** |
| Path | cards | `/data/cards` | `/mnt/disks` | Read Only |

- **isos** — where gathered media is written (must be Read/Write).
- **rclone** — reuses your existing `gdrive` remote for field audio. **Read/Write** so
  rclone can save refreshed OAuth tokens (read-only breaks the audio probe once the
  access token expires).
- **cards** — bind of Unraid's Unassigned-Devices mount point, for the phase-2 USB path.

## Step 3 — (optional) Variables to override device addresses
Defaults are baked into the image, so you can skip this. To change a device IP without
rebuilding, add **Variable** entries (Key → Value):

| Key | Default |
|---|---|
| `PIX_HOST` | `192.168.99.192` |
| `ATEM_HOST` | `192.168.100.10` |
| `ZCAM_HOST` | `192.168.102.52` |
| `AUDIO_FOLDER_ID` | `1t8Bm5MCO_I64Z3ebDugy_rciigizeB81` |
| `RCLONE_REMOTE` | `gdrive` |

## Step 4 — Apply
Click **Apply**. The container starts; you'll see it on the Docker tab. The **Autostart**
toggle there (leave it **ON**) brings it back after a reboot. Open the UI from the
container's **WebUI** link, or directly:

```
http://192.168.100.50:8787
```

---

## Why "Host" network (not Bridge)
The app has to reach three *different* subnets — PIX `192.168.99.x`, ATEM `192.168.100.x`,
Z CAM `192.168.102.x` — which are routed through the Unraid gateway. **Host** networking
gives the container the host's routing table so those reach. Bridge would isolate it and
the device probes would all show "unreachable." (A side effect of Host mode: no port
mapping is needed — the app is directly on `:8787` of the server.)

## Why the two Extra Parameters
`--cap-add SYS_ADMIN` lets the container do the kernel **CIFS mounts** for PIX/ATEM.
`--security-opt apparmor=unconfined` lets those mounts proceed under Unraid's AppArmor.
This is **not** full `--privileged`. Phase 2 switches SMB to a userspace client and drops
both.

## Updating the image later
After editing code, rebuild and recreate:
```
cd /mnt/disks/VM_DISK/unclaude/gather-app
docker build -t gotham-gather .
```
Then on the Docker tab: click the container → **Force Update** (or Stop → Start). Your
template settings (paths, params) are preserved.

## Simplest alternative (skip the UI template)
If you'd rather not use the template, this one-liner runs it persistently and it will
come back on reboot via the restart policy:
```
docker run -d --name gotham-gather --restart unless-stopped \
  --network host --cap-add SYS_ADMIN --security-opt apparmor=unconfined \
  -v /mnt/user/isos:/data/isos \
  -v /root/.config/rclone:/root/.config/rclone \
  -v /mnt/disks:/data/cards:ro \
  gotham-gather
```
Trade-off: it shows in the Docker tab but isn't editable via the template UI.
