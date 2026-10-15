# Gotham Gather (web GUI)

A web front-end for the end-of-shoot media gather — the same workflow as the
`gather-shoot` skill, driveable from a browser on any machine on the LAN.

The web app wraps `bin/gather.sh` (a copy of the `gather-shoot` skill's engine). It's an
**explicit "see-and-confirm" tool**: it detects every card by its *real* project + CAM#
(flagging any from a different shoot), you check what belongs to the shoot and confirm,
and it streams live progress with a per-source at-a-glance status. See `EZ-INSTRUCTIONS.md`
for the usage walkthrough and `UNRAID-SETUP.md` for deployment.

## Layout
```
gather-app/
├── app/
│   ├── main.py          FastAPI endpoints (see below) + job runner with live progress
│   ├── detect.py        device probes + enriched card identities (project/CAM#)
│   └── static/index.html  single-page see-and-confirm UI
├── bin/gather.sh        the gather engine (synced from the skill)
├── Dockerfile           python + rsync/smbclient/cifs/rclone, TZ=America/New_York
└── requirements.txt
```

### Key API endpoints
- `GET  /api/detect-items` — every available item (cards by real identity + mismatch flag,
  PIX, ATEM, audio); probes run concurrently.
- `POST /api/gather-selected` — gather only the chosen items (`cards:[mountpaths]`, plus
  `pix`/`atem`/`audio`) into a shoot.
- `POST /api/add-upload` (multipart) · `POST /api/add-link` · `POST /api/add-path` —
  add arbitrary files (browser upload / Drive link / server path) into `<shoot>/<subfolder>/`.
- `GET  /api/shoot-status?shoot=…` — per-source ingest status (pending/copying/verified).
- `GET  /api/jobs/{id}/events` — SSE live log for a running job. `GET /` serves the UI.

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
The container does **not** mount `/dev` itself (stays non-privileged). Instead:
1. Unraid's **Unassigned Devices** auto-mounts an inserted card at `/mnt/disks/<LABEL>`.
2. That's bound into the container as `/data/cards` with **`rslave`** propagation, so a
   card mounted *after* the container started still appears inside it (see `UNRAID-SETUP.md`).
3. `detect.card_items()` reads each mounted card dir, parses the `.braw` filename for its
   project + CAM#, and `gather-selected` ingests only the cards you checked
   (`card:<mountpath>` → `CAM-N/`), verified. Failing/stale mounts are timeout-guarded so
   they can't stall the scan.

The same `bin/gather.sh` also runs standalone on the host (`bash bin/gather.sh <shoot> cards`).

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
