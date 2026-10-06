# Gotham Gather (web GUI)

A web front-end for the end-of-shoot media gather — the same workflow as the
`gather-shoot` skill, driveable from a browser on any machine on the LAN.

**MVP status:** the web app wraps `bin/gather.sh` (a copy of the skill's engine).
It detects devices, lets you pick a shoot name + sources, runs the gather, and
streams live progress to the browser. Phase 2 replaces the shell-out with native
device modules, a job queue, SQLite history, and checksums.

## Layout
```
gather-app/
├── app/
│   ├── main.py          FastAPI: /api/status, /api/gather, /api/jobs/*/events, /
│   ├── detect.py        device probes (Z CAM, PIX, ATEM, USB cards, Drive)
│   └── static/index.html  single-page UI (device cards, source picker, live log)
├── bin/gather.sh        the gather engine (synced from the skill)
├── Dockerfile
└── requirements.txt
```

## Run locally (dev)
```
pip install -r requirements.txt
uvicorn app.main:app --reload --port 8787
# open http://localhost:8787
```

## Build & run the container
```
docker build -t gotham-gather gather-app/
docker run -d --name gotham-gather \
  --network host \
  --cap-add SYS_ADMIN --security-opt apparmor=unconfined \
  -v /mnt/user/isos:/data/isos \
  -v /root/.config/rclone:/root/.config/rclone \
  -v /mnt/disks:/data/cards:ro \
  gotham-gather
# UI at http://<unraid-ip>:8787
```

### Why these flags
- `--network host` — the app must reach the camera subnets (`.99`, `.100`, `.102`),
  which are routed via the Unraid gateway. Host networking inherits that routing.
- `-v /mnt/user/isos:/data/isos` — the destination share (read-write).
- `-v …/rclone:…` — reuse the existing `gdrive` rclone remote for field audio.
  **Must be read-write** so rclone can persist refreshed OAuth tokens (a read-only
  mount makes every refresh fail to save and errors the audio probe).
- `--cap-add SYS_ADMIN` — **network sources only need this** for the kernel CIFS
  mounts (PIX/ATEM). It is *not* full `--privileged`. (Phase 2 switches SMB to a
  userspace client — `smbprotocol` — and drops this cap entirely.)

## USB camera cards (the host-mount + bind model)
Per the chosen design, the container does **not** mount `/dev` itself. Instead:
1. Unraid's **Unassigned Devices** auto-mounts an inserted card at `/mnt/disks/<LABEL>`.
2. Bind that into the container: `-v /mnt/disks:/data/cards:ro`.
3. **Phase-2 TODO:** point the `cards` source at `/data/cards/*` (read already-mounted
   dirs) instead of detecting + mounting block devices. A UD *device script* hook can
   POST to `/api/card-inserted` so the UI lights up the moment a card is plugged in.

Until that change lands, card ingest still works by running the gather **on the host**
(`bash bin/gather.sh <shoot> cards`); the network sources all work in the container now.

## Unraid "Add Container" template (summary)
| Field | Value |
|---|---|
| Repository | `gotham-gather` (local build) |
| Network Type | `Host` |
| Extra Params | `--cap-add SYS_ADMIN --security-opt apparmor=unconfined` |
| Path | `/data/isos` → `/mnt/user/isos` (RW) |
| Path | `/root/.config/rclone` → `/root/.config/rclone` (**RW** — token refresh) |
| Path | `/data/cards` → `/mnt/disks` (RO) |
| WebUI | `http://[IP]:8787` |

## Config
Device addresses, the PIX drive, the Drive folder id, and the rclone remote are read
from env vars (see `app/detect.py`) and `bin/gather.sh`'s CONFIG block. Keep the two in
sync until phase 2 unifies them.
