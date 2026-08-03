# KTV — YouTube karaoke for iPad

An iPadOS karaoke app. Type a song title, and it finds the karaoke version
that already exists on YouTube — real instrumental, lyrics on screen — and plays
it. For the songs that don't have one, it falls back to removing the vocals
itself, on-device.

---

## What it does

**Search finds the karaoke version.** Most songs already have one uploaded: the
official backing track with timed lyrics burned into the video. Searching for it
beats anything signal processing can do, because it *is* the instrumental rather
than an estimate of one. Those play back untouched in an embedded player —
nothing downloaded, nothing analysed, no waiting.

Search is language-aware, because karaoke tagging isn't: a Korean upload says
`MR`, a Chinese one says `伴奏`, a Japanese one says `カラオケ`, and none of them
say "karaoke". Results are ranked on how confidently they look like an
instrumental, and anything signalling `原唱`, `cover` or `live` is dropped.

**Vocal removal is the fallback**, for the long tail with no karaoke version.
The app downloads the original and strips the lead vocal with a centre-channel
separator — about 28 dB of suppression on a typical pop mix. That path also
gives you:

- **Vocal fader**, 0–100%. Full karaoke at one end, a guide vocal in the middle,
  the untouched original at the other. Moving it is instant — there's no
  re-render.
- **Key change**, ±12 semitones, without changing the tempo.
- **Tempo change**, 0.75–1.25×, without changing the key.
- **Three removal presets**, trading vocal suppression against how much of the
  band survives.

Plus import from Files / AirDrop / any app's share sheet, background audio,
lock-screen playback, AirPlay, and interruption handling.

> **Karaoke videos can't be transposed.** They play in YouTube's embedded
> player, and there's no way to reach that audio, so key and tempo controls only
> apply to the vocal-removal path. Original key only on the good path — that's
> the trade.

## Requirements

- iPadOS / iOS 17 or later (iPhone works too; the layout adapts)
- Xcode 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the project file
- Python 3.10+ on some machine you control, if you want YouTube links to work

## Build and run

```bash
brew install xcodegen        # once
make app                     # generates App/KTVYouTube.xcodeproj and opens it
```

Then set a development team in *Signing & Capabilities* and run on your iPad.

Run the library's tests — the DSP, the link parser, the settings — with:

```bash
make test                    # swift test
```

## Getting songs in

The main flow is **＋ ▸ find a karaoke version**: type a title, pick from the
ranked results, sing. Falling back to **Add original, remove vocals** is for
when search comes up empty, and **Choose a file** imports anything your iPad can
play.

Search and downloading both need the helper service. Importing a file doesn't.

### The helper service

iOS has no supported API for searching or extracting YouTube media, and this app
deliberately ships no scraper. It asks a small service *you* run. A reference
implementation using [yt-dlp](https://github.com/yt-dlp/yt-dlp) is in
[`server/`](server/):

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

Ranking lives in [`server/karaoke_scoring.py`](server/karaoke_scoring.py), which
is where to add keywords for a language it handles badly.

> **On rights.** Karaoke videos found through search are *streamed from YouTube
> in its own embedded player* — nothing is downloaded, which is the sanctioned
> way to play YouTube in an app and part of why that path is the default.
>
> The fallback path is different: downloading generally requires permission from
> the rights holder, and YouTube's Terms of Service prohibit it without one.
> That's why extraction sits in a service you operate rather than in the app —
> the decision about a given video is yours. Karaoke performance itself may also
> need a licence depending on where and how you do it.

## How it works

This is the fallback path. When a karaoke version exists, none of it runs.

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
Sources/KaraokeKit/
  DSP/          FFT, Hann window, biquads, the separator and its settings
  Audio/        AVAudioEngine two-stem player, session handling, decoding
  Ingest/       search + resolver clients, link parsing, downloads, library,
                stem cache
App/
  project.yml   XcodeGen spec
  KTVYouTube/   SwiftUI app — library sidebar, search sheet, embedded karaoke
                player, vocal-removal player, settings
server/
  resolver.py          search and resolve endpoints
  karaoke_scoring.py   language-aware ranking of search results
Tests/          XCTest suite for the DSP, the clients and the platform-free layers
```

`KaraokeKit` is a plain Swift package with no third-party dependencies. The DSP
falls back to a portable Swift FFT where Accelerate isn't available, so the
tests run on Linux as well as on a Mac.

## License

No license is granted for this code yet — add one before distributing.
