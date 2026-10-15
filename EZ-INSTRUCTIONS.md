# Gotham Gather — EZ Instructions (tech cheat-sheet)

Quick reference for running and maintaining the app. Full deploy details are in
`UNRAID-SETUP.md`; architecture in `README.md`.

- **App (team UI):** http://192.168.100.50:8787
- **Repo:** https://github.com/Gotham-Sound/gotham-gather (private)
- **Code on server:** `/mnt/disks/VM_DISK/unclaude/gather-app`
- **Container:** `gotham-gather` (Unraid Docker tab) · image `gotham-gather:latest`
- **Media lands in:** `/mnt/user/isos/<shoot>/` (e.g. `2026-09-MWU`)

![Gotham Gather dashboard](docs/img/dashboard.png)

*See-and-confirm flow: (1) name the shoot, (2) check what belongs — every card shows its
real project + CAM# with a "matches" / "⚠ different shoot" badge (mismatches start
unchecked), (3) add other files (uploads, Drive links, server paths). Then Gather, with a
live progress bar + an at-a-glance status per source.*

---

## Everyday use (team)
**It's explicit now — you see every card's real identity and confirm before anything copies.**
1. **Name the shoot** (step 1).
2. **Check what to gather** (step 2): each detected card shows its *actual* project + CAM#.
   Anything matching today's shoot is pre-checked; anything from a **different shoot is
   flagged ⚠ and left unchecked**. PIX / ATEM / Audio appear as their own checkboxes.
   Review, then **Gather checked** → confirm → live progress + the at-a-glance strip.
3. **Add other files** (step 3) for anything not on a card: **upload** from your computer
   (iPhone clips), paste a **Drive link**, or point at a **server path** — each into a
   subfolder you name (e.g. `CAM-iPhone`, `AUDIO`).

> No more sticky "active shoot" auto-ingest — plugging a card no longer silently copies
> into whatever shoot was last set. That mix-up is gone; everything is checked + confirmed.
> Always use a **REAR** USB port for cards (front ports are flaky).

---

## Updating the app (after a code change)
```
cd /mnt/disks/VM_DISK/unclaude/gather-app
# edit code, then:
docker build -t gotham-gather:latest .
```
Then **Docker tab → `gotham-gather` → Edit → Apply** (recreates from the new local image).
A "couldn't pull image" warning is normal for a local build — it uses the local copy.

> Don't recreate **mid-copy** — it interrupts the running gather (it resumes, but
> re-verifies what was already done). Wait for the current copy, or deploy when a
> source just finished (finished files are skipped on the next run).

Commit + push changes:
```
git add -A && git commit -m "…"
git push    # origin = https://github.com/Gotham-Sound/gotham-gather.git
```

---

## Field audio — two ways
- **Normal:** TK uploads WAVs to the shared Drive folder
  (`1t8Bm5MCO_I64Z3ebDugy_rciigizeB81`). Run the **Audio** source — it grabs only the
  recent ones (last 72h), not old shoots'.
- **Paste a Drive link (in the app):** if TK shares a *direct link* instead of using the
  folder, paste it into the **🔗 Audio by Drive link** field (under Manual gather), make
  sure the shoot name is set, and click **Pull audio**. It extracts the file ID and pulls
  the file straight into `<shoot>/AUDIO/` with live status.
  *CLI equivalent:* `rclone backend copyid gdrive: <FILE_ID> "/mnt/user/isos/<shoot>/AUDIO/"`
  (`<FILE_ID>` is the long string in a Drive URL `/file/d/<FILE_ID>/view`).

---

## Plug-and-go cards (one-time setup)
For zero-click ingest the card must auto-mount on the host and reach the container:
1. **Unassigned Devices** (Main tab) → toggle **Automount ON** for the card.
2. Container must bind `/mnt/disks` with **`rslave`** propagation (in Extra Parameters):
   `--mount type=bind,source=/mnt/disks,target=/data/cards,readonly,bind-propagation=rslave`
   (see `UNRAID-SETUP.md`).
If a card doesn't appear: it's not mounted — hit **Mount** on it in Unassigned Devices,
or mount it by hand: `mount -t exfat -o ro /dev/sdX2 /mnt/disks/<label>`.

---

## Troubleshooting (things we actually hit)
| Symptom | Cause / fix |
|---|---|
| **Progress bar frozen at 0% / "starting…"** | Running the old image. Rebuild + Edit→Apply. (Fixed: output is read by `\r` so rsync % flows live.) |
| **"no cards" but a card is plugged in** | Card isn't *mounted*. Enable UD Automount, or Mount it in Unassigned Devices. Cards show as exfat USB disks (`lsblk`). |
| **Card copy hangs after one card** | A stale/failing `/mnt/disks` mount (dead USB device) stalled the scan. Hardened now (timeout-guarded). Clear dead mounts: `umount -l /mnt/disks/<name>`. |
| **Audio: "rclone auth/remote error"** | Usually a cold-start blip right after Apply — hit **Rescan**. If persistent: the rclone config mount must be **Read/Write** (token refresh). Re-auth: `rclone authorize "drive" --drive-scope=drive.readonly`. |
| **A card is plugged in but not in the list** | It's not *mounted* (enable UD Automount, or Mount it in Unassigned Devices), or it's a stale/blank card. Then **Rescan**. |
| **Copied the wrong shoot's footage** | Each card now shows its real project + CAM# with a ⚠ flag — only check cards that match this shoot. Eject old shoots' cards. |
| **Front USB port** | Flaky — cards read as 0-byte / don't enumerate. Use a **REAR** port. |

---

## Verifying a shoot is fully backed up
`/mnt/user/isos/<shoot>/` should have (per what was shot): `CAM-1..N/` (braw masters),
`CAM-TK/` (Z CAM), `PIX/`, `ATEM/<Project>/`, `AUDIO/`. The app's **At a glance** strip
and the engine's `✓ verified` (byte/hash checks) confirm each. Every transfer is
size/hash-verified; nothing is deleted from a card, recorder, or Drive.

*Last updated 2026-10-06.*
