# Building this on an iPad

The short version: **yes for the app, no for the helper service** — and with a
YouTube API key you don't need the helper service for karaoke anyway, so an
iPad-only setup does work end to end.

## What you need

- Swift Playgrounds 4.4 or later, from the App Store (free)
- A YouTube Data API key — see [below](#getting-an-api-key)

That's it. No Mac, no Xcode, no developer account for running on your own iPad.

## Opening the project

1. Get the repository onto the iPad. Working Copy (a git client for iOS) is the
   usual way; a plain download of the zip from GitHub also works.
2. In Swift Playgrounds, **My Playgrounds ▸ +  ▸ Open**, and choose the
   `KTV.swiftpm` folder.
3. Press ▶.

Everything the app needs lives inside `KTV.swiftpm/` — the SwiftUI app in
`App/`, the library in `KaraokeKit/`. That's not a stylistic choice: Swift
Playgrounds can only see the folder you open, and SwiftPM refuses target paths
that escape the package root, so a manifest reaching out to a sibling directory
fails twice over.

The repository's root `Package.swift` and the Xcode project both point *into*
`KTV.swiftpm/` instead. One copy of every file, three build systems reading it,
and edits made on the iPad are edits to the real project.

## Icon and accent colour

`KTV.swiftpm/Package.swift` deliberately doesn't set `appIcon:` or
`accentColor:`. The enum members those accept differ between Swift Playgrounds
versions, and a name that doesn't exist in yours doesn't fail gracefully — the
manifest stops compiling, and the whole project refuses to load with
`FailedToEvaluateManifest` plus an error pointing at the icon rather than at the
version mismatch.

Set them in **⋯ ▸ App Settings** instead. Swift Playgrounds writes the right
syntax for its own version straight back into `Package.swift`.

The same screen is how you put the app on the home screen rather than running it
inside Swift Playgrounds.

## If the project won't load

Read the **Package** section of the error list first, not the **App** section.
A manifest that fails to compile produces a cascade — "Loading failed",
"FailedToEvaluateManifest", "Build failed because the Mach-O file couldn't be
generated" — and every one of those is downstream of a single real error in
`Package.swift`. That real error is the only one worth acting on.

## What works

Everything on the karaoke path:

- Searching for karaoke versions (with an API key)
- The embedded YouTube player, the queue, skip and play-next
- The library, and importing audio files from Files
- Vocal removal on imported files — `Accelerate`, `AVAudioEngine` and `WebKit`
  are all available to Swift Playgrounds

## What doesn't

**The helper service can't run on the iPad.** It's Python and it shells out to
yt-dlp. That only matters for the vocal-removal-from-YouTube path; if you have
an API key, searching and playing karaoke videos needs nothing else. Import a
file from Files if you want to strip vocals from something specific.

**Background audio may not survive being backgrounded.** The `UIBackgroundModes`
key in `App/KTVYouTube/Info.plist` is picked up by the Xcode project, but Swift
Playgrounds manages entitlements through its own App Settings screen and doesn't
expose that one. Audio plays fine while the app is in front. If you find a
version of Swift Playgrounds that does expose it, nothing else needs changing.

**`make app`, XcodeGen and `swift test` are Mac-only.** The tests are a
command-line SwiftPM thing; Swift Playgrounds has no test runner. Push and let
CI or a Mac run them.

## Getting an API key

1. Go to `console.cloud.google.com` and make a project.
2. **APIs & Services ▸ Library**, find **YouTube Data API v3**, enable it.
3. **APIs & Services ▸ Credentials ▸ Create credentials ▸ API key**.
4. Copy it into the app: **Settings ▸ YouTube API key**.

Worth restricting the key to the YouTube Data API while you're in there.

The free allowance is 10,000 units a day. A search costs 100 units and the app
runs two phrasings per search, so roughly **50 searches a day**, resetting at
midnight Pacific. Songs already in your library cost nothing to play again.

## Editing on the iPad

The DSP in `Sources/KaraokeKit/DSP/` is the fiddliest code here and it has a
test suite you can't run from Swift Playgrounds. If you change the separator,
push and run `swift test` somewhere that can — the tests check that the two
stems still sum back to the original exactly, which is the property the vocal
fader depends on and the easiest one to break by accident.

The search ranking in `Sources/KaraokeKit/Ingest/KaraokeRanker.swift` is much
safer to tinker with on the iPad, and it's the part most likely to need
adjusting for whatever gets uploaded in your language.
