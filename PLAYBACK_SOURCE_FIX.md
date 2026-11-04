## Build 15 follow-up (device report)

Build 14 did not resolve the tester's YouTube refusal and the tester reports termination to the Home Screen. The crash cause is **unconfirmed pending an iOS .ips report**; do not describe build 15 as a verified crash fix.

Reproduced by source inspection: JioSaavn results were only added to Songs, not All; iPhone source picker vanished after typing; history rebuilt provider keys as YouTube entries; QueueEntry.videoId exposed provider keys to YouTube background work. Build 15 adds a permanent JioSaavn search choice, includes alternatives in All, preserves history routing, and excludes provider keys from videoId. Direct search never calls YouTube, including empty or failed provider searches. Provider search failures are distinguished from an empty catalogue. Playback failures use a readable alert instead of a truncated toast. Build archives retain dSYM symbols for diagnosing device reports.

Ordinary live JioSaavn API probe returned a successful provider audio token and HTTP 206 audio/mp4 bytes for a catalogue karaoke recording. Queries for the tester's exact Silica Gel and Sabrina Carpenter recordings returned no matching recording; Maroon 5 returned karaoke versions. This is evidence of provider transport availability on the laptop, not successful iPhone playback or availability of those original recordings. No automatic substitution with covers is permitted.

Regression checks cover direct provider isolation, empty/error behavior, mixed results, fallback, disabled providers, cancellation, and persisted provider/YouTube keys. Windows cannot run the Swift or iOS binary; hosted Mac checks and device testing remain required.

# BitChord iOS playback investigation

Investigated on 3 November 2026. Installed app reported by the listener: iOS 1.0.4, build 13, signed on Windows with Sideloadly. Base: `898d8ed746b1bfdeb26a4c2d24484844241ed990` (`main`). Local branch: `fix/playback-source-failures`.

## Result

This patch repairs the separate direct-JioSaavn resolution path and makes source state and refusal handling consistent. It does **not** remove YouTube's verification requirement or establish that playback is repaired on an iPhone. A new Apple build and physical-device validation are still required.

## Findings

### Release and issue status

