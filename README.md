# Kurarin

A real-time voice changer for macOS.

Kurarin transforms your microphone, mixes in soundboard samples and system
audio, and publishes the result as a virtual microphone that any application —
Discord, Roblox, OBS, Zoom — can select like any other input device.

```
microphone ──▶ noise gate ──▶ pitch / formant shift ──▶ EQ ──▶ drive ──▶ reverb ──┐
                                                                                  ├─▶ limiter ─┬─▶ Kurarin Microphone ─▶ Discord / Roblox / OBS
soundboard ───────────────────────────────────────────────────────────────────────┤            │
system audio ─────────────────────────────────────────────────────────────────────┘            └─▶ your headphones
```

> **Status:** feature complete, not yet verified end to end on a machine with
> the driver installed. See [docs/manual-testing.md](docs/manual-testing.md) for
> the checklist that has to pass before this is called stable.

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
  that your intonation survives.
- **Latency you choose.** 36, 46 or 56 ms end to end, trading the lowest
  fundamental the pitch tracker can follow against delay.

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
make test       # DSP, preset and soundboard test suites
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
   own. Presets are plain JSON in
   `~/Library/Application Support/Kurarin/presets`.
5. **Soundboard** — drop audio files onto the tiles, set a volume, bind a key.
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
[docs/manual-testing.md](docs/manual-testing.md) instead.

## Contributing

Bug reports and pull requests are welcome — see
[CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE).
