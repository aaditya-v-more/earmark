<div align="center">

<img src="docs/icon.png" width="112" alt="Earmark">

<h1>Earmark</h1>

<p>
  <b>A tiny Mac app that reads your books out loud.</b><br>
  It follows along, sentence by sentence and word by word.
</p>

<p>
  <a href="https://github.com/aaditya-v-more/earmark/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/aaditya-v-more/earmark?style=for-the-badge&logo=github&logoColor=white&labelColor=1F1B16&color=B45309"></a>
  <a href="https://github.com/aaditya-v-more/earmark/releases"><img alt="Total downloads" src="https://img.shields.io/github/downloads/aaditya-v-more/earmark/total?style=for-the-badge&logo=github&logoColor=white&label=Downloads&labelColor=1F1B16&color=B45309"></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-B45309?style=for-the-badge&logo=apple&logoColor=white&labelColor=1F1B16">
  <a href="https://github.com/aaditya-v-more/earmark/stargazers"><img alt="Stars" src="https://img.shields.io/github/stars/aaditya-v-more/earmark?style=for-the-badge&logo=github&logoColor=white&labelColor=1F1B16&color=B45309"></a>
  <a href="LICENSE"><img alt="MIT licence" src="https://img.shields.io/github/license/aaditya-v-more/earmark?style=for-the-badge&labelColor=1F1B16&color=B45309"></a>
  <a href="https://ko-fi.com/aadityavmore"><img alt="Support this on Ko-fi" src="https://img.shields.io/badge/Ko--fi-support-FF5E5B?style=for-the-badge&logo=kofi&logoColor=white&labelColor=1F1B16"></a>
</p>

<p>
  <a href="#install"><b>Install</b></a>
  &nbsp;·&nbsp;
  <a href="#voices"><b>Voices</b></a>
  &nbsp;·&nbsp;
  <a href="#plugins"><b>Plugins</b></a>
  &nbsp;·&nbsp;
  <a href="https://github.com/aaditya-v-more/earmark/releases"><b>Releases</b></a>
</p>

<br>

<img src="docs/screenshot.png" width="620" alt="Earmark reading Pride and Prejudice: the current sentence is shaded and the spoken word stands out">

</div>

Earmark is for listening to long books, especially web novels, at whatever
speed suits you. Open an EPUB, PDF or text file and press Space. The sentence being read is
shaded, the word being spoken stands out, and the page scrolls along.

It is one window with one control bar. The app is under 1 MB, opens in
under a second and quits at once. It remembers your place in every book.

## Install

Requires macOS 14 or later, on Apple Silicon or Intel.

