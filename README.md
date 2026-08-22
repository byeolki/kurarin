# Kurarin

[![CI](https://github.com/byeolki/kurarin/actions/workflows/ci.yml/badge.svg)](https://github.com/byeolki/kurarin/actions/workflows/ci.yml)
[![Platform](https://img.shields.io/badge/platform-macOS%2014.2%2B-lightgrey)](#requirements)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

A real-time voice changer for macOS.

Kurarin transforms your microphone, mixes in soundboard samples and system
audio, and publishes the result as a virtual microphone that any application —
Discord, Roblox, OBS, Zoom — can select like any other input device.

```
                clean                       change who it is              shape
             ┌───────────────────────┐   ┌──────────────────────┐   ┌──────────────┐
microphone ─▶│ clicks · hum · hiss   │──▶│ ≤5 kHz  PSOLA shift  │──▶│ formants     │──┐
             │ gate · rumble         │   │ >5 kHz  rebuilt air  │   │ breath·EQ    │  │
             └───────────────────────┘   └──────────────────────┘   │ drive·reverb │  │
                        ▲                            ▲              └──────────────┘  │
                        └────── pitch tracker ───────┘                                │
                            one verdict, shared                                       │
                                                                                      ├─▶ limiter ─┬─▶ Kurarin Microphone ─▶ Discord / Roblox / OBS
soundboard ───────────────────────────────────────────────────────────────────────────┤            │
system audio ─────────────────────────────────────────────────────────────────────────┘            └─▶ your headphones
```

One pitch tracker feeds the whole left-hand side. The gate uses it to know a
held note is still a note, the click suppressor uses it to know a vowel is not a
keystroke, and the shifter uses it to place its grains — all from the same
verdict on the same samples.

> **Status:** feature complete. The driver installs and registers, the app runs,
> and 195 automated tests cover the DSP — including a check that nothing on the
> audio thread touches the heap. What has not been signed off is how it
> *sounds*: that needs a person and a pair of headphones, and the checklist is
> [docs/manual-testing.md](docs/manual-testing.md) (Korean).

## What it does

- **Pitch and formant independently.** Raising pitch alone gives you a chipmunk.
  Formant shifting moves the resonances of the vocal tract separately, which is
  the difference between a sped-up recording and a voice that sounds like a
  different person.
- **PSOLA on voiced sounds.** Voiced speech is cut and overlapped at glottal
  period boundaries rather than pushed through a phase vocoder, which avoids the
  metallic ringing that gives most voice changers away. Fricatives take a
  separate path that leaves their transients intact.
- **Cleaning that knows what a voice is.** Mouse clicks, typing and knocks are
  ducked through a look-ahead; fans, hum and hiss are subtracted band by band.
  Both use the pitch tracker to tell speech from noise, which is why a held
  "aaah" survives instead of fading out halfway through the way it does under
  suppressors that decide from level alone.
- **A soundboard that does not fight the voice.** Samples are decoded to memory
  up front, triggered from global shortcuts, and mixed before a look-ahead
  limiter so a meme and a shout at the same time do not clip.
- **System audio without the routing dance.** Sound is copied from other apps
  with a Core Audio process tap, so what you share keeps playing normally
  through your own headphones and the volume keys keep working.
- **Air rebuilt rather than repeated.** Above five kilohertz a voice is breath
  and hiss, and a pitch shifter repeats that into a buzz locked to the new note
  — most of why shifted voices sound shifted. That band is measured and
  regenerated as fresh noise instead, moved by the formant ratio so a smaller
  speaker's fricatives sit higher.
- **Presets that aim at a pitch.** "Sound like a woman" is 200 Hz, not a
  multiplier: a ratio that suits a deep voice overshoots a light one. Kurarin
  measures where your voice normally sits and works out the rest, slowly enough
  that your intonation survives. The shift is bounded to an octave either way,
  because past that the grain repetition stops sounding like a person — so a
  deep voice aimed at the top of the range lands short, and the interface says
  so rather than leaving you wondering.
- **Latency you choose.** 36, 46 or 56 ms end to end, trading the lowest
  fundamental the pitch tracker can follow against delay.
- **Screen recording that captures what was sent.** Not what your speakers are
  playing — the engine's own mix, after the limiter, so the file holds the
  transformed voice and the soundboard exactly as your listeners got them. The
  audio thread copies its block into a lock-free ring and the encoding happens
  somewhere else, because a render callback cannot wait on a disk.

## Requirements

- macOS 14.2 or later — process taps and `CATapDescription` landed there
- Xcode command line tools (`xcode-select --install`); no Xcode project needed
- Administrator rights, once, to install the virtual audio device

Apple silicon and Intel are both built; the driver is a universal binary.

## Build and install

```sh
git clone https://github.com/byeolki/kurarin.git
cd kurarin
make                                  # driver + app into build/
sudo ./scripts/install-driver.sh      # installs the virtual microphone
open build/Kurarin.app
```

Installing the driver copies a bundle into `/Library/Audio/Plug-Ins/HAL` and
restarts `coreaudiod`, which interrupts audio everywhere on the machine for a
second or two. The script reports whether the device actually registered.

Other targets:

```sh
make driver     # virtual audio device only
make app        # application only
make test       # every suite, plus the release-only real-time checks
make clean
```

To remove the device again:

```sh
sudo ./scripts/uninstall-driver.sh
```

The app itself needs no installation — it runs from `build/`, or drag it to
`/Applications`.

## Using it

1. Open Kurarin. It lives in the menu bar; **Settings…** opens the main window.
2. **Devices** — pick your real microphone, and the headphones you want to
   monitor through. Press **Start**.
3. In Discord, Zoom or OBS, choose **Kurarin Microphone** as the input device.
   Roblox has no microphone picker, so leave *Make Kurarin the system default
   microphone while running* on and it will follow along. Your previous default
   is restored when you stop.
4. **Voice** — pick a preset, or move pitch and formant yourself and save your
   own. With *Aim for a pitch* on, the line under the slider tells you what it
   has measured your voice at and where it is actually landing, which will not
   be the target if that is more than an octave away. Presets are plain JSON in
   `~/Library/Application Support/Kurarin/presets`.
5. **Soundboard** — drop audio files onto the tiles, set a volume, bind a key.
6. **Record screen** in Devices, or from the menu bar. Recordings land in
   Movies. macOS asks for screen recording permission the first time; if you
   refuse it, the button says so and nothing else stops working.
6. **Shortcuts** — click a binding and press the combination you want. These
   work while a game holds the keyboard and need no accessibility permission.

Defaults: F1 mute, F2 toggle the effect, F3/F4 previous and next preset,
F5 stop all sounds.

### Permissions

macOS asks for microphone access the first time the engine starts, and for
audio recording permission the first time you turn on system audio capture.
Refusing the second one disables only that feature; the voice and the soundboard
keep working.

## How it is put together

Two separate products, for a reason worth stating plainly: the driver runs
inside `coreaudiod`, so a crash there takes down audio for the entire machine
and every fix costs an admin password and a daemon restart. The driver is
therefore a fixed, minimal loopback with no settings and no IPC, and everything
that can change lives in the app.

| Path | Contents |
|---|---|
| `Driver/` | `Kurarin Microphone` — a minimal loopback HAL plug-in in C |
| `Sources/KurarinDSP/` | Processing units. No real-time dependencies, fully testable |
| `Sources/KurarinEngine/` | Aggregate device, process tap, render callback |
| `Sources/KurarinSoundboard/` | Sample decoding and lock-free playback |
| `Sources/KurarinPresets/` | Parameter model and JSON persistence |
| `Sources/KurarinRecording/` | Screen capture, and the ring that gets audio off the render thread |
| `Sources/KurarinApp/` | SwiftUI menu bar app and main window |

[docs/architecture.md](docs/architecture.md) covers the routing, the shifter and
the real-time rules in detail.

## Testing

```sh
make test
```

The DSP is where automated tests are meaningful: synthetic signals go in,
measured pitch, level and stability come out. Routing and the driver need
hardware and a person, and are covered by
[docs/manual-testing.md](docs/manual-testing.md) (Korean) instead.

Two things are worth knowing about how the suite is kept honest.

**The no-allocation rule is checked, not trusted.** A counter on Darwin's
`malloc_logger` runs the whole chain, every unit, the mixer and the channel
router and asserts none of them touch the heap. It needs the optimiser — a debug
build allocates once per loop iteration for bookkeeping release removes — so
`make test` runs it as a separate release step, and it skips itself with an
explanation if you invoke it the other way.

**The tests are mutation-checked.** Every claim the DSP comments make about why
a design choice exists has been broken on purpose to see whether anything
notices. The first sweep found half of them unguarded, including both
concessions to voicing that stop the click suppressor eating a held vowel. Two
claims turned out not to survive the measurement they implied — the comments now
say what was established and what was not — and one piece of code was removed
outright when its stated benefit could not be reproduced but its cost could.

If you add a test here, break the thing it covers and watch it fail before you
trust it. Several tests in this repository were green and worthless until
someone did.

## Contributing

Bug reports and pull requests are welcome — see
[CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE).
