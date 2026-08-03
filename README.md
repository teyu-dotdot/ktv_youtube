# KTV — YouTube karaoke for iPad

A full-screen YouTube player for karaoke nights. Point it at a collaborative
YouTube playlist, and everyone adds songs from the YouTube app on their own
phone while the iPad plays them in order.

The one thing it adds that YouTube can't do: a **Stereo / Left / Right** switch.
Karaoke uploads — Chinese and Japanese ones especially — often carry a guide
vocal on one channel and the bare instrumental on the other, so picking a
channel is the 原唱/伴唱 switch every KTV machine has.

---

## What it is

- **Full-screen video.** No sidebar, no library, no queue list. The playlist is
  the running order and YouTube advances through it.
- **A floating bar** with the channel switch, reload, and settings.
- **QR scanning** to load a playlist without typing a link on a TV-sized screen:
  share the playlist from a phone, show the code, point the iPad at it.
- **Settings** for the playlist and an API key.

## How the shared queue works

Make a playlist in the YouTube app, set it to Unlisted, then **Edit ▸
Collaborate**. Share the link. Everyone adds songs from their own phone; the
iPad plays the list. No accounts in this app, no server, no sync protocol, and
nothing for guests to install — YouTube already built all of it.

> A private playlist can't be opened by anyone else, including this app.
> Unlisted is the setting you want.

## What was removed, and what's still in the repo

The local library, the playback queue, the ranked karaoke search and the
on-device vocal separator were all cut from the app. They existed to reproduce
a running order on the iPad, and a YouTube playlist already is one.

