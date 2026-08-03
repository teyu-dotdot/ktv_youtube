"""Reference resolver service for the KTV iPad app.

Two jobs, both delegated here rather than done in the app.

`/search` is the one that matters day to day: it finds karaoke versions of a
song that already exist on YouTube. Those play back untouched in the app's
embedded player — no download, no vocal removal, and the on-screen lyrics come
free.

`/resolve` is the fallback, for songs with no karaoke version. It hands back a
downloadable audio URL so the app can strip the vocals itself. The app contains
no YouTube extraction code of its own; this is a minimal implementation of that
contract, built on yt-dlp.

    GET /search?q=<song name>&limit=<n>
      -> {"results": [{"video_id": "...", "title": "...", "channel": "...",
                       "duration": 215, "thumbnail": "...",
                       "score": 6, "confidence": "high"}, ...]}

    GET /resolve?url=<youtube url>
      -> {"audio_url": "...", "title": "...", "artist": "...",
          "duration": 213.4, "ext": "m4a"}

    GET /audio/<video id>          (only when PROXY_AUDIO=1)
      -> the audio stream itself

    GET /healthz -> {"status": "ok"}

Run it on a machine on your own network:

    pip install -r requirements.txt
    python resolver.py

then point the app's Settings at http://<that machine>:8808

Only use this with content you have the rights to download. YouTube's Terms of
Service prohibit downloading without permission from the rights holder, and
this service does nothing to check that on your behalf — that judgement is
yours to make.
"""

from __future__ import annotations

import logging
import os
import re
import subprocess
import sys
from http import HTTPStatus
from typing import Any
from urllib.parse import parse_qs, urlparse

from flask import Flask, Response, jsonify, request, stream_with_context

from karaoke_scoring import score_result, search_queries

try:
    import yt_dlp
except ImportError:  # pragma: no cover - dependency check only
    sys.exit("yt-dlp is not installed. Run: pip install -r requirements.txt")

app = Flask(__name__)
log = logging.getLogger("resolver")

# Optional shared secret. When set, requests must carry
# `Authorization: Bearer <token>`; configure the same value in the app.
ACCESS_TOKEN = os.environ.get("ACCESS_TOKEN", "").strip()

# When enabled, the app is handed a URL back to this service instead of a
# signed CDN URL. Slower and it puts the traffic through your machine, but the
# URL never expires mid-download and it works when the CDN rejects the iPad's
# request.
PROXY_AUDIO = os.environ.get("PROXY_AUDIO", "0") == "1"

VIDEO_ID = re.compile(r"^[A-Za-z0-9_-]{11}$")

# Results pulled per query phrasing before merging and ranking. Four phrasings
# at ten each is plenty to surface a karaoke version if one exists, without
# making the user wait on four slow searches.
PER_QUERY_RESULTS = 10


def extract_video_id(raw: str) -> str | None:
    """Mirror of YouTubeLink.parse on the client, so both agree on what's valid."""
    raw = (raw or "").strip()
    if VIDEO_ID.match(raw):
        return raw

    parsed = urlparse(raw if "://" in raw else f"https://{raw}")
    host = (parsed.hostname or "").lower()
    host = host[4:] if host.startswith("www.") else host

    if host == "youtu.be":
        candidate = parsed.path.lstrip("/").split("/")[0]
        return candidate if VIDEO_ID.match(candidate) else None

    if host not in {
        "youtube.com",
        "m.youtube.com",
        "music.youtube.com",
        "youtube-nocookie.com",
    }:
        return None

    values = parse_qs(parsed.query).get("v")
    if values and VIDEO_ID.match(values[0]):
        return values[0]

    segments = [segment for segment in parsed.path.split("/") if segment]
    if len(segments) >= 2 and segments[0] in {"embed", "shorts", "live", "v"}:
        return segments[1] if VIDEO_ID.match(segments[1]) else None

    return None


def require_token() -> Response | None:
    if not ACCESS_TOKEN:
        return None
    header = request.headers.get("Authorization", "")
    if header == f"Bearer {ACCESS_TOKEN}":
        return None
    return error("Unauthorized.", HTTPStatus.UNAUTHORIZED)


def error(message: str, status: HTTPStatus) -> Response:
    response = jsonify({"error": message})
    response.status_code = int(status)
    return response


def probe(video_id: str) -> dict[str, Any]:
    """Ask yt-dlp for the best audio-only stream it can find."""
    options = {
        # Prefer m4a: AVAudioFile reads it natively, and opus-in-webm does not
        # always decode on iOS.
        "format": "bestaudio[ext=m4a]/bestaudio/best",
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
        "skip_download": True,
    }
    if cookies := os.environ.get("COOKIES_FILE"):
        options["cookiefile"] = cookies

    with yt_dlp.YoutubeDL(options) as downloader:
        return downloader.extract_info(
            f"https://www.youtube.com/watch?v={video_id}", download=False
        )


@app.get("/healthz")
def healthz() -> Response:
    return jsonify({"status": "ok", "proxy_audio": PROXY_AUDIO})


