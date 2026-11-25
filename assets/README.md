# Model assets (CC0)
With Python 3 and Node.js 22 installed, run `python tools/fetch_assets.py` before opening the project. The workflow does this automatically. The facility models are converted using glTF Transform's dequantize command because the original files require an extension not supported by Godot.
- Facility and animated unit: https://3dassets.dev/packs/self-storage-facility-and-loading-bay — CC0 1.0, AI-assisted per creator disclosure. Starter scene is static.
- Rogue: https://github.com/KayKit-Game-Assets/KayKit-Character-Pack-Adventures-1.0 — Kay Lousberg, CC0 1.0, rigged and animated. Pinned to commit 672074b73ba276876a19e8816ecdc5241817ab47.

- Sendagaya Shino: https://vroid.pixiv.help/hc/en-us/articles/360013482714-Sendagaya-Shino — Pixiv VRoid Studio official CC0 model. Original VRM 0.x from https://github.com/madjin/vrm-samples pinned to e16eb187100149a315ad92c3c9968f1d5baa6c7d. The linked VRoid Hub edition is VRM 1.0; the build uses the older freely downloadable original of the same character. Import uses standard glTF materials, without the VRM MToon shader or spring-bone physics. Existing KayKit animations are retargeted at runtime.