The [latest release](https://github.com/bagumamartin/BitChord/releases/tag/v1.0.4) is still 1.0.4 build 13, tagged at `b4aae80294cb80a5994c95ba486eb68d80d13b21`. Its notes say JioSaavn catalogue and playback work again. Comparing that tag with the inspected main commit found only README, appcast and artwork changes: the relevant playback code is identical. Updating to current main alone therefore supplies no newer playback fix.

The repository has no open issues or PRs at inspection time. Its only issue, [#1](https://github.com/bagumamartin/BitChord/issues/1), concerns Discord presence/random play and is closed. Earlier playback/source PRs, including [#11](https://github.com/bagumamartin/BitChord/pull/11), describe work incorporated into this release; they are not evidence that this listener's device works.

### Metadata and stream resolution are separate

Library and playlist metadata do not establish access to audio. Queue entries from YouTube remain `yt:<videoId>`. `PlaybackController.resolveSource` sends them to the YouTube extractor, except for usable downloads/cache or explicitly pinned original-version handling. Enabling JioSaavn permits catalogue lookup; it does not rewrite library tracks into JioSaavn IDs.

Source settings do affect the shared resolver: `SourceRegistry.activeForPlayback`, `SourceResolver.canSubstituteForYouTube` and `substituteForYouTube` consult enabled sources, rank, recording metadata and the quality setting. LOW/MEDIUM currently admit only YouTube to automatic substitution; HIGH permits JioSaavn; LOSSLESS permits all eligible kinds. JioSaavn is lossy AAC. An original-version pin also keeps a track on YouTube.

On Apple, the startup race uses a zero-second preference window and still starts with the selected YouTube upload. Even if the alternative finishes first, the `.preferred` branch awaits YouTube and retains the candidate for subsequent recording verification.

### Exact origin of the bot message

Call chain: Swift `InnertubeStreamResolver` -> Kotlin `PlayerBridge` -> `StreamResolver` -> `UpstreamPlaybackExtractor` -> vendored `InnerTubeExtractor`.

After extraction throws or yields no stream, `StreamResolver.isBotChecked` makes an anonymous diagnostic request to `https://www.youtube.com/youtubei/v1/player` using its existing ANDROID_VR profile. If `playabilityStatus.reason` contains `not a bot`, it raises `BotCheckException` and sets a 120-second backoff shared across resolutions until expiry or session change. `PlayerBridge` forwards the error, Swift converts it to a sentence, and the load-failure path presents the toast.

Consequently the toast proves that this diagnostic request was refused. It does **not** prove a bad Wi-Fi address, establish why the original extraction failed, or prove that changing networks will help. Both cellular and Wi-Fi failing is consistent with this code. This investigation did not obtain the listener's raw extraction diagnostics and cannot identify the server-side decision with more precision.

### Why JioSaavn fallback does not rescue these library tracks

`recoverRefusedTrack` awaits the alternative lookup and shelves a candidate with `QualityUpgrade.shelve`; it does not return the candidate for playback. It skips another YouTube counterpart request for bot failures, then throws. Other race outcomes could previously throw before reaching this common refusal handler.

This behavior is tied to a recording safeguard. `RecordingIdentityVerifier.matches` compares decoded audio against the original YouTube upload or a usable original cache. Metadata matching alone cannot establish recording identity. When the original audio is unavailable, automatically promoting a catalogue result can play a different master, edit or recording. The patch preserves this safeguard.

Explicit JioSaavn results are different: the listener chooses that catalogue's recording directly. Their `saavn:` IDs should resolve solely through JioSaavn, without requiring a YouTube reference.

### A separate obsolete direct-playback implementation

Before the patch, `AppleApp/.../JioSaavn.swift` locally DES-decrypted the opaque media value and sometimes replaced a filename suffix with `_320`. The shared `JioSaavnSource` instead requests a URL using the provider's `song.generateAuthToken` API. Direct JioSaavn results therefore did not use the implementation mentioned in the release's shared-source repair.

Search also checked the legacy `jiosaavn_enabled` preference, while Sources updates the registry's enabled state. Search results could disagree with the visible switch, and JioSaavn results were unavailable when YouTube catalogue search threw.

## Changes

- Direct `saavn:` playback now uses the shared JioSaavn provider resolver, with the current playback ceiling or the separate download-quality request. Only enabled JioSaavn is eligible; an explicit selection never falls through to YouTube. Explicit capped AAC selection is independent of the automatic substitution eligibility filter.
- Removed local DES decoding and guessed CDN filename rewriting. Provider refusals stop resolution. Missing/unsafe URLs are rejected. Track details must contain the requested provider ID. The advertised lack of a 320-kbps rendition is respected, and Lossless requests correctly report lossy delivery.
- Search consults the registry, uses a bounded request and checks HTTP status. If YouTube search fails, enabled JioSaavn results can still be shown. Track rows visibly identify JioSaavn, including their accessibility labels, so listeners can distinguish the direct catalogue choice.
- All startup-race paths now use the same recovery/cancellation helper. Bot refusals explain why a found alternative cannot be verified and suggest an explicit catalogue selection. Messages no longer diagnose the network as the cause or promise that switching networks usually fixes it. Existing backoff remains.
- Added mocked Kotlin provider/routing regressions and a Swift recovery/cancellation verification executable.

## Verification and limits

Passed: **15 Kotlin/JUnit tests** (one existing transport test and fourteen new tests), compiled from the real provider, direct-routing, format, duration and source-kind files with Kotlin 2.4.10/JDK 21 and the repository's Ktor 3.5.2 / kotlinx 1.11.0 versions. A focused Windows JVM harness substituted only platform HTTP, registry/config storage and a copy of the Song data type. Live HTTP was forbidden in those tests. These results do not validate Apple Keychain, bridge export/serialization, native decoding or the complete application.

A separate ordinary live JioSaavn search returned catalogue rows with IDs and media fields. No audio-token or CDN listening check was performed; this does not establish regional playback availability. No live YouTube extraction, credentials, cookies, CAPTCHA handling, identity changes or access-control bypass was attempted.

`git diff --check` passed. Swift recovery tests are provided but **not run**, and the iOS app was **not compiled**: this Windows machine has no Swift/Xcode/Apple SDK toolchain. Full Kotlin/Native, Rust and Apple integration checks remain pending on a Mac. This is a source patch requiring review and build validation.

On a supported Mac, from the patched checkout:

```sh
./gradlew :shared:macosArm64Test
bash scripts/check-source-recovery.sh
CONFIG=release ./scripts/build-shared-framework.sh
./scripts/build-native-core.sh
xcodegen generate --spec AppleApp/project.yml
xcodebuild -project AppleApp/BitChord.xcodeproj -scheme BitChord \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

Rebuild the shared framework before Swift compilation: the bridge has a new exported method. Also run the project's source-priority/source-bridge checks and test real iPhone playback before distribution. The project expects XcodeGen, a supported JDK, Rust/Apple targets and CMake; see the repository README.

## Getting a corrected IPA onto the Windows user's phone

1. A Mac builder applies the patch, runs the pending checks and creates a new unsigned IPA using `scripts/package-ios-ipa.sh 1.0.4 --output-dir build/release` after generating the frameworks/project. Use a distinct build identity for any distributed candidate; do not overwrite or relabel upstream build 13.
2. Transfer the resulting **iOS device IPA** to Windows. Sideloadly signs/installs an existing IPA; it does not compile this Swift/Kotlin/Rust source tree. A simulator build or ZIP of source is not a sideloadable app.
3. Use Sideloadly with the same signing identity and app identifier as the existing install. Install over it and retain the old IPA. Do not delete the app first; changing the effective identifier can create a separate install and affect data/Keychain continuity.
4. Enable JioSaavn in Sources. In Search select the YouTube catalogue and Songs scope; JioSaavn results are inserted before YouTube results. Select a result labelled JioSaavn explicitly. Existing library/playlist YouTube rows still require YouTube audio or a previously verified usable copy.

Device acceptance: direct JioSaavn playback on Wi-Fi and cellular; enabled/disabled state across relaunch; low-cap AAC and a normal-quality request; unrelated/missing track and provider refusal; next/stop during a lookup; normal YouTube playback where available; and the clearer refusal message where unavailable. A provider may still refuse or lack a track, and this patch cannot guarantee access.

## Handoff

Upstream is read-only for the connected GitHub account. The connector exposes no fork-creation action. Browser fallback was stopped by Computer Use because it could not verify Opera's current URL sufficiently to enforce its policy. No fork or remote draft PR was created, and upstream was not changed. The local branch, commit patch, changed-source archive and ready-to-use draft PR description are the deliverables. A maintainer can apply the patch and build it, or the branch can later be pushed to an authorized fork.
