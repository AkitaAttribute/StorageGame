# StorageGame

Minimal Godot 4.7.1 storage-facility exploration prototype, based on the SpaceMinerGame preview build architecture.

## Run locally
1. Install Godot 4.7.1, Python 3 and Node.js 22 (with npx).
2. Run `python tools/fetch_assets.py` (on Linux use python3).
3. Open project.godot in Godot, allow imports to finish, then run.

New Game creates an independent save slot; Continue resumes the most recently saved valid slot. Autosave every two seconds, on door interaction, and when the app loses focus or pauses. Player position, facing and animated door states are stored in user://saves. There is no save-slot selection UI yet.

Windows: WASD to move; E when near an interactive shutter. Android: SpaceMinerGame's fixed lower-right joystick; context button above it, landscape orientation. Camera follows the player from above on fixed world axes.

The downloaded starter facility is static; the four additional units on its west side are independently animated with wall and door collisions. Character is KayKit Rogue, a free rigged humanoid; see assets/README.md.

## Automated builds and updates
Pushes to main and manual runs build Windows EXE, Android APK and both platform PCKs. The workflow is adapted from SpaceMinerGame's prototype/ship-builder-first-pass, using the official precompiled Windows template, Android cached development signing key, runtime checks and public preview release. The SpaceMiner-specific custom gamepad patch is not needed for this WASD prototype. The stable first autoload checks the preview manifest, validates download size and SHA-256, and activates the pack on restart. A newer complete executable or APK supersedes older installed packs. Use the full installer for engine or project configuration changes. The cache-based Android development signing key can be lost if GitHub evicts it; for durable signing, migrate to a backed-up key before distribution.

[Actions](https://github.com/AkitaAttribute/StorageGame/actions) · [Preview downloads](https://github.com/AkitaAttribute/StorageGame/releases/tag/preview)

Facility GLBs are automatically dequantized to remove the unsupported KHR_mesh_quantization extension, preserving named animations. Asset files are fetched before import rather than committed as large binaries. Exports include the imported assets and do not need an asset download on first launch.
