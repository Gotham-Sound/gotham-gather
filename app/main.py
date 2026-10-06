"""Gather app — MVP web GUI over the gather-shoot workflow.

Wraps bin/gather.sh: detects devices, starts per-source gather jobs, and streams
their live output to the browser. Phase 2 replaces the shell-out with native
device modules + a job queue + SQLite history.
"""
from __future__ import annotations
import asyncio, os, re, uuid, time, json
from pathlib import Path
from dataclasses import asdict
from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse, StreamingResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from . import detect

APP_DIR = Path(__file__).parent
GATHER_SH = os.environ.get("GATHER_SH", str(APP_DIR.parent / "bin" / "gather.sh"))
SHARE = detect.SHARE
RCLONE_REMOTE = detect.RCLONE_REMOTE
VALID_SOURCES = {"cards", "pix", "atem", "zcam", "audio", "sweep", "pixeft", "pixrec"}
SHOOT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")

app = FastAPI(title="Gotham Gather")

# in-memory job registry (MVP). {job_id: {proc, lines[], done, shoot, sources}}
JOBS: dict[str, dict] = {}

# Persisted "active shoot" state (survives restarts via the isos volume) + auto-ingest.
STATE_FILE = os.path.join(SHARE, ".gather-state.json")

def _load_state() -> dict:
    try:
        with open(STATE_FILE) as f:
            s = json.load(f)
    except Exception:  # noqa: BLE001
        s = {}
    s.setdefault("active_shoot", "")
    s.setdefault("auto_ingest", True)
    return s

def _save_state() -> None:
    try:
        with open(STATE_FILE, "w") as f:
            json.dump(STATE, f)
    except Exception:  # noqa: BLE001
        pass

STATE = _load_state()
# watcher bookkeeping
AUTO = {"seen": set(), "job": None, "shoot": None}

# ---- per-shoot ingest status (the at-a-glance panel) ----
# States: pending (not gathered) · copying (job running, with pct) · verified (engine's
# ✓ byte/hash check passed) · present (on disk, verification marker not captured) · error.
STATUS_SOURCES = ["cards", "pix", "atem", "zcam", "audio"]
SHOOT_STATUS: dict[str, dict] = {}
_HDR = re.compile(r"\b(CARDS|PIX|ATEM|ZCAM|AUDIO)\s+[—-]")       # gather.sh section headers
_PCT = re.compile(r"(\d{1,3})%")
_VERIFIED = ("✓ verified", "0 differences found", "done — safe to remove", "already have")

def _status_path(shoot): return os.path.join(SHARE, shoot, ".gather-status.json")

def shoot_status(shoot: str) -> dict:
    if shoot not in SHOOT_STATUS:
        try:
            with open(_status_path(shoot)) as f:
                SHOOT_STATUS[shoot] = json.load(f)
        except Exception:  # noqa: BLE001
            SHOOT_STATUS[shoot] = {}
    return SHOOT_STATUS[shoot]

def _persist_status(shoot: str):
    try:
        os.makedirs(os.path.join(SHARE, shoot), exist_ok=True)
        with open(_status_path(shoot), "w") as f:
            json.dump(SHOOT_STATUS.get(shoot, {}), f)
    except Exception:  # noqa: BLE001
        pass

def _set_src(shoot, src, **kw):
    st = shoot_status(shoot).setdefault(src, {})
    st.update(kw); st["updated"] = time.strftime("%H:%M:%S")

def _disk_present(shoot: str, src: str) -> bool:
    base = os.path.join(SHARE, shoot)
    def nonempty(sub):
        p = os.path.join(base, sub)
        try:
            return os.path.isdir(p) and any(not f.startswith(".") for f in os.listdir(p))
        except OSError:
            return False
    if src == "pix":   return nonempty("PIX")
    if src == "atem":  return nonempty("ATEM")
    if src == "audio": return nonempty("AUDIO")
    if src == "zcam":  return nonempty("CAM-TK")
    if src == "cards":
        try:
            return any(re.match(r"CAM-\d", d) and nonempty(d) for d in os.listdir(base))
        except OSError:
            return False
    return False


