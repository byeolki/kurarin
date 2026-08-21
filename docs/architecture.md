# Architecture

How Kurarin is put together, and why it is put together that way. Written for
someone about to change the code.

## The shape of the thing

Two products, deliberately separated:

```
┌─ Kurarin.driver ───────────────────────────┐
│  lives inside the coreaudiod process       │
│  "Kurarin Microphone", 2 in / 2 out        │
│  one shared ring buffer. no DSP. no config │
└────────────────────────────────────────────┘
        ▲ writes (output stream)   ▼ reads (input stream)
        │                          └──▶ Discord / Roblox / OBS
┌─ Kurarin.app ┴──────────────────────────────────────┐
│  KurarinApp        SwiftUI menu bar, window, hotkeys │
│  KurarinPresets    parameter model, JSON persistence │
│  KurarinEngine     aggregate device, taps, render    │
│  KurarinDSP        processing units (Accelerate-free)│
│  KurarinSoundboard decoded samples, lock-free mixer  │
└──────────────────────────────────────────────────────┘
```

The split is the single most important decision in the project. A HAL plug-in is
loaded into `coreaudiod`; if it crashes, audio dies for the whole machine, and
replacing it costs an administrator password and a daemon restart. So the driver
is a fixed, minimal loopback — no volume control, no configuration surface, no
IPC with the app — and everything that might need changing lives in the app,
where a mistake costs one relaunch.

With the app closed the device still exists and outputs silence, which is what
an application holding it open should see.

## KurarinDriver

`Driver/KurarinDriver.c`, an `AudioServerPlugIn`.

- Device `Kurarin Microphone`, UID `com.byeolki.kurarin.microphone`
- 2 channels, Float32 interleaved, 44100 / 48000 / 96000 Hz, 48000 default
- Frames written to the output stream land in a ring buffer; reads of the input
  stream return the same position of that ring
- If nothing has written for 100 ms, the input returns silence rather than
  looping stale audio
- `GetZeroTimeStamp` derives a sample counter from the host clock

## KurarinEngine

### Aggregate device

Separate audio devices run on separate clocks. Bridging them with a hand-rolled
ring buffer means the two ends drift apart, and a few minutes later the audio
starts ticking — a bug that is miserable to reproduce and worse to fix.

So the engine does not bridge devices. It builds a **private aggregate device**
containing the input microphone, the virtual device, the monitoring output and
the system tap, and lets Core Audio resample against a designated master clock.

- `kAudioAggregateDeviceIsPrivateKey` keeps it out of Audio MIDI Setup and out
  of every other app's device list, and destroys it when the app exits. Users
  never have to build or maintain a routing device by hand.
- `kAudioAggregateDeviceMainSubDeviceKey` is the microphone: input is the most
  jitter-sensitive member, so it holds the clock.
- Every other sub-device gets drift compensation at
  `kAudioAggregateDriftCompensationMaxQuality`.

A device change rebuilds the aggregate from scratch. There is no partial update
path, because there is no partial update path worth the bugs.

### System audio tap

`AudioHardwareCreateProcessTap` copies what other applications are playing
without taking it away from them, which is why sharing music does not make the
sound vanish from your own headphones.

- Everything: `CATapDescription(stereoGlobalTapButExcludeProcesses:)` excluding
  Kurarin itself. The list takes audio object IDs, not process IDs, and the HAL
  only has an object for a process that has already done I/O — so the engine
  announces itself with a throwaway callback if it has to. Getting this wrong
  means the engine captures what it writes to the virtual device and mixes it
  back in, one block later, forever.
- Chosen apps: `CATapDescription(stereoMixdownOfProcesses:)`. The user's choice
  is stored as bundle identifiers and resolved to live process objects when the
  tap is built, since a process object ID only lives as long as its app.
- Needs macOS audio recording permission. Refused, only capture is lost: the
  voice and the soundboard keep working.

### Render callback

One IOProc on the aggregate. Per block:

