# SlowReverb

A personal iOS slow-and-reverb player with a small FastAPI service for YouTube metadata search and yt-dlp/FFmpeg conversion.

## iOS app

Open `SlowReverb.xcodeproj` in Xcode, choose an iPhone simulator or device, set your signing team if needed, and run. In the app's Search tab, the API server defaults to `http://127.0.0.1:8000` for the simulator when the backend is running on the same Mac. For a physical phone, enter your Mac's LAN address (and allow local network access) or use your deployed HTTPS backend.

The app imports audio through the iOS Files picker, keeps a local copy in its app documents folder, and applies playback speed and reverb live. It does not export altered audio.

## Backend

Requires Python 3.10+ and [uv](https://docs.astral.sh/uv/).

```sh
cd backend
uv python install 3.12
uv sync --python 3.12
cp .env.example .env
# Put your YouTube Data API key and SLOWREVERB_API_TOKEN in backend/.env
# Install FFmpeg separately: brew install ffmpeg
uv run --python 3.12 uvicorn app:app --reload
```

The backend uses yt-dlp to retrieve the selected video's best available audio and FFmpeg to convert it to a 192 kbps MP3. The temporary MP3 is kept under `/tmp/slowreverb-conversions` for up to 30 minutes so the phone can download it, then automatically deleted. Set `SLOWREVERB_TMP_DIR` only if you want a different temporary path. The song library itself is stored on the iPhone.

For Railway, connect the Git repository, set the service root directory to `/backend`, and Railway will detect `backend/Dockerfile`. Add `YOUTUBE_API_KEY` in the service's Variables tab, generate a public domain, then enter its `https://…up.railway.app` URL in the iOS app. The Docker image installs FFmpeg and listens on Railway's assigned `PORT`.

Set `SLOWREVERB_API_TOKEN` to a long random secret in `backend/.env` locally and in Railway's service variables. Enter the same token in the app's **Search → API server** section; it is stored in iOS Keychain and sent as a Bearer token.

Endpoints:

- `GET /search?q=...` — YouTube search metadata, including view counts.
- `POST /conversions` with `{"video_id":"..."}` — enqueue conversion.
- `GET /conversions/{id}` — job status and, when ready, `download_url`.
- `GET /conversions/{id}/download` — fetch the MP3.

YouTube search requires a YouTube Data API key. Use the search and conversion flow only within the permissions and rights applicable to your account and content.