async def _spawn_job(shoot: str, sources: list[str], cmd: list[str],
                     trust_rc: bool = False) -> str:
    """Run `cmd` as a tracked job, streaming output and tracking per-source status.
    trust_rc=True marks the source verified on a clean exit (for a plain rclone pull
    that doesn't print the engine's own ✓ verified line)."""
    job_id = uuid.uuid4().hex[:8]
    proc = await asyncio.create_subprocess_exec(
        *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
    job = {"proc": proc, "lines": [], "done": False, "rc": None,
           "shoot": shoot, "sources": sources, "started": time.time()}
    JOBS[job_id] = job
    for s in sources:
        if s in STATUS_SOURCES:
            _set_src(shoot, s, state="copying", pct=0, detail="starting…")
    _persist_status(shoot)

    async def pump():
        assert proc.stdout
        state = {"cur": sources[0] if (len(sources) == 1 and sources[0] in STATUS_SOURCES) else None}

        def handle(raw_line: str):
            line = re.sub(r"\x1b\[[0-9;]*m", "", raw_line).rstrip()
            if not line:
                return
            hm = _HDR.search(line)
            if hm:
                state["cur"] = hm.group(1).lower()
            cur = state["cur"]
            pm = _PCT.search(line)
            is_progress = bool(pm and "/s" in line)   # rsync/rclone progress line
            if not is_progress:                        # keep progress spam out of the log
                job["lines"].append(line); del job["lines"][:-500]
            if cur in STATUS_SOURCES:
                if any(m in line for m in _VERIFIED):
                    _set_src(shoot, cur, state="verified", pct=100, detail=line.strip()[:90]); _persist_status(shoot)
                elif "✗" in line:
                    _set_src(shoot, cur, state="error", detail=line.strip()[:90]); _persist_status(shoot)
                elif is_progress:
                    _set_src(shoot, cur, state="copying", pct=int(pm.group(1)), detail="copying…")

        # Read raw chunks and split on BOTH \r and \n: rsync --info=progress2 updates
        # the percentage with carriage returns, which a line-by-line (\n) reader only
        # sees when the file finishes — making the bar look frozen mid-copy.
        buf = b""
        while True:
            chunk = await proc.stdout.read(65536)
            if not chunk:
                break
            buf += chunk
            segs = re.split(rb"[\r\n]", buf)
            buf = segs.pop()
            for seg in segs:
                handle(seg.decode(errors="replace"))
        if buf:
            handle(buf.decode(errors="replace"))
        job["rc"] = await proc.wait(); job["done"] = True
        for s in sources:   # finalize anything still 'copying' we never saw a ✓ for
            if s in STATUS_SOURCES and shoot_status(shoot).get(s, {}).get("state") == "copying":
                present = _disk_present(shoot, s)
                if trust_rc and job["rc"] == 0 and present:
                    _set_src(shoot, s, state="verified", pct=100, detail="done")
                else:
                    _set_src(shoot, s, state=("present" if present else "pending"),
                             detail=("on disk" if present else "nothing gathered"))
        _persist_status(shoot)

    asyncio.create_task(pump())
    return job_id


async def start_gather(shoot: str, sources: list[str]) -> str:
    return await _spawn_job(shoot, sources, ["bash", GATHER_SH, shoot, *sources])


@app.get("/api/status")
async def status():
    # detection does blocking network I/O — run it off the event loop
    data = await asyncio.to_thread(detect.detect_all)
    data["shoots"] = detect.list_shoots()
    return JSONResponse(data)


@app.get("/api/shoot-status")
async def shoot_status_api(shoot: str):
    if not SHOOT_RE.match(shoot or ""):
        raise HTTPException(400, "invalid shoot name")
    stored = shoot_status(shoot)
    out = {}
    for s in STATUS_SOURCES:
        st = stored.get(s)
        if st and st.get("state") in ("copying", "verified", "error"):
            out[s] = st
        elif await asyncio.to_thread(_disk_present, shoot, s):
            out[s] = {"state": "present", "detail": "on disk", "pct": 100}
        else:
            out[s] = {"state": "pending", "detail": "not gathered", "pct": 0}
    return {"shoot": shoot, "sources": out}


@app.get("/api/cards")
async def cards():
    # fast, local-only (no network) — safe to poll every few seconds so an inserted
    # card lights up the dashboard on its own
    d = await asyncio.to_thread(detect.detect_cards)
    return asdict(d)


@app.post("/api/gather")
async def gather(payload: dict):
    shoot = (payload or {}).get("shoot", "").strip()
    sources = (payload or {}).get("sources", [])
    if not SHOOT_RE.match(shoot):
        raise HTTPException(400, "invalid shoot name (use the YYYY-MM-CODE rubric)")
    sources = [s for s in sources if s in VALID_SOURCES]
    if not sources:
        raise HTTPException(400, "pick at least one valid source")
    job_id = await start_gather(shoot, sources)
    return {"job_id": job_id, "shoot": shoot, "sources": sources}


_DRIVE_ID = re.compile(r"[A-Za-z0-9_-]{25,}")

@app.post("/api/audio-link")
async def audio_link(payload: dict):
    """Pull one Google Drive file (by share link or ID) straight into <shoot>/AUDIO/.
    For when field audio is shared as a direct link instead of dropped in the folder."""
    shoot = (payload or {}).get("shoot", "").strip()
    link = (payload or {}).get("link", "").strip()
    if not SHOOT_RE.match(shoot):
        raise HTTPException(400, "invalid shoot name")
    m = _DRIVE_ID.search(link)
    if not m:
        raise HTTPException(400, "couldn't find a Drive file ID in that link")
    fid = m.group(0)
    dest = os.path.join(SHARE, shoot, "AUDIO") + "/"
    os.makedirs(dest, exist_ok=True)
    job_id = await _spawn_job(
        shoot, ["audio"],
        ["rclone", "backend", "copyid", f"{RCLONE_REMOTE}:", fid, dest,
         "-P", "--stats", "2s", "--stats-one-line"],
        trust_rc=True)
    return {"job_id": job_id, "file_id": fid}


@app.get("/api/active-shoot")
async def get_active_shoot():
    job = JOBS.get(AUTO["job"] or "", {})
    return {**STATE, "auto_job": AUTO["job"],
            "auto_job_done": job.get("done", True) if AUTO["job"] else True}


@app.post("/api/active-shoot")
async def set_active_shoot(payload: dict):
    shoot = (payload or {}).get("shoot", "").strip()
    if shoot and not SHOOT_RE.match(shoot):
        raise HTTPException(400, "invalid shoot name (use the YYYY-MM-CODE rubric)")
    STATE["active_shoot"] = shoot
    if "auto_ingest" in (payload or {}):
        STATE["auto_ingest"] = bool(payload["auto_ingest"])
    # changing the active shoot re-arms auto-ingest for the cards currently in
    AUTO["seen"] = set()
    _save_state()
    return STATE


async def card_watcher():
    """Zero-click ingest: when a card appears and an active shoot is set, auto-run the
    cards gather into it. do_cards_dir skips cards already fully present, so re-triggers
    are cheap and only new cards transfer."""
    while True:
        try:
            if STATE.get("active_shoot") and STATE.get("auto_ingest", True):
                d = await asyncio.to_thread(detect.detect_cards)
                labels = {it.get("label") for it in (d.items or []) if it.get("label")}
                running = bool(AUTO["job"]) and not JOBS.get(AUTO["job"], {}).get("done", True)
                fresh = labels - AUTO["seen"]
                if labels and fresh and not running:
                    AUTO["job"] = await start_gather(STATE["active_shoot"], ["cards"])
                    AUTO["shoot"] = STATE["active_shoot"]
                    AUTO["seen"] |= labels
        except Exception:  # noqa: BLE001
            pass
        await asyncio.sleep(8)


@app.on_event("startup")
async def _startup():
    asyncio.create_task(card_watcher())


@app.get("/api/jobs")
async def jobs():
    return [{"job_id": k, "shoot": v["shoot"], "sources": v["sources"],
             "done": v["done"], "rc": v["rc"]} for k, v in JOBS.items()]


@app.get("/api/jobs/{job_id}/events")
async def job_events(job_id: str):
    job = JOBS.get(job_id)
    if not job:
        raise HTTPException(404, "no such job")

    async def stream():
        sent = 0
        while True:
            lines = job["lines"]
            while sent < len(lines):
                yield f"data: {lines[sent]}\n\n"
                sent += 1
            if job["done"] and sent >= len(job["lines"]):
                yield f"event: done\ndata: rc={job['rc']}\n\n"
                return
            await asyncio.sleep(0.4)

    return StreamingResponse(stream(), media_type="text/event-stream")


@app.get("/", response_class=HTMLResponse)
async def index():
    return (APP_DIR / "static" / "index.html").read_text()


app.mount("/static", StaticFiles(directory=str(APP_DIR / "static")), name="static")
