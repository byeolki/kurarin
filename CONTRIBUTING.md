# Contributing

Thanks for taking a look. Issues and pull requests are both welcome.

## Getting set up

```sh
xcode-select --install     # command line tools are all you need
make                       # driver + app
make test                  # DSP, preset and soundboard suites
```

There is no Xcode project on purpose: everything builds from the command line,
so CI can check it and nobody needs a particular Xcode version. `swift build`
alone is enough while working on the Swift targets; `make app` only matters when
you need a real `.app` bundle (the menu bar item needs one).

Working on the driver means reinstalling it:

```sh
make driver && sudo ./scripts/install-driver.sh
```

That restarts `coreaudiod` and interrupts audio on the whole machine for a
moment. Expect to do it often, and expect to check
`log show --last 2m --predicate 'process == "coreaudiod"'` when something does
not appear.

## Ground rules for the code

**The audio callback allocates nothing, locks nothing, and calls nothing that
might.** No `malloc`, no Swift array growth, no Objective-C messaging, no
`print`. Anything the UI needs to hand over goes through `CommandQueue` or
`ParameterSlot`; anything the UI needs to read is a plain store the UI polls. If
a change makes the audio thread touch a file, a decoder or a lock, it is the
wrong change.

`Tests/KurarinDSPTests/AllocationTests.swift` checks this rather than trusting
it, by counting heap traffic through Darwin's `malloc_logger` while the chain
runs. It needs the optimiser, so it is a separate step — `make test` runs it,
or `swift test -c release --filter AllocationTests` on its own. Run in a debug
build it skips itself, because without optimisation Swift allocates once per
loop iteration for bookkeeping release removes.

**The driver stays boring.** It runs inside `coreaudiod`, so a crash there takes
down audio for the entire machine. New behaviour belongs in the app unless it
genuinely cannot live there.

**DSP comes with tests.** `Tests/KurarinDSPTests` drives units with synthetic
signals and measures the result. A new unit should at least prove that silence
in gives silence out, that the output stays finite and bounded on noise, and
that the thing it claims to do to a signal actually happens.

**Comments explain why.** The code says what it does. A comment earns its place
by recording the reason a non-obvious choice was made, the constraint that
forced it, or the failure it prevents.

## Pull requests

- One concern per pull request.
- `make test` passes (which includes the release-mode real-time checks), and
  `make` builds both products.
- If the change touches routing, the driver or anything involving another
  application, say which items of [docs/manual-testing.md](docs/manual-testing.md) (Korean)
  you ran and on which macOS version. Those paths have no automated coverage.
- Update [docs/architecture.md](docs/architecture.md) when the design changes,
  not only the code.

## Commit messages

The convention here is a lowercase type prefix, an imperative summary, and a
body that explains the reasoning when it is not obvious:

```
fix: keep monitor and virtual device mixes separate

The monitoring output was being written the same mix as the virtual
device, so a captured app was echoed back into the headphones it was
already playing through.
```

Types in use: `feat`, `fix`, `build`, `docs`, `refactor`, `test`, `chore`.

## Reporting a bug

Audio bugs are hard to reproduce from a description alone. Please include your
macOS version and hardware, the microphone and output device, the latency mode
and preset, whether system capture was on, and — if the driver is involved —
the output of:

```sh
log show --last 5m --predicate 'process == "coreaudiod"' | grep -i kurarin
```
