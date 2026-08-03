# KTV — YouTube karaoke for iPad

An iPadOS app that takes a song, strips the lead vocal out of it, and gives you
a fader to put it back. Point it at a YouTube link or import an audio file, and
you get a backing track you can sing over — in your own key, at your own tempo.

Vocal removal runs entirely on the device. Your audio is never uploaded
anywhere.

---

## What it does

- **Add songs** from a YouTube link or from Files / AirDrop / any app's share sheet.
- **Removes the lead vocal** with a real-time-tunable centre-channel separator
  (about 28 dB of suppression on a typical pop mix — see [How it works](#how-it-works)).
- **Vocal fader**, 0–100%. Full karaoke at one end, a guide vocal in the middle,
  the untouched original at the other. Moving it is instant — there's no
  re-render.
- **Key change**, ±12 semitones, without changing the tempo.
- **Tempo change**, 0.75–1.25×, without changing the key.
- **Three removal presets** trading vocal suppression against how much of the
  band survives.
- Background audio, lock-screen playback, AirPlay, and interruption handling.

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

## Getting audio in

There are two ways to add a song, and they have very different requirements.

### Importing a file — works out of the box

**Add ▸ Choose a file** takes anything your iPad can play. Nothing else to set
up. Stereo recordings work; mono ones mostly don't (see [Limits](#limits)).

### YouTube links — needs a resolver you run

iOS has no supported API for extracting media from YouTube, and this app
deliberately ships no scraper. Instead it asks a small service *you* run for a
downloadable audio URL. A reference implementation using
[yt-dlp](https://github.com/yt-dlp/yt-dlp) is in [`server/`](server/):

```bash
cd server
pip install -r requirements.txt
ACCESS_TOKEN=$(openssl rand -hex 16) python resolver.py
```

Then in the app: **Settings ▸ Resolver service**, enter
`http://your-machine.local:8808` and the same token.

The contract is one endpoint, so you can point the app at anything that speaks it:

```
GET /resolve?url=<youtube url>
    -> {"audio_url": "...", "title": "...", "artist": "...",
        "duration": 213.4, "ext": "m4a"}
```

`audio_url` may be absolute or a path relative to the service — set
`PROXY_AUDIO=1` to have the service stream the audio itself rather than handing
out a CDN URL that can expire mid-download.

> **On rights.** Downloading from YouTube generally requires permission from the
> rights holder, and YouTube's Terms of Service prohibit it without one. That
> split — the app plays audio, a service you operate fetches it — is why the
> decision about a given video is yours to make and not something this app makes
> for you. Karaoke performance itself may also need a licence depending on where
> and how you do it.

## How it works

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
  Ingest/       link parsing, resolver client, downloads, library, stem cache
App/
  project.yml   XcodeGen spec
  KTVYouTube/   SwiftUI app — library sidebar, player, add and settings sheets
server/
  resolver.py   reference yt-dlp resolver service
Tests/          XCTest suite for the DSP and the platform-free layers
```

`KaraokeKit` is a plain Swift package with no third-party dependencies. The DSP
falls back to a portable Swift FFT where Accelerate isn't available, so the
tests run on Linux as well as on a Mac.

## License

No license is granted for this code yet — add one before distributing.
