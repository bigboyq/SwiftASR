# SwiftASR Help

## Requirements

- An Apple Silicon Mac (M1 or newer)
- macOS 14 Sonoma or later
- About 1 GB of free space for installation, plus working space for long audio
- A network connection and your own Gemini API key only if you use cleanup

Intel Macs are not currently supported.

## Install and open the app

1. Download `SwiftASR-<version>-<build>.dmg` from GitHub Releases.
2. Open the DMG and drag `SwiftASR.app` to Applications.
3. Public preview builds are not yet notarized by Apple. For the first launch,
   Control-click or right-click the app in Finder, choose Open, then confirm.
4. If macOS still blocks it, open System Settings → Privacy & Security and use
   Open Anyway beside the SwiftASR notice.

If macOS reports that the app is damaged, first verify that the download and
SHA-256 checksum came from this project's official GitHub Release. You may then
remove the quarantine attribute:

```bash
xattr -dr com.apple.quarantine /Applications/SwiftASR.app
```

Only do this for a download whose source and checksum you have verified.

## Quick start

1. Open Files and import an audio file.
2. Review the queue in Transcription and start the job.
3. When it finishes, use Results to switch between sentence-level raw text,
   speaker-merged text, and cleaned text.
4. Select a speaker name to label it, adjust an assignment, or synchronize it
   with the local speaker library.
5. Export produces exactly the text represented by the current Results preview.

The current interface is primarily in Simplified Chinese. Main navigation maps
as follows: 文件 = Files, 转写 = Transcription, 结果 = Results, 说话人 = Speakers,
设置 = Settings.

## Results and editing

Each job uses one structured `result.json` as its working document. Manual edits
and Gemini cleanup do not overwrite raw text, timestamps, automatic speaker
labels, or acoustic fingerprint evidence. Cleaned text remains separately
editable so the original recognition can still be inspected.

If a merged row comes from multiple source segments, restore or confirm the
source speaker assignments before editing it.

## Gemini cleanup and privacy

Local transcription does not upload audio. When you explicitly start Gemini
cleanup, the text batch being processed, speaker labels, and configured glossary
hints are sent to the Google Gemini API. Google's Gemini API terms and data
policies apply.

The Gemini API key is currently stored at:

```text
~/Library/Application Support/SwiftASR/settings.json
```

SwiftASR restricts the file to the current user, but the key is not stored in
macOS Keychain. Enable FileVault and do not save a key in an untrusted or shared
macOS account.

## Local data

SwiftASR stores settings, its SwiftData database, job results, logs, and speaker
profiles under:

```text
~/Library/Application Support/SwiftASR/
```

Removing the app does not automatically remove this directory. Back up results
you want to retain before deleting it.

## Bundled models

Release builds contain local runtime artifacts for FSMN-VAD, SeACo-Paraformer,
CT-Transformer punctuation, and ERes2NetV2 speaker embeddings. Their sources,
versions, licenses, and paper citations are documented in
[MODEL_LICENSES.md](../MODEL_LICENSES.md) and
[ACKNOWLEDGEMENTS.md](../ACKNOWLEDGEMENTS.md).

## Troubleshooting

### The app will not open

Confirm that the Mac uses Apple Silicon and macOS 14 or later, then follow the
steps above for an unnotarized build.

### A model is missing or invalid

Download the DMG again from the official Release and verify its checksum. Do not
move `Contents/Resources/Models` out of the application bundle.

### Transcription is slow or memory use is high

Long recordings require PCM, acoustic features, and speaker clustering working
data. Close other memory-heavy apps, keep sufficient free disk space, and split
exceptionally long recordings when practical. Jobs can be paused or cancelled.

### Speaker assignments are inaccurate

Overlapping speech, very short turns, background noise, and distant microphones
reduce diarization quality. Correct assignments in Results and use clear,
sufficiently long samples for the local speaker library.

### Gemini cleanup fails

Check the API key, proxy/network access, account quota, and Gemini service status.
Local transcription is independent of cleanup; a Gemini failure does not delete
the raw transcript.

## Support

Remove audio content, API keys, personal paths, and sensitive transcript text
before opening a public issue. Use GitHub Issues for normal support and follow
[SECURITY.md](../SECURITY.md) for private security reports.