`KaraokeKit` still contains the separator and its tests — around 28 dB of vocal
suppression via centre-channel extraction, documented in
[How the separator works](#how-the-separator-works). Nothing in the app calls it
any more. It's kept because it works and is tested, not because it's wired up.

## Requirements

- iPadOS / iOS 17 or later (iPhone works too; the layout adapts)
- A YouTube Data API key, for search — free, and the only thing the karaoke
  path needs
- Optionally, Python 3.10+ on a machine you control, for the vocal-removal
  fallback

## Build and run

### On a Mac

```bash
brew install xcodegen        # once
make app                     # generates App/KTVYouTube.xcodeproj and opens it
make test                    # runs the KaraokeKit test suite
```

Set a development team in *Signing & Capabilities*, then run on your iPad.

### On the iPad itself

Open `KTV.swiftpm` in Swift Playgrounds and press ▶. No Mac, no Xcode.

The app and library sources live *inside* `KTV.swiftpm/`, because Swift
Playgrounds can only see the folder you open and SwiftPM won't accept target
paths that escape the package root. The root `Package.swift` and the Xcode
project point into it, so there's still one copy of everything.

The helper service can't run on an iPad — it's Python shelling out to yt-dlp —
but with an API key the karaoke path needs nothing else, so an iPad-only setup
works end to end. Full details, including what Swift Playgrounds can't
configure, are in [docs/BUILDING-ON-IPAD.md](docs/BUILDING-ON-IPAD.md).

## Getting songs in

The main flow is **＋ ▸ find a karaoke version**: type a title, pick from the
ranked results, sing. Falling back to **Add original, remove vocals** is for
when search comes up empty, and **Choose a file** imports anything your iPad can
play.

### Searching

Two ways, and you only need one:

**A YouTube API key** (recommended). Enable *YouTube Data API v3* at
`console.cloud.google.com`, make an API key, paste it into **Settings ▸ YouTube
API key**. The app searches and ranks on its own — no other machine involved.
The free allowance works out to about 50 searches a day.

**The helper service**, if you're already running one for the fallback path. It
does the same job server-side.

### The helper service — only for vocal removal

iOS has no supported API for extracting YouTube media, and this app deliberately
ships no scraper. For songs with no karaoke version, it asks a small service
*you* run for a downloadable audio URL. A reference implementation using
[yt-dlp](https://github.com/yt-dlp/yt-dlp) is in [`server/`](server/):

```bash
cd server
pip install -r requirements.txt
ACCESS_TOKEN=$(openssl rand -hex 16) python resolver.py
```

Then in the app: **Settings ▸ Helper service**, enter
`http://your-machine.local:8808` and the same token.

Two endpoints, so you can point the app at anything that speaks them:

```
GET /search?q=<song name>&limit=<n>
    -> {"results": [{"video_id": "...", "title": "...", "channel": "...",
                     "duration": 215, "thumbnail": "...",
                     "score": 6, "confidence": "high"}, ...]}

GET /resolve?url=<youtube url>
    -> {"audio_url": "...", "title": "...", "artist": "...",
        "duration": 213.4, "ext": "m4a"}
```

`audio_url` may be absolute or a path relative to the service — set
`PROXY_AUDIO=1` to have the service stream the audio itself rather than handing
out a CDN URL that can expire mid-download.

Ranking lives in two places that must agree, because either backend can do it:
[`server/karaoke_scoring.py`](server/karaoke_scoring.py) and
[`KaraokeRanker.swift`](Sources/KaraokeKit/Ingest/KaraokeRanker.swift). A test
pins the Swift scores to the Python ones, so a keyword added to one and not the
other fails the build rather than quietly changing results on one path only.

> **On rights.** Karaoke videos found through search are *streamed from YouTube
> in its own embedded player* — nothing is downloaded, which is the sanctioned
> way to play YouTube in an app and part of why that path is the default.
>
> The fallback path is different: downloading generally requires permission from
> the rights holder, and YouTube's Terms of Service prohibit it without one.
> That's why extraction sits in a service you operate rather than in the app —
> the decision about a given video is yours. Karaoke performance itself may also
> need a licence depending on where and how you do it.

## How the separator works

Not reachable from the app any more — see above. Kept for reference.

### The idea

Lead vocals are mixed to the centre in essentially every commercial recording:
the same signal, at the same level and phase, in both speakers. Everything else
is spread around it. So *"how centred is this?"* is a usable stand-in for *"how
vocal is this?"*.

The separator takes a Short-Time Fourier Transform of both channels (4096-sample
Hann window, 75% overlap) and builds a soft mask per frequency bin from two
independent pieces of evidence:

| Term | Formula | 1 means | 0 means |
|---|---|---|---|
| Phase coherence | `2·\|L·conj(R)\| / (\|L\|² + \|R\|²)` | same waveform in both channels | uncorrelated |
| Level balance | `1 - \|\|L\|-\|R\|\| / (\|L\|+\|R\|)` | dead centre | hard-panned |

The two are raised to tunable exponents and multiplied. A band weighting then
rolls the mask off below 140 Hz and above 12 kHz, so the kick and bass — which
are also centred and also coherent — survive, and cymbals keep their air.

### Why the fader is free

Only the *vocal* estimate is resynthesised. The instrumental is computed in the
time domain as `original − vocal`, which makes the two stems sum back to the
input exactly, not approximately. That buys three things:

1. At vocal level 100% you hear the original recording sample-for-sample, not a
   mix that has been through a lossy analysis/synthesis round trip.
2. The fader is a mixer gain on one of two synchronised player nodes, so moving
   it costs nothing and can't click.
3. Only one stem has to be cached on disk — the other is a subtraction away.

### Measured performance

From the test suite, on a synthetic mix with a centred vocal, hard-panned guitar
and keys, and a centred bass line:

| Preset | Vocal suppression | Backing track retained |
|---|---|---|
| Gentle | −20 dB | −1.0 dB |
| Balanced | −28 dB | −1.3 dB |
| Aggressive | −33 dB | −2.7 dB |

Centred bass at 55 Hz survives at −1.5 dB, versus −28 dB for a centred vocal —
that gap is the band weighting doing its job.

Separation takes a few seconds for a four-minute track and is cached, keyed by
track *and* preset, so switching presets re-runs it but switching back doesn't.

## Limits

Worth knowing before you judge the results:

- **It needs real stereo.** A mono file, or a fake-stereo file with two
  identical channels, carries no panning information at all. The app detects
  this, falls back to gently ducking the vocal band, and says so in the player —
  but the result is much weaker.
- **Anything else centred goes too.** Snare, kick, bass and centred synths lose
  a little. That's the −1.3 dB in the table above, and it's inherent to the
  method rather than a bug.
- **Doubled, wide, or heavily reverberant vocals survive better**, because the
  reverb tail isn't centred even when the dry vocal is.
- **It is not a neural separator.** Demucs or Spleeter will beat this on a dense
  mix. What this gives you instead is instant, on-device, no-model, no-upload,
  and a fader that moves in real time. The `VocalSeparator` API is small enough
  that swapping in a Core ML model later is a contained change.

## Project layout

```
KTV.swiftpm/            opens directly in Swift Playgrounds on an iPad
  Package.swift         app playground manifest
  App/                  SwiftUI app — library sidebar, search sheet, embedded
                        karaoke player, vocal-removal player, queue, settings
  KaraokeKit/
    DSP/                FFT, Hann window, biquads, separator and its settings
    Audio/              AVAudioEngine two-stem player, session, decoding
    Ingest/             search clients and ranking, link parsing, downloads,
                        library, stem cache, playback queue
Package.swift           builds and tests KaraokeKit on macOS and Linux
App/project.yml         XcodeGen spec for the Xcode build
Tests/                  XCTest suite for the DSP, clients and platform-free layers
server/
  resolver.py           search and resolve endpoints
  karaoke_scoring.py    language-aware ranking of search results
docs/                   building on iPad
```

All three build systems read the same source files; nothing is duplicated.

`KaraokeKit` is a plain Swift package with no third-party dependencies. The DSP
falls back to a portable Swift FFT where Accelerate isn't available, so the
tests run on Linux as well as on a Mac.

## License

No license is granted for this code yet — add one before distributing.
