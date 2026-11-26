# StorageGame

Minimal Godot 4.7.1 storage-facility exploration prototype, based on the SpaceMinerGame preview build architecture.

## Run locally
1. Install Godot 4.7.1, Python 3 and Node.js 22 (with npx).
2. Run `python tools/fetch_assets.py` (on Linux use python3).
3. Open project.godot in Godot, allow imports to finish, then run.

New Game creates an independent save slot; Continue resumes the most recently saved valid slot. Autosave every two seconds, on door interaction, and when the app loses focus or pauses. Player position, facing and animated door states are stored in user://saves. There is no save-slot selection UI yet.

Windows: WASD to move; E when near an interactive shutter. Android: SpaceMinerGame's fixed lower-right joystick; context button above it, landscape orientation. Move the mouse freely (no mouse button required) on Windows or swipe an unused area of the Android screen to orbit the third-person camera horizontally and vertically. Windows captures the cursor automatically when gameplay starts; Escape releases or recaptures it. Movement is relative to the camera. Camera orientation persists in each save. The camera maintains a fixed 3.0 m orbit radius, even behind walls. The default pitch puts the camera approximately 0.84 m above the 1.7 m character's head. Walking speed is 3.4 m/s and the animation playback rate follows actual movement. Small steps and stair risers up to 0.44 m are traversable using collision-checked step-up and floor snapping.

An additional original procedural roll-up unit (rollup_00) is placed in a clear ground footprint near the existing units when possible. Its roof height matches the imported unit geometry. The segmented corrugated curtain winds around a drum inside an overhead bay, with open/close persistence and collision. See scenes/rollup_unit.tscn and scripts/rollup_unit.gd. The downloaded starter facility is static; the four additional units on its west side are independently animated with wall and door collisions. Character is Sendagaya Shino, the official CC0 VRoid sample. The invisible Quaternius Universal Animation Library mannequin supplies human-proportioned walking and idle cycles; the runtime retargeter aligns the humanoid skeletons and grounds the support foot. This first iteration uses standard glTF materials, without MToon or hair spring physics; see assets/README.md.

## Automated builds and updates
Pushes to main and manual runs build Windows EXE, Android APK and both platform PCKs. The workflow is adapted from SpaceMinerGame's prototype/ship-builder-first-pass, using the official precompiled Windows template, Android cached development signing key, runtime checks and public preview release. The SpaceMiner-specific custom gamepad patch is not needed for this WASD prototype. The stable first autoload checks the preview manifest, validates download size, PCK magic and SHA-256, and atomically activates the verified pack. After a successful install it displays success for three seconds, then automatically restarts on Windows or exits on Android (Godot's restart-on-exit API is desktop-only). Failures display an error and leave the game open, retaining the previous activation. This updater bootstrap change requires installing a new full APK/EXE once because the running autoload cannot replace its own script from a resource pack. A newer complete executable or APK supersedes older installed packs. Use the full installer for engine or project configuration changes. The cache-based Android development signing key can be lost if GitHub evicts it; for durable signing, migrate to a backed-up key before distribution.

[Actions](https://github.com/AkitaAttribute/StorageGame/actions) · [Preview downloads](https://github.com/AkitaAttribute/StorageGame/releases/tag/preview)

Facility GLBs are automatically dequantized to remove the unsupported KHR_mesh_quantization extension, preserving named animations. Asset files are fetched before import rather than committed as large binaries. Exports include the imported assets and do not need an asset download on first launch.
