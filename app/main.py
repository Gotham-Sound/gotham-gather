"""Gather app — MVP web GUI over the gather-shoot workflow.

Wraps bin/gather.sh: detects devices, starts per-source gather jobs, and streams
their live output to the browser. Phase 2 replaces the shell-out with native
device modules + a job queue + SQLite history.
"""
from __future__ import annotations
import asyncio, os, re, uuid, time, shlex
from pathlib import Path
from dataclasses import asdict
from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse, StreamingResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from . import detect

APP_DIR = Path(__file__).parent
GATHER_SH = os.environ.get("GATHER_SH", str(APP_DIR.parent / "bin" / "gather.sh"))
SHARE = detect.SHARE
VALID_SOURCES = {"cards", "pix", "atem", "zcam", "audio", "sweep", "pixeft", "pixrec"}
SHOOT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")

app = FastAPI(title="Gotham Gather")

# in-memory job registry (MVP). {job_id: {proc, lines[], done, shoot, sources}}
JOBS: dict[str, dict] = {}


@app.get("/api/status")
async def status():
    # detection does blocking network I/O — run it off the event loop
    data = await asyncio.to_thread(detect.detect_all)
    data["shoots"] = detect.list_shoots()
    return JSONResponse(data)


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

    job_id = uuid.uuid4().hex[:8]
    cmd = ["bash", GATHER_SH, shoot, *sources]
    proc = await asyncio.create_subprocess_exec(
        *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
    job = {"proc": proc, "lines": [], "done": False, "rc": None,
           "shoot": shoot, "sources": sources, "started": time.time()}
    JOBS[job_id] = job

    async def pump():
        assert proc.stdout
        async for raw in proc.stdout:
            line = raw.decode(errors="replace").rstrip("\n")
            # strip ANSI color and collapse rsync's carriage-return progress spam
            line = re.sub(r"\x1b\[[0-9;]*m", "", line)
            if "\r" in line:
                line = line.split("\r")[-1]
            job["lines"].append(line)
            del job["lines"][:-500]  # keep last 500 lines
        job["rc"] = await proc.wait()
        job["done"] = True

    asyncio.create_task(pump())
    return {"job_id": job_id, "shoot": shoot, "sources": sources}


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
