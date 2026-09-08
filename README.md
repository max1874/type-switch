# TypeSwitch

[简体中文](README.zh-Hans.md)

Keep writing when a word runs out on you.

You are writing in one language, you hit a phrase you don't have, so you type it
in a language you do have and carry on. Tap the Space bar three times and the
line becomes the language you were writing in.

```
这个功能 should be 很简单          →  This feature should be very simple
Je voudrais 预约 une réunion       →  Je voudrais réserver une réunion
明日の会議を 预约 したい            →  明日の会議を予約したい
```

It works in any app that macOS lets it read — a text editor, a browser field, a
chat box, a terminal.

**Read this before installing:** TypeSwitch needs Accessibility and Input
Monitoring permission, which means it can see everything you type and read the
text field you are focused on. It only ever sends the line it rewrites, and only
to the endpoint you configure. Read [How it works](#how-it-works) and the source
before you grant that.

## Requirements

- macOS 14 or later
- Xcode 16 or later, to build it
- An API key for any service that speaks the OpenAI chat-completions format

There is no signed release build. You build it yourself.

## Install

```sh
git clone https://github.com/max1874/type-switch.git
cd type-switch
make app
open build/TypeSwitch.app
```

Move `build/TypeSwitch.app` to `/Applications` to keep it.

By default the project signs ad-hoc, so it builds with no Apple developer
account. The catch is that macOS ties Accessibility and Input Monitoring grants
to the signature, and an ad-hoc signature changes on every build — so you
re-approve TypeSwitch each time you rebuild. If you have a developer account,
`cp Config/Local.xcconfig.example Config/Local.xcconfig`, put your team ID in
it, and the grants stick. That file is gitignored.

### Permissions

On first launch TypeSwitch asks for two grants in System Settings → Privacy &
Security:

- **Accessibility** — to read the line you are on and write the rewrite back
- **Input Monitoring** — to notice the trigger keystrokes

It watches for the trigger and never modifies a keystroke on its way to the app
you are typing in. Grant both and it starts working; no relaunch needed.

### Your key

Open Settings → AI service, pick a provider or type any OpenAI-compatible
address, and paste your key. It is stored in your login keychain and sent only
to that address. Nothing is bundled with the app.

## Development

```sh
make app       # Build TypeSwitch.app into build/
make release   # Signed, notarized, stapled DMG — maintainers only
make clean     # Remove build/
```

`make release` runs on a maintainer's own machine rather than in CI, so the
Developer ID certificate never leaves it. It needs notarization credentials
stored once:

```sh
xcrun notarytool store-credentials TypeSwitch \
    --apple-id <your-apple-id> --team-id <your-team-id> --password <app-specific-password>
```

## Using it

Select some text and trigger, and TypeSwitch rewrites the selection. Select
nothing and it rewrites the line your cursor is on.

## Settings

**Trigger** — click the key field and press whatever key you want, then set how
many taps and how close together. The default is three taps of Space within 0.30
seconds. A modifier key (⇧, ⌘, ⌥, ⌃, left and right are distinct) types nothing,
so it leaves no stray characters in the line; an ordinary key does, and the extra
characters get replaced along with the line.

macOS turns two quick spaces into a period, which lands in the middle of a
Space-triggered rewrite. The Settings window has a switch for that system
setting, so you can turn it off without leaving the app.

**AI service** — the endpoint, the model, and your key. Presets for DeepSeek,
OpenAI, Moonshot, and a local Ollama fill the first two in; anything else that
speaks `POST /chat/completions` works if you type the address yourself.

**Output language** — what your text is rewritten *into*. Default English. Any
language the model knows works; TypeSwitch is not built around one language pair.

**Rewrite instructions** — the system prompt, shown in full and editable.
`{{language}}` is replaced with the output language above. Clear the field to go
back to the built-in one.

**Menu bar icon** — can be hidden. With it hidden, opening TypeSwitch again
brings back the Settings window.

The interface is available in English and Simplified Chinese, following your
system language.

## How it works

**Trigger.** A `CGEventTap` in listen-only mode counts taps of your trigger key.
Listen-only matters: a tap that swallowed the Space would break candidate
selection in every input method, so TypeSwitch never modifies the event stream.
Key repeats are filtered out, so holding the key down does not trigger it.

**Reading and writing.** The Accessibility API first — the focused element's
value and selected range. Some apps report a successful write and apply nothing,
so the write is read back to confirm; if it did not take, TypeSwitch falls back
to synthesizing ⌘C/⌘V, saving and restoring your pasteboard around it.

Because the tap does not modify events, the trigger keystrokes are still on
their way to the app when the tap fires. TypeSwitch waits for them to land
before reading, and re-reads the text at write time to confirm it has not
changed. If focus moved or the text changed, it writes nothing.

**Rewriting.** One non-streaming `POST /chat/completions`. Round-trip is about
0.6s on DeepSeek with reasoning off. The result is written back in one edit, so
⌘Z undoes it in apps that support undo.

## Known limitations

- **It triggers everywhere**, including terminals and code editors, where the
  line it picks up may be a shell prompt rather than prose. There is no
  per-app allowlist yet.
- **Only the DeepSeek path is tested.** The OpenAI, Moonshot, and Ollama presets
  are the documented shapes of those APIs, not verified requests.
- **Undo depends on the app.** Where the pasteboard fallback is used, ⌘Z behaves
  the way a paste does in that app.
- **No signed release.** Build it yourself.

## Privacy

The text of one line, or one selection, goes to the endpoint you configured,
when you trigger it. Nothing else leaves your machine — no telemetry, no
analytics, no other network calls. Your key lives in your login keychain. The
app is not sandboxed, because a sandboxed app cannot create an event tap or read
another app's text.

## License

[MIT](LICENSE) © 2026 Max
