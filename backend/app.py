"""Personal slow-and-reverb app API.

YouTube metadata comes from the YouTube Data API; selected audio conversion is
handled by yt-dlp and FFmpeg on the backend host.
"""

from __future__ import annotations

import asyncio
import html
import os
import re
import secrets
import shutil
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Literal

import httpx
from fastapi import BackgroundTasks, Depends, FastAPI, HTTPException, Query
from fastapi.responses import FileResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, Field
from dotenv import load_dotenv
from yt_dlp import YoutubeDL

load_dotenv()

app = FastAPI(title="SlowReverb API", version="1.0.0")
bearer_scheme = HTTPBearer(auto_error=False)
DATA_DIR = Path(os.getenv("SLOWREVERB_TMP_DIR", "/tmp/slowreverb-conversions"))
DATA_DIR.mkdir(parents=True, exist_ok=True)
YOUTUBE_SEARCH_URL = "https://www.googleapis.com/youtube/v3/search"
YOUTUBE_VIDEOS_URL = "https://www.googleapis.com/youtube/v3/videos"
jobs: dict[str, dict] = {}
job_lock = asyncio.Lock()
expiry_tasks: set[asyncio.Task] = set()


class SearchResult(BaseModel):
    video_id: str
    title: str
    channel_title: str
    thumbnail_url: str | None = None
    view_count: int = 0


class ConversionRequest(BaseModel):
    video_id: str = Field(min_length=1, max_length=64)


class ConversionResponse(BaseModel):
    id: str
    status: Literal["queued", "running", "completed", "failed"]
    error: str | None = None
    download_url: str | None = None


def _required_env(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value:
        raise HTTPException(status_code=503, detail=f"Server is missing {name} configuration")
    return value


async def require_api_token(credentials: HTTPAuthorizationCredentials | None = Depends(bearer_scheme)) -> None:
    expected = _required_env("SLOWREVERB_API_TOKEN")
    if credentials is None or credentials.scheme.lower() != "bearer" or not secrets.compare_digest(credentials.credentials, expected):
        raise HTTPException(status_code=401, detail="Invalid or missing API token")


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/search", response_model=list[SearchResult])
async def search(q: str = Query(min_length=1, max_length=120), _: None = Depends(require_api_token)) -> list[SearchResult]:
    api_key = _required_env("YOUTUBE_API_KEY")
    async with httpx.AsyncClient(timeout=15) as client:
        response = await client.get(
            YOUTUBE_SEARCH_URL,
            params={"part": "snippet", "type": "video", "maxResults": 20, "q": q, "key": api_key},
        )
        if response.is_error:
            raise HTTPException(status_code=502, detail="YouTube search request failed")
        payload = response.json()

        entries = [item for item in payload.get("items", []) if item.get("id", {}).get("videoId")]
        ids = [item["id"]["videoId"] for item in entries]
        views: dict[str, int] = {}
        if ids:
            stats = await client.get(
                YOUTUBE_VIDEOS_URL,
                params={"part": "statistics", "id": ",".join(ids), "key": api_key},
            )
            if stats.is_success:
                views = {
                    item["id"]: int(item.get("statistics", {}).get("viewCount", 0))
                    for item in stats.json().get("items", [])
                }

    return [
        SearchResult(
            video_id=item["id"]["videoId"],
            title=html.unescape(item.get("snippet", {}).get("title", "Untitled")),
            channel_title=html.unescape(item.get("snippet", {}).get("channelTitle", "Unknown channel")),
            thumbnail_url=(item.get("snippet", {}).get("thumbnails", {}).get("medium", {}).get("url")),
            view_count=views.get(item["id"]["videoId"], 0),
        )
        for item in entries
    ]


async def _run_conversion(job_id: str, video_id: str) -> None:
    async with job_lock:
        jobs[job_id]["status"] = "running"
    try:
        path = DATA_DIR / f"{job_id}.mp3"
        await asyncio.to_thread(_convert_with_yt_dlp, video_id, path)
        if not path.is_file() or path.stat().st_size == 0:
            raise RuntimeError("yt-dlp completed without producing an MP3 file")
        async with job_lock:
            jobs[job_id].update(status="completed", file=str(path))
        expiry = asyncio.create_task(_expire_conversion(job_id, path))
        expiry_tasks.add(expiry)
        expiry.add_done_callback(expiry_tasks.discard)
    except Exception as exc:
        (DATA_DIR / f"{job_id}.mp3").unlink(missing_ok=True)
        async with job_lock:
            jobs[job_id].update(status="failed", error=str(exc)[:240])


async def _expire_conversion(job_id: str, path: Path) -> None:
    """Keep a finished file available briefly, then remove it from the server."""
    await asyncio.sleep(30 * 60)
    path.unlink(missing_ok=True)
    jobs.pop(job_id, None)


def _convert_with_yt_dlp(video_id: str, output_path: Path) -> None:
    """Download the best available audio and extract it to MP3 with FFmpeg."""
    if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
        raise RuntimeError("FFmpeg is required for MP3 conversion. Install it with 'brew install ffmpeg' and restart the backend.")
    output_template = str(output_path.with_suffix(""))
    options = {
        "format": "bestaudio/best",
        "outtmpl": output_template + ".%(ext)s",
        "noplaylist": True,
        "quiet": True,
        "no_warnings": True,
        "overwrites": True,
        "postprocessors": [{
            "key": "FFmpegExtractAudio",
            "preferredcodec": "mp3",
            "preferredquality": "192",
        }],
    }
    video_url = f"https://www.youtube.com/watch?v={video_id}"
    with YoutubeDL(options) as downloader:
        downloader.download([video_url])


@app.post("/conversions", response_model=ConversionResponse, status_code=202)
async def create_conversion(payload: ConversionRequest, background_tasks: BackgroundTasks, _: None = Depends(require_api_token)) -> ConversionResponse:
    if not re.fullmatch(r"[A-Za-z0-9_-]+", payload.video_id):
        raise HTTPException(status_code=422, detail="Invalid video ID")
    job_id = uuid.uuid4().hex
    jobs[job_id] = {"status": "queued", "video_id": payload.video_id, "created_at": datetime.now(timezone.utc)}
    background_tasks.add_task(_run_conversion, job_id, payload.video_id)
    return ConversionResponse(id=job_id, status="queued")


@app.get("/conversions/{job_id}", response_model=ConversionResponse)
async def get_conversion(job_id: str, _: None = Depends(require_api_token)) -> ConversionResponse:
    job = jobs.get(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Conversion not found")
    return ConversionResponse(
        id=job_id,
        status=job["status"],
        error=job.get("error"),
        download_url=f"/conversions/{job_id}/download" if job["status"] == "completed" else None,
    )


@app.get("/conversions/{job_id}/download")
async def download_conversion(job_id: str, _: None = Depends(require_api_token)) -> FileResponse:
    job = jobs.get(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Conversion not found")
    path = Path(job.get("file", ""))
    if job["status"] != "completed" or not path.is_file():
        raise HTTPException(status_code=409, detail="Conversion is not ready")
    return FileResponse(path, media_type="audio/mpeg", filename=f"{job_id}.mp3")
