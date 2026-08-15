# Manual test checklist

Routing, the driver and anything involving another application need real
hardware and a person. Everything below is what `make test` cannot tell you.

Run this after installing the driver on a clean machine, and again before
tagging a release. Note the macOS version you ran it on.

## 0. Driver loads

The largest unverified risk in the project: an unsigned HAL plug-in has to be
accepted by `coreaudiod`.

- [ ] `make driver` succeeds and produces `build/Kurarin.driver`
- [ ] `sudo ./scripts/install-driver.sh` reports **Kurarin Microphone is present**
- [ ] `Kurarin Microphone` appears in System Settings ▸ Sound ▸ Input
- [ ] It also appears in Audio MIDI Setup as a 2-in / 2-out device
- [ ] With the app **not** running, recording from it produces silence, not noise
- [ ] `log show --last 2m --predicate 'process == "coreaudiod"' | grep -i kurarin`
      shows no errors
- [ ] `sudo ./scripts/uninstall-driver.sh` removes it cleanly, then reinstall

## 1. Sound gets through

- [ ] Launch the app; the menu bar icon appears
- [ ] Devices tab lists the real microphones, and does **not** offer
      Kurarin Microphone as an input
- [ ] Press Start. macOS asks for microphone permission the first time
- [ ] The **In** meter moves when you speak
- [ ] QuickTime ▸ New Audio Recording ▸ Kurarin Microphone records your voice
- [ ] Discord ▸ Voice settings ▸ Kurarin Microphone: the input bar moves, and a
      friend or a second account hears you
- [ ] Roblox with *Make Kurarin the system default microphone* on: voice chat
      picks it up
- [ ] Stop. The system default input returns to what it was before

## 2. Voice

- [ ] Effect off sounds like the plain microphone
- [ ] Child, Deep Male, Female, Robot, Radio, Monster, Underwater each sound
      distinct and none of them clip or crackle
- [ ] Pitch alone changes how high the voice sits without changing the
      apparent size of the speaker
- [ ] Formant alone changes the apparent size without changing the note
- [ ] Dragging pitch and formant while speaking produces no clicks
- [ ] Fricatives ("s", "sh", "f") stay crisp rather than buzzing
- [ ] Switching the latency mode restarts the engine and audio returns
- [ ] Editing a built-in preset and saving creates a copy; the built-in is intact
- [ ] Saved presets survive a relaunch

## 3. Soundboard

- [ ] Dropping a file onto a tile assigns it; **Choose…** does the same
- [ ] Play is heard by the far end and in your own monitoring
- [ ] Volume changes are audible while a looping sample plays
- [ ] Loop repeats seamlessly; Stop ends it
- [ ] Triggering the same slot repeatedly restarts it instead of piling up
- [ ] Several slots at once do not clip (watch the **Out** meter)
- [ ] A non-audio file, or a file longer than two minutes, is refused with a
      message on the tile rather than a crash
- [ ] Assigned slots survive a relaunch

## 4. System audio

- [ ] Turning capture on prompts for audio recording permission
- [ ] **Everything**: music playing on the machine reaches the far end
- [ ] The music still plays normally in your own headphones, and the volume keys
      still work
- [ ] You do **not** hear an echo of yourself or a feedback howl
- [ ] **Chosen apps**: the list shows playing apps with names and icons, and
      Kurarin is not in it
- [ ] Only the ticked apps are shared
- [ ] Shared sound level changes what the far end hears
- [ ] Refusing the permission leaves the voice and soundboard working

## 5. Shortcuts

- [ ] Defaults work while another app is focused: F1 mute, F2 effect,
      F3/F4 preset, F5 stop sounds
- [ ] Clicking a binding and pressing a combination records it
- [ ] A bare letter key is refused; a letter with a modifier is accepted
- [ ] Escape cancels recording and leaves the old binding
- [ ] Assigning a combination that another action holds moves it
- [ ] A combination another application already owns reports that it is taken
- [ ] Bindings survive a relaunch

## 6. Living with it

- [ ] Unplug the microphone mid-session: the engine restarts on the default and
      says so
- [ ] Unplug the headphones mid-session: the same
- [ ] Change the system output while running
- [ ] Sleep and wake the machine; audio recovers
- [ ] 30 minutes of continuous use: no drift, no ticking, no dropouts, no
      creeping delay
- [ ] CPU use stays reasonable (a single core's fraction, not a whole core)
- [ ] Quit from the menu bar, from ⌘Q and from Force Quit: in every case the
      system default microphone ends up back where it started — for Force Quit,
      at the next launch
