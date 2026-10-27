<div align="center">

<img src="docs/icon.png" width="112" alt="Earmark">

<h1>Earmark</h1>

<p>
  <b>A tiny Mac app that reads your EPUBs out loud.</b><br>
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
speed suits you. Open an EPUB and press Space. The sentence being read is
shaded, the word being spoken stands out, and the page scrolls along.

It is one window with one control bar. The app is under 1 MB, opens in
under a second and quits at once. It remembers your place in every book.

## Install

Requires macOS 14 or later, on Apple Silicon or Intel.

Download **Earmark.zip** from
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

## Reading

Open a book with **⌘O**, by dragging it onto the Dock icon, or with
**Open With → Earmark** in Finder. The last book reopens where you left off.

| Key | |
|---|---|
| Space or ⌘P | Play / pause |
| ⌘→ / ⌘← | Next / previous sentence |
| ⌘] / ⌘[ | Next / previous chapter |
| ⌘= / ⌘- | Faster / slower |

Click any sentence to start reading from it. The chapter menu on the left
follows the reading position, and playback carries on into the next chapter
by itself. Light and dark mode follow the system.

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
      "name": "Google sfg",
      "url": "http://127.0.0.1:5591/speak",
      "body": { "speaker": "sfg" },
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
| `command` | The sentence arrives on stdin. `{out}` is the WAV path to write, `{text}` and `{rate}` are also replaced. |
| `speed` | `engine` passes the speed to the plugin as `rate`. `player` speeds up playback instead, up to 2×. |
| `enabled` | `false` hides the plugin. |

Plugins return audio only, so the word highlight is estimated from word
lengths and punctuation pauses. It stays close for most voices.

The first entry works with
[google-tts-local](https://github.com/aaditya-v-more/google-tts-local), which
runs Android's Google voices on a Mac. Start its server and pick **Google sfg**.

## How it works

Earmark unzips each book once into `~/Library/Caches/Earmark` and shows
chapters in a WebKit view with a reading stylesheet on top. A small script
splits the chapter into sentences with `Intl.Segmenter`. It highlights them
with the CSS Custom Highlight API, so the book's own markup is never
changed. System voices speak through `AVSpeechSynthesizer`, and plugin audio
plays through `AVAudioPlayer`.

## Licence

[MIT](LICENSE). The screenshot shows *Pride and Prejudice* from
[Project Gutenberg](https://www.gutenberg.org/ebooks/1342).

If Earmark gets you through a long series, you can
[buy me a coffee on Ko-fi](https://ko-fi.com/aadityavmore).
