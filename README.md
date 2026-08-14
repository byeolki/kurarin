# Kurarin

A real-time voice changer for macOS. Transforms your microphone input and mixes in
soundboard samples and system audio, then exposes the result as a virtual microphone
that any app — Discord, Roblox, OBS — can select.

> Status: in development. See `docs/` for design notes (not tracked in git).

## Requirements

- macOS 14.2 or later (Core Audio process taps)
- Xcode command line tools

## Building

```sh
make            # builds the driver and the app into build/
make driver     # virtual audio driver only
make app        # application only
make test       # runs the DSP and preset test suites
```

## Installing the driver

The virtual audio device lives in `/Library/Audio/Plug-Ins/HAL`, which requires
administrator rights and a restart of the system audio daemon:

```sh
sudo ./scripts/install-driver.sh
```

This briefly interrupts all audio on the machine while `coreaudiod` restarts.
To remove it:

```sh
sudo ./scripts/uninstall-driver.sh
```

## Layout

| Path | Contents |
|---|---|
| `Driver/` | `Kurarin Microphone` — a minimal loopback HAL plug-in |
| `Sources/KurarinDSP/` | Audio processing units (no real-time dependencies, fully testable) |
| `Sources/KurarinEngine/` | Core Audio routing: aggregate device, process taps, render callback |
| `Sources/KurarinSoundboard/` | Sample loading and playback |
| `Sources/KurarinPresets/` | Parameter model and persistence |
| `Sources/KurarinApp/` | SwiftUI menu bar app |

## License

MIT
