"""Device detection for the gather app.

MVP: lightweight probes that mirror exactly what gather.sh does, returning
structured status the web UI can render. Phase 2 will consolidate these and
gather.sh's CONFIG block into one source of truth.
"""
from __future__ import annotations
import subprocess, shutil, datetime, os, re, json
from dataclasses import dataclass, asdict

# --- site config (keep in sync with gather.sh CONFIG block) ---
ZCAM_HOST   = os.environ.get("ZCAM_HOST", "192.168.102.52")
PIX_HOST    = os.environ.get("PIX_HOST", "192.168.99.192")
PIX_DRIVE   = os.environ.get("PIX_DRIVE", "1")
ATEM_HOST   = os.environ.get("ATEM_HOST", "192.168.100.10")
ATEM_SHARE  = os.environ.get("ATEM_SHARE", "1003")
AUDIO_FOLDER_ID = os.environ.get("AUDIO_FOLDER_ID", "1t8Bm5MCO_I64Z3ebDugy_rciigizeB81")
RCLONE_REMOTE   = os.environ.get("RCLONE_REMOTE", "gdrive")
SHARE       = os.environ.get("ISOS_SHARE", "/mnt/user/isos")

def _run(cmd: list[str], timeout: int = 12) -> tuple[int, str]:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except Exception as e:  # noqa: BLE001
        return 1, str(e)

def _today() -> str:
    return datetime.date.today().isoformat()

def _human(n: int) -> str:
    f = float(n)
    for u in "BKMGT":
        if f < 1024 or u == "T":
            return f"{f:.1f}{u}"
        f /= 1024
    return f"{f:.1f}T"

@dataclass
class Device:
    key: str
    name: str
    reachable: bool
    detail: str = ""
    ready: bool = False          # has material for today / usable now
    items: list | None = None    # files/folders it would pull

# ---- individual probes ----

def detect_zcam() -> Device:
    rc, out = _run(["curl", "-sf", "-m", "6", f"http://{ZCAM_HOST}/info"])
    if rc != 0:
        return Device("zcam", "Z CAM (remote)", False, "unreachable")
    today = _today().replace("-", "")
    rc, dcim = _run(["curl", "-s", "-m", "8", f"http://{ZCAM_HOST}/DCIM/"])
    clips = []
    for fol in re.findall(r'"([A-Z0-9]+)"', dcim):
        if fol == "files":
            continue
        rc, listing = _run(["curl", "-s", "-m", "10", f"http://{ZCAM_HOST}/DCIM/{fol}/"])
        for f in re.findall(r'"([^"]+\.(?:MOV|MP4))"', listing):
            ts = re.search(r"(\d{8})", f)
            clips.append({"name": f, "folder": fol, "today": bool(ts and ts.group(1) == today)})
    todays = [c for c in clips if c["today"]]
    return Device("zcam", "Z CAM (remote)", True,
                  f"{len(todays)} clip(s) today / {len(clips)} total", bool(todays), clips)

def detect_pix() -> Device:
    rc, _ = _run(["bash", "-c", f"timeout 2 bash -c 'echo > /dev/tcp/{PIX_HOST}/80'"])
    if rc != 0:
        return Device("pix", "PIX recorder", False, "unreachable")
    rc, tr = _run(["curl", "-s", "-m", "6", f"http://{PIX_HOST}/sounddevices/transport"])
    rc, cur = _run(["curl", "-s", "-m", "6",
                    f"http://{PIX_HOST}/sounddevices/invoke/RemoteApi/currentRecordTake()"])
    rc, mode = _run(["curl", "-s", "-m", "6",
                     f"http://{PIX_HOST}/sounddevices/getsettings/RecordToDrive{PIX_DRIVE}"])
    m = re.search(r'"Transport":"([^"]*)"', tr); transport = m.group(1) if m else "?"
    m = re.search(r'/([^/"]+\.mov)', cur, re.I); curfile = m.group(1) if m else ""
    m = re.search(r'"RecordToDrive\d":"([^"]*)"', mode); dmode = m.group(1) if m else "?"
    recording = transport == "rec"
    # Build the detail gracefully: the current reel is only reported by the recorder in
    # Record/standby; during an active pull (Ethernet File Transfer) it's unavailable.
    bits = [f"drive {PIX_DRIVE}: {dmode}"]
    if curfile:
        bits.insert(0, f"reel {curfile}")
    elif dmode.startswith("Ethernet"):
        bits.append("on network (pulling / released)")
    if recording:
        bits.append("RECORDING")
    return Device("pix", "PIX recorder", True, " · ".join(bits),
                  ready=not recording,
                  items=[{"name": curfile, "mode": dmode}] if curfile else [{"mode": dmode}])