With [Homebrew](https://brew.sh):

```sh
brew install --cask aaditya-v-more/tap/earmark
```

Or download **Earmark.zip** from
[Releases](https://github.com/aaditya-v-more/earmark/releases/latest), unzip it
and move **Earmark** to Applications. Earmark is ad hoc signed, not notarised.
On first launch, right-click it and choose **Open**, or allow it in
**System Settings → Privacy & Security**.

To build it yourself, with the Xcode command line tools:

```sh
git clone https://github.com/aaditya-v-more/earmark
cd earmark
./build.sh        # writes build/Earmark.app
```

`DEV=1 ./build.sh` builds **Earmark Dev** instead, with its own settings,
caches and process name, so a test copy can run next to an installed Earmark.
`defaults write com.aadityavmore.earmark.dev mute -bool true` makes it play
silently while still moving the highlights.

## Reading

Earmark opens **EPUB**, **PDF**, **plain text** (`.txt`, `.md`) and **HTML**.
Plain text is split into chapters at headings like "Chapter 12".

Open a book with **⌘O**, from **File → Open Recent**, by dragging it onto the
Dock icon, or with **Open With → Earmark** in Finder. Every book reopens where
you left off, and Earmark starts with the last one you were reading. Your place
is tied to the book itself, so moving or re-downloading the file keeps it.

| Key | |
|---|---|
| Space or ⌘P | Play / pause |
| ⌘→ / ⌘← | Next / previous sentence |
| ⌘] / ⌘[ | Next / previous chapter |
| ⌘G | Go to a chapter by number or title (a page, in a PDF) |
| ⌘= / ⌘- | Faster / slower |
| ⌥⌘= / ⌥⌘- | Bigger / smaller text (zoom, in a PDF) |
| ⌥⌘] / ⌥⌘[ | Wider / narrower column |
| ⌘F | Find in the chapter (the whole PDF); Return for the next match, Shift-Return for the previous |
| ⌘D | Bookmark the current sentence; the Bookmarks menu lists them |
| Media keys | Play / pause, next / previous sentence, from the keyboard, AirPods or Control Center |

Click any sentence to start reading from it. The status line shows where you
are in the book, and the chapter menu follows along. Playback carries on into
the next chapter by itself, without a gap: the next chapter's first sentences
are prepared while the current one finishes. Scroll back to re-read and the
page stays put for a few seconds before following the voice again. After a
pause of more than 30 seconds, the sentence starts over. Drag the window by
its top edge or the empty parts of the control bar.

**Playback → Sleep Timer** stops after 15 to 60 minutes, or at the end of the
chapter. Unplugging headphones pauses reading instead of switching to the
speakers. Light and dark mode follow the system.

### Skipping lines and fixing pronunciation

Web novels repeat lines like "Translator: … Editor: …" in every chapter.
Earmark skips any sentence that matches a pattern in
`~/Library/Application Support/Earmark/skip.txt`, which starts with a few
common ones. To fix how a word is said, add `from => to` lines to
`replacements.txt` in the same folder, such as `Lv. => level`. The page keeps
the original text and the highlight still lands on it. Both files open from
the bottom of the voice menu, and **File → Reload Settings** (⌘R) applies
changes.

## Voices

The voice menu lists the system voices for the book's language, best quality
first. These include every voice installed in **System Settings →
Accessibility → Spoken Content**, the Enhanced and Premium downloads, and
voices added by third-party speech synthesis extensions. System voices report
each word as it is spoken, so the word highlight is exact.

Speed runs from 0.75× to 4×. System voices top out at about 3×.

## Plugins

Any other text-to-speech engine can be added as a plugin in
`~/Library/Application Support/Earmark/engines.json`. Choose **Edit Plugins…**
at the bottom of the voice menu to open the file, and **File → Reload
Plugins** (⌘R) after editing it.

A plugin is either an HTTP endpoint or a command, and it returns a WAV file
for one sentence at a time. Earmark fetches the next sentence while the
current one plays, so there are no gaps.

```json
{
  "engines": [
    {
      "name": "Google",
      "url": "http://127.0.0.1:5591/speak",
      "voices": "http://127.0.0.1:5591/voices",
      "start": ["/usr/local/bin/docker", "start", "gtts"],
      "speed": "engine"
    },
    {
      "name": "Piper",
      "command": ["/opt/homebrew/bin/piper", "--model", "/path/to/voice.onnx", "--output_file", "{out}"],
      "speed": "player"
    }
  ]
}
```

| Field | |
|---|---|
| `url` | Earmark POSTs JSON: your `body` plus `text` and `rate`. The reply is the WAV file. |
| `voices` | Optional. A URL returning `[{"id", "name", "language", "gender"}]`. Each voice gets its own menu entry, and the chosen `id` is sent as `voice`. |
| `command` | The sentence arrives on stdin. `{out}` is the WAV path to write, and `{text}`, `{rate}` and `{voice}` are also replaced. |
| `body` | Optional extra fields to send with every request. |
| `speed` | `engine` passes the speed to the plugin as `rate`. `player` speeds up playback instead, up to 2×. |
| `start` | Optional. A command that starts the plugin's server, such as `["/usr/local/bin/docker", "start", "gtts"]`. Earmark runs it once if the server can't be reached, then retries. |
| `enabled` | `false` hides the plugin. |

If a plugin still can't be reached, Earmark carries on with the best system
voice for the book and says so on the status line. Choose a voice or press ⌘R
to try the plugin again.

Plugins return audio only, so Earmark times the words from the audio itself.
It finds the pauses the voice makes, matches them to the sentence's
punctuation, and spreads the words between two pauses by syllable count.

The first entry works with
[google-tts-local](https://github.com/aaditya-v-more/google-tts-local), which
runs the 51 Google voices from Android and ChromeOS on a Mac, in six
languages. Start its server and they appear under **Google**, filtered to the
book's language. Its `sfg` voice is the default US English voice on Android.

## How it works

Earmark unzips each book once into `~/Library/Caches/Earmark` and shows
chapters in a WebKit view with a reading stylesheet on top. PDFs are shown with
PDFKit and read page by page. A small script
splits the chapter into sentences with `Intl.Segmenter`. It paints the
highlights in a layer behind the text, so the book's own markup is never
changed. System voices speak through `AVSpeechSynthesizer`, and plugin audio
plays through `AVAudioPlayer`.

## Licence

[MIT](LICENSE). The screenshot shows *Pride and Prejudice* from
[Project Gutenberg](https://www.gutenberg.org/ebooks/1342).

The ♥ Donate button in the top-right corner of the window opens Ko-fi. If
Earmark gets you through a long series, you can
[buy me a coffee on Ko-fi](https://ko-fi.com/aadityavmore).