1. read the microphone channels, summed to mono
2. run the voice chain (it runs even while muted, so the delay lines stay primed
   and unmuting does not jump the stream by the shifter's latency)
3. mix the soundboard and the tap
4. limit
5. write to the virtual device's channels
6. write the monitoring channels — soundboard, plus the voice on request. The
   tap is deliberately excluded: those apps are already audible in the same
   headphones, and echoing them back doubles every sound.

Real-time rules for anything reachable from this callback: no allocation, no
locks, no Objective-C messaging, no dynamic dispatch through the Swift runtime.
Buffers are preallocated at their maximum block size.

The first of those is enforced rather than assumed. `AllocationTests` installs
a counter on Darwin's `malloc_logger` and drives the whole chain, every unit
individually, and the pitch tracker, asserting that none of them touch the
heap. It runs in release only — a debug build allocates per loop iteration for
bookkeeping the optimiser removes — and it is wired into `make test` and CI as
a separate step.

Data crosses the boundary in one of three ways:

| Direction | Mechanism |
|---|---|
| UI → audio, commands | SPSC lock-free ring (`CommandQueue`) |
| UI → audio, parameter sets | three-slot publisher with an atomic index (`ParameterSlot`) |
| audio → UI, levels | plain stores of a `Float`, read on a timer |

`ParameterSlot` exists because writing a coefficient set field by field lets the
audio thread observe half of the old set and half of the new one. For a gain
that is inaudible; for a biquad it can mean a momentarily unstable filter, which
is a crack in the middle of a sentence.

## KurarinDSP

Pure units with preallocated state, exposed as
`process(buffer, frameCount:)`. No hardware, no I/O, no dependency on the rest
of the app — which is what makes this the one part of the project where
automated tests are genuinely meaningful.

Chain order:

```
input gain
  → pitch tracking (on the untouched signal)
  → transient suppressor → noise reducer → noise gate → high pass
  → split at 5 kHz ─┬─ low: VoiceShifter (PSOLA)
                    └─ high: HighBandShaper (rebuilt as noise)
  → formant correction → breath → parametric EQ → drive → reverb → output gain
```

Pitch is tracked first, on the signal before anything has been done to it: a
gate that has already closed or a click that has already been ducked would make
the tracker answer a question about audio nobody is going to hear. One verdict
then serves four units, which is the difference between this chain and a stack
of independent effects.

Cleaning happens before the gate — with the room tone already gone the gate has
a much clearer difference between speech and silence — and the high pass runs
before the shifter, because low-frequency rumble is what makes a pitch tracker
report an octave too low. Everything after the split shapes the voice the
listener actually hears.

### The split

Speech divides at roughly five kilohertz. Below it the signal is harmonic and
PSOLA is the right tool. Above it the signal is air — breath, and the hiss of
"s" and "sh" — and PSOLA is the wrong one: raising pitch means laying the same
glottal period down more often, and the noise inside that period is repeated
with it, locked to the new fundamental. Measured on a breathy vowel raised by
half, the noise above three kilohertz went from a periodicity of 0.013 at the
input to 0.265 at the output. That buzz is most of what makes a shifted voice
sound shifted rather than like somebody else.

Two things fixed it. Repeated grains are read from earlier glottal periods —
whole periods back, so the harmonics stay aligned while the noise gets a fresh
sample of itself — which took it to 0.098. And the band above the split is not
moved at all: it is measured as four sub-band envelopes and rebuilt from fresh
noise, which takes it to 0.013, the input's own figure. The synthesis bands sit
where the analysis bands land after the formant ratio has moved them, which is
how a change of size finally reaches the fricatives; a child's "s" is higher
than an adult's, and pitch alone never did that.

This is the harmonic-plus-noise model from the speech literature, minus the
spectrum it usually needs to do it.

Everything is mono, Float32, at the engine's sample rate. There is no resampling
inside the chain — the aggregate device deals with rate differences.

### VoiceShifter

Where most of the quality lives. Time-domain PSOLA, exploiting the fact that a
human voice is a single source with a clear fundamental.

1. **Pitch tracking** (YIN-style) gives F0 and a voiced/unvoiced decision per
   analysis frame.
2. **Voiced frames** are cut into grains at glottal period boundaries and laid
   down every `period / pitchRatio` samples. The output repeats at a rate the
   caller chooses, with none of the metallic ringing a phase vocoder leaves on
   speech.
3. **Formants** come from resampling each grain by `formantRatio` as it is laid
   down. A grain is a couple of periods long, so what survives the resampling is
   the spectral envelope while the mark spacing re-imposes periodicity. Pitch
   and formant therefore move independently — which is the difference between a
   child's voice and a chipmunk.
4. **Unvoiced frames** take a separate path: fixed-length grains at their
   original spacing, resampled by the formant ratio only. PSOLA on a fricative
   invents glottal marks that are not there and buzzes. Noise has no pitch to
   move, and what the ear reads as "smaller" in an "s" is purely spectral.

The design sketch called for a phase vocoder on the unvoiced path. Fixed-grain
overlap-add replaced it: on noise the two are perceptually equivalent, while
overlap-add keeps transients intact and adds no latency.

### Latency

Latency is set by the lowest fundamental the tracker must resolve. A grain
reaches one period forward in the output and `period × formantRatio` forward in
the input, and both have to be in hand before a sample can leave, so the
shifter's delay is `period × (1 + maximum formant ratio)` with the formant
ceiling at 2.

| Mode | Lowest F0 | Period | Shifter | With suppressor and limiter |
|---|---|---|---|---|
| Low | 100 Hz | 480 | 1440 frames (30 ms) | 36 ms |
| Balanced | 75 Hz | 640 | 1920 frames (40 ms) | 46 ms |
| Quality | 60 Hz | 800 | 2400 frames (50 ms) | 56 ms |

The click suppressor's look-ahead adds four milliseconds and the limiter's two.
The rebuilt high band adds none: it waits exactly as long as the shifter does,
so the two halves arrive together.

Low mode will not track a deep voice reliably; that is the trade being made.
Window sizes are constructor parameters, and switching modes rebuilds the
shifter, so the engine restarts rather than resizing anything mid-stream.

### Identity, not just pitch

Two further things separate "a voice moved up" from "a different person".

**Where the pitch lands.** A ratio is the wrong unit for "sound like a woman":
1.28 times a deep voice arrives at 155 Hz, which is neither, and the same
preset overshoots someone lighter. Presets can name a frequency instead, and
the shifter works out the ratio from the pitch it is already tracking. What it
tracks is the speaker's resting pitch, not the sentence's: it settles in a
couple of seconds and then moves over half a minute, because a sentence rises
and falls in one or two and following that would cancel out the intonation and
leave the output reading on a single note.

**Breath.** A glottis does not close completely, and the air that keeps
escaping is heard as noise above two kilohertz — one of the cues for who is
speaking, and stronger in female voices. It is generated fresh, shaped by the
envelope of the voice and only while the signal is voiced, because a fricative
is already noise.

**Formant correction.** A shorter vocal tract raises its upper resonances more
than its lower ones, and grain resampling multiplies every frequency by the
same number. The literature warps the frequency axis piecewise; that needs a
spectrum and an FFT window this chain cannot afford, so the difference between
the two maps is applied as a pair of shelves derived from the ratio.

### The other units

- **NoiseGate** — threshold with hysteresis and a hold time. One threshold makes
  the gate chatter on breath sitting right at the boundary, which is more
  distracting than the noise it removes. It also stays open while the tracker
  hears a voice, so a held note is not cut off by a threshold that was right
  for its beginning.
- **TransientSuppressor** — mouse clicks, key presses, knocks. Compares a
  one-millisecond envelope against a fifteen-millisecond one, because a knock
  is only a little louder than a shout but gets there in a fraction of the
  time, and ducks through a four-millisecond look-ahead. Anything still loud
  after ten milliseconds is not a click.
- **NoiseReducer** — fans, hum, hiss. Eight bands, each learning how quiet it
  gets, subtracting in power rather than in amplitude. It only learns while the
  tracker hears no voice: steadiness cannot separate noise from speech, because
  a held vowel is steady too, and an estimator that learns from anything steady
  eventually decides the vowel is the room — which is why "aaah" fades out
  halfway through on every other noise suppressor.
- **Biquad** — transposed direct form II, Audio EQ Cookbook coefficients.
- **ParametricEQ** — five bands: low shelf, three peaks, high shelf.
- **Drive** — saturation, bit crush and sample rate crush as three separate
  controls, because a radio voice and a robot want different ones.
- **Reverb** — Freeverb-style, mono.
- **Limiter** — 2 ms look-ahead brick wall. Last in the chain: a listener on a
  virtual microphone cannot turn down the source, so clipping there is
  especially unpleasant.

## KurarinSoundboard

Files are decoded to mono Float32 at the engine's rate when they are assigned,
and validated then — the audio thread never touches a decoder, a file or an
allocator.

Buffers move to the audio thread through a command queue, and the buffer a new
one displaces travels back through a second queue so the control thread frees it
only once the audio thread is certainly done with it. Freeing directly would
pull memory out from under a callback mid-read.

Twelve slots, eight simultaneous voices, per-slot volume and looping.
Retriggering a slot restarts it instead of layering a second copy.

## KurarinPresets

One `Codable` struct holds every parameter, and it is the only contract between
the UI, persistence and the DSP — so adding a control means touching one
declaration rather than three that can drift apart. Decoding tolerates missing
keys, so presets written by an older build keep loading.

Built-ins (Neutral, Child, Deep Male, Female, Robot, Radio, Monster, Underwater)
are compiled in with fixed UUIDs so a user's choice survives an upgrade, and are
read-only: editing one saves a copy. They are compiled in rather than shipped as
bundle resources, as the design sketch had them: a starting point that cannot
fail to load is worth more than one that can be edited in place, and the app
bundle is assembled by hand here rather than by Xcode. User presets are one JSON file each in
`~/Library/Application Support/Kurarin/presets`, so a corrupt write costs one
preset rather than the library.

## KurarinApp

SwiftUI: `MenuBarExtra` for the things you need mid-game, one `Window` for
setup. Global shortcuts use Carbon's `RegisterEventHotKey`, which needs no
accessibility permission and works while a game holds the keyboard.

The level meters live in the window and not in the menu, which the design
sketch asked for. A `MenuBarExtra` in menu style hosts menu items, not
arbitrary views, and a meter that renders once when the menu opens and then
sits still is worse than no meter. Moving the whole menu to window style to
gain one would cost the quick toggles their menu behaviour.

Two pieces of state hygiene worth knowing about:

- The engine stops on `NSApplication.willTerminateNotification`, not only from
  the Quit menu item, and the displaced default input device is written to disk
  so a run that ends in a crash is undone at the next launch. Leaving the system
  input pointed at a silent virtual device breaks the microphone for every other
  app on the machine.
- A device-list listener catches the microphone or the monitoring output being
  unplugged and restarts the engine on the system defaults.

## Failure handling

| Situation | Behaviour |
|---|---|
| Driver not installed | Detected at start; instructions shown, everything else disabled |
| Recording permission refused | System capture disabled, voice and soundboard unaffected |
| Selected microphone unplugged | Engine restarts on the default input, message shown |
| Aggregate device fails to build | Engine stops with an error. No half-running state |
| Sample rate mismatch | Aggregate is asked for 48 kHz, otherwise follows the device |
| Corrupt soundboard file | Rejected at load, marked on the slot; never reaches the audio thread |
| App killed | Driver returns to silence; system audio unaffected |

## Testing

`KurarinDSP`, `KurarinPresets` and `KurarinSoundboard` are covered by `make
test`: synthetic signals in, measured pitch, level, finiteness and range out;
serialization round-trips; decode results.

`KurarinEngine` and the driver need real hardware and a person. See
[manual-testing.md](manual-testing.md) (Korean).

## Building

No Xcode project. The `Makefile` compiles the driver bundle with clang and
assembles `swift build` output into an `.app`, so a contributor with only the
command line tools can build everything and CI can check it.

Both products are ad-hoc signed (`codesign --sign -`). That is enough for a
locally built HAL plug-in; distributing a signed and notarised build is a
separate piece of work that has not been done.