def detect_atem() -> Device:
    rc, out = _run(["smbclient", f"//{ATEM_HOST}/{ATEM_SHARE}",
                    "-U", "guest%", "-c", "ls"], timeout=15)
    if rc != 0 and "NT_STATUS" in out:
        # try listing shares to confirm reachability
        rc2, _ = _run(["smbclient", "-L", f"//{ATEM_HOST}", "-N"], timeout=10)
        if rc2 != 0:
            return Device("atem", "ATEM switcher", False, "unreachable")
    # parse directory entries: "  <name>  D  0  <date>"
    folders = []
    for line in out.splitlines():
        m = re.match(r"\s+(.+?)\s+D\s+\d+\s+(\w{3}\s+\w{3}\s+\d+\s[\d:]+\s\d{4})", line)
        if m and m.group(1) not in (".", ".."):
            folders.append(m.group(1).strip())
    # today's folder = newest; the UI shows the list and flags likely-today by name
    return Device("atem", "ATEM switcher", True,
                  f"{len(folders)} project folder(s)", bool(folders),
                  [{"name": f} for f in folders[-6:]])

CARDS_DIR = os.environ.get("CARDS_DIR", "")

def detect_cards() -> Device:
    # Container path: read already-mounted card dirs under CARDS_DIR (Unraid mounts the
    # card, /mnt/disks is bind-mounted in). A non-privileged container can't see host
    # block devices via lsblk, so this is the reliable path when CARDS_DIR is set.
    import glob
    if CARDS_DIR and os.path.isdir(CARDS_DIR):
        cards = []
        try:
            names = sorted(os.listdir(CARDS_DIR))
        except OSError:
            names = []
        for name in names:
            d = os.path.join(CARDS_DIR, name)
            try:
                if not os.path.isdir(d):
                    continue
                has = bool(glob.glob(os.path.join(d, "*.braw")) or
                           glob.glob(os.path.join(d, "*", "*.braw")))
            except OSError:
                continue   # a failing/stale USB mount (I/O error) — skip, never break detection
            if has:
                cards.append({"label": name, "dev": name})
        return Device("cards", "Camera cards (USB)", True,
                      f"{len(cards)} card(s) with footage" if cards else "no cards mounted",
                      bool(cards), cards)
    # Host path: USB-transport exfat partitions (parent disk is USB).
    rc, usb = _run(["bash", "-c", "lsblk -rno NAME,TRAN | awk '$2==\"usb\"{print $1}'"])
    usb_disks = set(usb.split())
    rc, out = _run(["bash", "-c", "lsblk -rno NAME,SIZE,FSTYPE,PKNAME,LABEL"])
    cards = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 4 and parts[2] == "exfat" and parts[3] in usb_disks:
            label = parts[4] if len(parts) > 4 else parts[0]
            cards.append({"dev": parts[0], "size": parts[1], "label": label})
    return Device("cards", "Camera cards (USB)", True,
                  f"{len(cards)} card(s) detected" if cards else "no cards plugged in",
                  bool(cards), cards)

def detect_audio() -> Device:
    if not shutil.which("rclone"):
        return Device("audio", "Field audio (Drive)", False, "rclone not installed")
    def _parse(out):
        w = []
        for line in out.splitlines():
            m = re.match(r"\s*(\d+)\s+([\d-]+\s[\d:.]+)\s+(.+\.wav)", line, re.I)
            if m:
                w.append({"name": m.group(3).strip(), "size": _human(int(m.group(1))),
                          "modified": m.group(2)[:10]})
        return w

    def _ls():
        return _run(["rclone", "lsl", f"{RCLONE_REMOTE}:", "--drive-root-folder-id",
                     AUDIO_FOLDER_ID, "--low-level-retries", "2"], timeout=25)

    rc, out = _ls()
    wavs = _parse(out)
    # A read-only rclone config makes the token refresh fail to SAVE (non-zero exit) even
    # though the listing still comes through — treat that as reachable.
    ro_save = "read-only file system" in out
    if not wavs and rc != 0 and not ro_save:
        # The first call right after a container start can fail while rclone does its
        # initial token refresh. Retry once before calling it an error.
        rc, out = _ls()
        wavs = _parse(out)
        ro_save = ro_save or "read-only file system" in out
        if not wavs and rc != 0 and not ro_save:
            low = out.lower()
            if any(k in low for k in ("invalid_grant", "unauthor", "401", "token has been expired",
                                      "couldn't fetch token", "oauth")):
                return Device("audio", "Field audio (Drive)", False,
                              "rclone auth expired — re-run: rclone authorize \"drive\"")
            return Device("audio", "Field audio (Drive)", False, "Drive unreachable — will retry")
    detail = f"{len(wavs)} WAV(s) in Drive folder"
    if ro_save:
        detail += " · ⚠ rclone config read-only (mount RW so tokens refresh)"
    return Device("audio", "Field audio (Drive)", True, detail, bool(wavs), wavs)

def detect_all() -> dict:
    devices = [detect_cards(), detect_pix(), detect_atem(), detect_zcam(), detect_audio()]
    return {"generated": datetime.datetime.now().isoformat(timespec="seconds"),
            "devices": [asdict(d) for d in devices]}

def list_shoots() -> list[dict]:
    try:
        entries = sorted(os.listdir(SHARE))
    except OSError:
        return []
    out = []
    for name in entries:
        p = os.path.join(SHARE, name)
        if os.path.isdir(p) and re.match(r"\d{4}-\d{2}-", name):  # rubric folders
            out.append({"name": name})
    return out[::-1]  # newest first