@app.get("/search")
def search() -> Response:
    """Find karaoke versions of a song.

    GET /search?q=<song name>&limit=<n>
      -> {"results": [{"video_id", "title", "channel", "duration",
                       "thumbnail", "score", "confidence"}, ...]}

    Several query phrasings are tried because karaoke uploads are tagged
    differently by language, and the merged results are ranked by how confidently
    they look like an instrumental rather than the original recording.
    """
    if denied := require_token():
        return denied

    query = (request.args.get("q") or "").strip()
    if not query:
        return error("Say what you're looking for.", HTTPStatus.BAD_REQUEST)
    if len(query) > 200:
        return error("That search is too long.", HTTPStatus.BAD_REQUEST)

    try:
        limit = max(1, min(25, int(request.args.get("limit", "12"))))
    except ValueError:
        limit = 12

    options = {
        "quiet": True,
        "no_warnings": True,
        "extract_flat": True,   # metadata only; don't touch the media
        "skip_download": True,
    }
    if cookies := os.environ.get("COOKIES_FILE"):
        options["cookiefile"] = cookies

    # Keyed by video id so the same upload found by two phrasings is kept once,
    # at its best score.
    found: dict[str, dict[str, Any]] = {}

    try:
        with yt_dlp.YoutubeDL(options) as downloader:
            for phrasing in search_queries(query):
                try:
                    page = downloader.extract_info(
                        f"ytsearch{PER_QUERY_RESULTS}:{phrasing}", download=False
                    )
                except yt_dlp.utils.DownloadError as exc:
                    # One phrasing failing shouldn't sink the whole search.
                    log.warning("search phrasing failed (%s): %s", phrasing, exc)
                    continue

                for entry in (page or {}).get("entries") or []:
                    video_id = entry.get("id")
                    if not video_id or not VIDEO_ID.match(video_id):
                        continue

                    title = entry.get("title") or ""
                    channel = entry.get("channel") or entry.get("uploader") or ""
                    duration = entry.get("duration")
                    scored = score_result(title, channel, duration)

                    existing = found.get(video_id)
                    if existing and existing["score"] >= scored.score:
                        continue

                    found[video_id] = {
                        "video_id": video_id,
                        "title": title,
                        "channel": channel,
                        "duration": duration,
                        "thumbnail": f"https://i.ytimg.com/vi/{video_id}/hqdefault.jpg",
                        "score": scored.score,
                        "confidence": scored.confidence,
                    }
    except Exception:  # pragma: no cover - unexpected upstream failure
        log.exception("search failed for %r", query)
        return error("The search failed. Try again in a moment.", HTTPStatus.BAD_GATEWAY)

    results = sorted(found.values(), key=lambda item: item["score"], reverse=True)

    # Anything scoring below zero is actively signalling "original vocal" or
    # "live" — never worth showing in a karaoke app.
    results = [item for item in results if item["score"] > 0][:limit]

    return jsonify({"results": results, "query": query})


@app.get("/resolve")
def resolve() -> Response:
    if denied := require_token():
        return denied

    video_id = extract_video_id(request.args.get("url", ""))
    if not video_id:
        return error("That doesn't look like a YouTube link.", HTTPStatus.BAD_REQUEST)

    try:
        info = probe(video_id)
    except yt_dlp.utils.DownloadError as exc:
        log.warning("resolve failed for %s: %s", video_id, exc)
        return error(
            "That video couldn't be read. It may be private, age-restricted, "
            "or unavailable in this region.",
            HTTPStatus.BAD_GATEWAY,
        )
    except Exception:  # pragma: no cover - unexpected upstream failure
        log.exception("unexpected failure resolving %s", video_id)
        return error("The resolver hit an unexpected error.", HTTPStatus.INTERNAL_SERVER_ERROR)

    extension = info.get("ext") or "m4a"
    audio_url = (
        f"/audio/{video_id}" if PROXY_AUDIO else info.get("url")
    )
    if not audio_url:
        return error("No audio stream was available for that video.", HTTPStatus.BAD_GATEWAY)

    return jsonify(
        {
            "audio_url": audio_url,
            "title": info.get("title"),
            "artist": info.get("artist") or info.get("uploader"),
            "duration": info.get("duration"),
            "ext": extension,
        }
    )


@app.get("/audio/<video_id>")
def audio(video_id: str) -> Response:
    if not PROXY_AUDIO:
        return error("Audio proxying is disabled.", HTTPStatus.NOT_FOUND)
    if denied := require_token():
        return denied
    if not VIDEO_ID.match(video_id):
        return error("Invalid video id.", HTTPStatus.BAD_REQUEST)

    # Streamed through ffmpeg via yt-dlp's stdout so nothing is buffered on disk.
    command = [
        sys.executable, "-m", "yt_dlp",
        "--quiet", "--no-warnings", "--no-playlist",
        "-f", "bestaudio[ext=m4a]/bestaudio/best",
        "-o", "-",
        f"https://www.youtube.com/watch?v={video_id}",
    ]
    if cookies := os.environ.get("COOKIES_FILE"):
        command[1:1] = ["--cookies", cookies]

    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)

    def generate():
        try:
            while chunk := process.stdout.read(65536):
                yield chunk
        finally:
            process.stdout.close()
            process.terminate()
            process.wait(timeout=5)

    return Response(
        stream_with_context(generate()),
        mimetype="audio/mp4",
        headers={"Content-Disposition": f'inline; filename="{video_id}.m4a"'},
    )


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    host = os.environ.get("HOST", "0.0.0.0")
    port = int(os.environ.get("PORT", "8808"))
    if not ACCESS_TOKEN:
        log.warning(
            "ACCESS_TOKEN is not set: anyone who can reach %s:%s can use this "
            "service. Set it, and the matching token in the app, if this host "
            "is reachable beyond your own network.",
            host, port,
        )
    app.run(host=host, port=port, threaded=True)
