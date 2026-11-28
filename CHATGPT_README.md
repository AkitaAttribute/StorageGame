# StorageGame — ChatGPT development handoff

Last updated: 2026-11-27. This is the current engineering handoff for a new ChatGPT conversation, not the player-facing README. Read this file, then inspect current source and CI before changing anything. The ordinary README contains chronological notes, some superseded by later changes.

## 1. Workflow and user preferences

- Repository: https://github.com/AkitaAttribute/StorageGame ; branch main. User expects actual code changes committed to main, not only plans or code snippets. Use the connected GitHub tools when available.
- Read the current main SHA/tree and relevant source before modifying. Create a tree based on current main, commit with current SHA as parent, update main with expected SHA to avoid overwriting concurrent changes.
- Inspect GitHub Actions before claiming success. If user says "Build failed", get actual failed job logs first, fix the root cause, retain meaningful regression tests, then check the new workflow. Do not simply lower an assertion to get a green build. Be explicit when queued/in progress versus successful.
- CI is the usual executable test environment. Do not claim local Godot execution or visual verification unless actually performed. Headless pass does not prove an animation looks human.
- User tests Android builds frequently using the in-game updater. Preserve existing working features and movement feel, especially when a narrowly scoped animation issue is reported.
- User prefers concise, professional responses, no emojis, no needless follow-up questions, clean links. Avoid repeatedly adjusting arbitrary angles without measuring the real mesh or investigating animation/retargeting issues.
- Research requests mean inspect credible online technical sources, actual open-source implementations and available game animation resources. Separate verified facts from architectural inspiration; do not imply we inspected unavailable proprietary files.
- This handoff is intentionally a documentation-only change; no code fix from the interrupted Build 49 investigation has been committed. A later assistant should resume that issue.

## 2. Immediate priority: Build 49 failure and resting arm quality

**Latest known successful playable build:** 48 / v0.1.48, commit 30b5b1457e883677b7ceb6b2c7725d6e9b3f9852, run https://github.com/AkitaAttribute/StorageGame/actions/runs/46025022344 .

**Latest code commit before this handoff:** 757b40490b8ef93877fc15afed069fd2cc5e2cdf, Build 49 / v0.1.49, run https://github.com/AkitaAttribute/StorageGame/actions/runs/46025849392 . Failed game/save-state smoke test, job 140596928860. Import and compile succeeded.

Exact useful logs:
```
SECONDARY_COLLISION hair=63 skirt=12 skirt_width=0.22828517031157 surface_samples=158 torso_samples=766
ARM_SWING left degrees=32.4379639146326
ARM_SWING right degrees=31.3530274286151
FK_IDLE wrist_deviation=0.0 deformed_clearance_overlap=0.0 skirt_compression=0.0 abduction=42.4185752832758 torso_overlap=0.0145794594318
ERROR: Resting arm intersects torso collision surface
```

The failing assertion in scripts/main.gd _smoke requires nonempty torso samples and idle_torso_overlap <= 0.008 m. Do not weaken this threshold to hide the issue. The current solver is pushing the arms out to 42 degrees and still reporting ~14.6 mm overlap. This is a regression and would bring back the unwanted "expecting a hug" posture.

### User's actual visual feedback, in order
1. Initially hands passed through skirt at rest, hair passed through body; walking backwards/sideways needed natural movement.
2. Hair became better. Arms had rough T/A-pose and barely moved. Sideways locomotion shuffled and did not turn hips promptly.
3. After turns and arm adjustments, arms were too close, hand movement robotic, fingers still passed through skirt. Eight carry directions caused poor sidesteps and jittery diagonals.
4. Carrying movement was improved by using forward/backward only with hysteresis and body turning; user explicitly said carrying walking is fine apart from the resting/free hand. Do not undo that.
5. User requested research into how established games handle believable characters, including male/female upper-body posture and Deadlock modding/rigging. Current AnimGraph-inspired prepared arm streams improved movement overall; user explicitly said movement is better.
6. Build 47 screenshot: idle arms too far from torso, "looks like they're expecting a hug." User wants arms nearer hips; actual hand/skirt contact should deform the skirt just as hair rests against body.
7. Build 48 screenshot: arms much closer, but user says worse: elbows appear to enter torso. Build 49 added torso collision but FAILED as above. Latest user report before handoff: "Build failed."

Desired result: relaxed non-symmetrical-looking human stance, shoulders not held out like A-pose, natural elbow flexion, palms/fingers relaxed, arms not intersecting torso or skirt. Hands should be able to touch/compress skirt and skirt recover. Preserve current hair and approved walking/carrying behavior. No need to rework legs or camera again unless asked.

### Diagnosis and suggested next investigation (NOT committed or verified)
- Current torso surface samples are selected by >=65% hips/spine/chest/upperChest skin influence, within shoulder width +25 mm, vertical range pelvis-80 mm to shoulder+15 mm. This may include shoulder/sleeve attachment or waistband that should not be treated as hard body geometry. It is not yet proven which samples cause the remaining overlap.
- Current capsules use fixed 35 mm upper arm and 30 mm forearm radii, plus 8 mm margin, plus 10 mm tolerance in y/z. These may be oversized for Shino. Measure actual limb radii from arm-weighted vertices at each relevant segment rather than assuming thickness.
- arm_body_overlap checks forearm at fraction 0 (the elbow pivot) as well as the upper-arm endpoint. Rotating the forearm cannot move its pivot, so this can cause futile correction. Assign elbow clearance to the upper arm and test the forearm downstream.
- The interrupted candidate fix would select more strongly torso-weighted vertices, exclude shoulder/sleeve/waist attachments carefully, estimate upper/forearm thickness from mesh skinning, avoid double-testing elbow, and reduce maximum correction. This was NOT applied. Do not assume filtering is automatically correct: inspect which body surfaces are excluded and log sample positions, joint centers, radii, side signs, actual contacts. The aim is actual collision clearance with a modest shoulder angle, not just a passing metric.
- Verify skinning transforms against Godot Skin bind poses and mesh-to-skeleton transform. Current cached sample formula uses bone global pose * inverse bone global rest, and may differ from actual imported skin binds. If needed use skin.get_bind_pose(bind) and the proper mesh/skeleton coordinate transform. Compare rest and posed sampled geometry.
- Audit whether visual-space x sign matches rig.target_basis and whether a supposed outward rotation actually increases elbow distance from the torso. Confirm a unit test on a known point before changing limits.
- Consider computing a character-specific relaxed idle pose offline from body/arm mesh envelopes, solving shoulder/elbow jointly with a small outward bias, instead of stacking runtime corrections. Then run hair/cloth contact after the pose and use bounded, local corrections. Don't let body and skirt passes fight one another.
- Add useful numerical tests for shoulder angle, elbow/forearm actual clearance, hand/skirt contact and deformation, no significant clipping, and transition smoothness. Test full idle cycle and actual gameplay order (torso limits -> arm layer -> foot correction -> object aim -> secondary contact). Add front/side visual comparison if rendering is actually available. Do not claim the headless numbers prove visual quality.
- For larger improvements, evaluate proper VRM or Godot secondary-motion tools, or offline authored/retargeted motion capture on Shino. Avoid another elaborate solver without a way to verify it.

## 3. Current character architecture

### Asset pipeline
- Godot 4.7.1, GL Compatibility renderer. Python 3, Node.js 22/npx for assets. Run python tools/fetch_assets.py before Godot import. Assets fetched/pinned with size/hash checks; large GLBs are not tracked.
- Visible avatar is CC0 VRoid Sendagaya Shino, VRM 0.x from madjin/vrm-samples pinned commit e16eb187100149a315ad92c3c9968f1d5baa6c7d. VRM conversion preserves glTF skin/mesh/morphs, renames humanoid bones VRM_<key>, tags secondary hair/skirt bones SEC_HAIR_<id> and SEC_SKIRT_<id>, strips unsupported VRM extension. Standard glTF fallback materials, not full MToon.
- Hidden forward/idle donor: Quaternius UAL1 mannequin from toonlab commit 2e354c52e5539e33fb3d8f339645b47e1ac937ca (locomotion.glb).
- Hidden directional donor: Quaternius UAL2 CC0 pinned tilakpatell/tilakverse-assets commit 85064399bbdacc0e8cc50807179490314bc4ff1c. Build prunes to eight in-place Walk_* clips. Godot can remove Loop suffix at import; normalized exact names handle it. Normal movement now uses forward only; carry uses backward too. Do not reenable lateral/diagonal clips merely because imported.
- See tools/fetch_assets.py and assets/README.md for exact source URLs, credits, checksums and conversion.

### Rig code and runtime order
- scripts/humanoid_retarget.gd: maps source humanoid aliases to explicit VRM keys, aligns left-right axes, transfers source global rest-relative rotation in common character coordinates, compensates differing limb rest directions; builds target global bases in hierarchy order. aim_arm_bone aligns a segment via quaternion and converts to parent's local basis. apply_force_pose aims right arm at held object, using upper/lower arm separately. No finger source mapping; natural_gait sets finger curl.
- scripts/main.gd: player setup, input, movement, camera, animator phase synchronization, save, HUD, smoke tests. AnimationPlayer manual processing. animate_directional selects forward walk/idle or backward carry, crossfades target bones over 0.12 s preserving normalized phase. Normal walking turns toward travel via angle_difference/wrapf, maximum 420 deg/s, response 12; translation reduced on large turns, straight speed 3.4 m/s. No normal backpedal exception.
- Holding: two gait clips (forward/backward) + turn toward travel within 65 degrees of object facing. carry_reverse_mode hysteresis enters backward at dot < -0.40, exits at >=0.05. Hold target smoothing exp(-16*delta), right arm aim overlay. User approved this behavior.
- scripts/natural_gait.gd: authored base first; bounded torso pitch/roll/yaw, terrain foot IK, support contact hysteresis, relaxed fingers. Foot contact from donor gait, ground ray, release on turning/lift/horizontal error/reach/crossing centerline. No full procedural leg gait. Limit torso before arm layer. Avatar ground offset small.
- Current free-arm layer: setup_hand_geometry finds VRM finger joints, calculates anatomical palm basis and curls fingers; calibrate_arm_pose builds arm_neutral (walking) and idle_neutral. prepare_arm_clip samples each donor at 48 evenly spaced phases, uses mean local pose per bone, transfers motion to target neutral, bakes/smooths walking clearance, idle intentionally does not bake skirt clearance. Runtime clip_arm_pose interpolates adjacent keyframes; keep_arms_clear blends state changes over 0.20 s and excludes held right arm. No world-axis wrist reorientation every frame. Walking arms ~31–32 degrees sagittal swing in last tests.
- scripts/secondary_collision.gd: bone-based hair/cloth. Hair uses source chain bones and capsules on torso/neck/upper arms; damped return to rest, limited segment rotation. User likes hair improvement. Skirt has 12 tagged bones; cache 158 actual skirt skin-weighted samples, compute live positions, compare wrist/finger points near matching y/z; compress garment inward up to 65 mm with waist taper and thigh guard, return at 0.20 m/s. Residual contact abducts free arm at most 22 deg, gradually releases. Build 49 adds torso_samples (766), arm_body_overlap, solve_arm_torso before hair/skirt solve. This is not full cloth physics.
- Keep dependencies and phase order: base clip -> torso limit -> masked arm layer -> leg grounding -> holding aim overlay -> secondary collision. No per-frame cumulative edits; base animation resets mapped bones each tick, secondary bones restore/rest separately.
- Current idle_neutral arm directions at Build 49: upper (side*0.15,-1,-0.025), lower (side*0.10,-1,0.13). Walking: upper (side*0.30,-1,-0.025), lower (side*0.23,-1,0.16). These are tuning defaults, not measured human anatomy. Build 48 was upper 0.075 and lower 0.05, visually elbow clipping. Do not just increase abduction globally.

### Research and references
- Human gait: https://pubmed.ncbi.nlm.nih.gov/25548119/ ; https://pmc.ncbi.nlm.nih.gov/articles/PMC7440644/ ; https://pmc.ncbi.nlm.nih.gov/articles/PMC2817299/ ; https://pubmed.ncbi.nlm.nih.gov/31289110/ . Population averages are not mandatory female poses. Natural swing involves coordinated trunk/pelvis and relaxed arm/elbow movement.
- Godot contact/IK examples https://github.com/Johnz86/locomotion-godot and https://github.com/fl-wxiao/godot-rigkit ; TPS directional animation graph https://github.com/godotengine/tps-demo .
- https://docs.godotengine.org/en/stable/tutorials/assets_pipeline/retargeting_3d_skeletons.html ; https://dev.epicgames.com/documentation/en-us/unreal-engine/ik-rig-animation-retargeting-in-unreal-engine ; https://dev.epicgames.com/documentation/en-us/unreal-engine/animation-in-lyra-sample-game-in-unreal-engine .
- User specifically suggested Deadlock. Prior discussion examined public modding documentation/AnimGraph concepts (separate clips, body masks, additive aim); no actual Valve hero graphs or animation files were acquired or inspected. Current implementation uses existing CC0 Quaternius animation data, NOT Valve assets. Candidate further research: inspect real modding tools/assets if accessible, e.g. Valve Resource Format, source2viewer; verify claims directly. Motion capture alternative: https://mocap.cs.cmu.edu/ .
- Prior technical direction: authored motion + masked layers + limited contact correction is preferred over rigid independently scripted joints. Do not regress to procedural gait or eight-way carry.

## 4. Other established systems (preserve)

### Movement, camera, saves, facility
- Godot project based on SpaceMinerGame update/build architecture. New Game and Continue, independent save slots internally; no selection UI yet. Autosaves every 2 s and focus/pause; save_store.gd stores user://saves.
- Windows WASD, mouse moves camera without clicking, Escape capture/release, E use, G grab. Android landscape fixed lower-right joystick, swipe empty region to orbit, contextual Open/Close and Grab/Drop above joystick. User expects no unrequested control redesign.
- Third-person camera normally 3 m orbit, full vertical -89.5..89.5 degrees. Sphere sweep/ray compress instantly against world/props, smooth return. Player and invisible prop-only boundaries excluded. Small stairs/bumps traversable 0.44 m max via collision-tested step-up and floor snap; no extra horizontal speed; smoothed visual height.
- Facility GLBs from https://3dassets.dev/packs/self-storage-facility-and-loading-bay ; dequantize KHR_mesh_quantization. Four west swing-door units plus procedural rollup_00 near (-13,0,-7.8), roof ~2.650103. rollup_unit.gd segmented curtain winds into overhead drum, moving collider, gently pushes player while closing, saved state.

### Household props and physics
- scripts/household_props.gd: fridge, Poly Haven textured metal office desk and flathead screwdriver, Khronos BoomBox. Props placed unobstructed on floor near player, saved. No debug locator. Dot crosshair, golden highlight within 2.1 m of shoulder, ray excludes player and held prop where appropriate. G / mobile Grab toggle.
- Held items remain dynamic RigidBody3D, gravity off, rotation locked, CCD; target velocity capped 14 m/s, acceleration-limited ~48 m/s² and collision-aware, no teleporting through solids. Drop restores gravity, rotation and actual motion momentum.
- Untouched bodies start frozen; collision activation delayed to avoid startup launch. Solid ground slab and prop-only boundary layer 8. Invalid escaped/extreme-speed items recover to clear floor. Layout version 4 migrates untouched old props; don't erase moved items.
- Fridge rebuilt from measured reference size ~0.686 x 1.75 x 0.689 m, 65 kg, hollow cabinet, freezer and fridge compartments, shelves, independent right-hinged doors, visible metal hinge assembly and center seam seal. scripts/interactive_fridge.gd, hinged_panel.gd. Door ray hit shape metadata; E/use opens/closes and G still grabs fridge. Door actions while holding other object supported.
- Hinge speed 120 deg/s, target 105 deg opening. Compound RigidBody3D panel collider rotates about actual hinge. Predictive contact impulse based on swept local contact point velocity and effective contact mass, gravity compensation. Push loose item first, cabinet if fixed obstruction. Only substantial existing penetration pauses. User wants face-down fridge to open smoothly lifting/tilting naturally; prior slow force ramp unacceptable. Build 38 passed face-down regression (<~1.05 s), but visual success not independently confirmed. Do not replace with horizontal translation or direct teleport.
- scripts/storage_contents.gd: event-driven containment, no polling. On fully_closed signal scan actual item mesh vertex envelope in cabinet-local coords, allow small contact tolerance, regardless of rest/velocity; release grab if held. Reparent original item under StorageContents with local transform, disable body processing and collision/remove from physics space, freeze. Child transforms follow automatically. At accessible (~70 deg) restore parent/world transform/physics and inherit cabinet velocity including angular tangential component. Save container ID, compartment, local transform; restore after container. Separate compartments, not nested containers. No per-frame containment or cargo sync.
- scripts/stored_outline.gd: cyan actual enclosed item silhouette through cabinet, NOT cabinet outline. Shared-world SubViewport mask, dedicated render layer, clone item mesh, screen-space edge shader. Membership updated on storage signals; camera sync each frame. Only secured contents outlined. Original open-container outline behavior superseded.

## 5. Build / updater / testing

- .github/workflows/build.yml runs on main push/manual. Official Godot 4.7.1 Linux editor + templates, Python + Node 22, Android Java 17. Import, startup, updater transaction and gameplay smoke before exports. Windows EXE, Android APK, both platform PCKs, public preview release. Build number = GitHub Actions run_number + 1, version 0.1.<build>. Do not change project.godot config/version baseline 0.1.0; CI stamps it. Android signing identity cached; full installer required for engine/project settings changes.
- scripts/update_manager.gd stable first autoload mounts selected PCK, scripts/update_bridge.gd supports legacy full install, scripts/update_runtime.gd patchable UI/updater. New binary ignores older installed pack. Verified size, magic, SHA-256; atomically activate metadata, retain previous pack. One click download/install, success countdown 3s then Windows restarts/Android exits. Failures stay open. Publish immutable build/run/attempt PCK names, verify anonymously downloaded bytes, manifest last. No extra APK needed for ordinary code/PCK updates; user confirmed one-click working.
- https://github.com/AkitaAttribute/StorageGame/actions ; https://github.com/AkitaAttribute/StorageGame/releases/tag/preview .
- Local commands if available:
```sh
python3 tools/fetch_assets.py
godot --headless --path . --import
godot --headless --path . --script res://tools/updater_smoke.gd
godot --headless --path . -- --storage-smoke
```
- CI timeouts updater 30s/game 45s. Logs grep for errors even when exit code 0. _smoke in main.gd tests retarget, clips, arm swing, wrist stability, shoulder/torso, skirt, carry hysteresis, prop placement/physics, doors, storage, saves and camera. Beware duplicate variable names in same GDScript function and Variant type inference errors. Use explicit typed locals where needed. Do not remove tests. When changing pose pipeline, update regression to simulate same runtime operations, not incompatible pre-deformation geometry.
- Recent history: Build 38 continuous hinge pass; 39 directional clips lookup failed, 40 import name normalization passed; 41 relaxed arms and travel turning passed; 42 biomechanics/shortest arc pass; 43 anatomy hands + 2-direction carry pass; 44 duplicate right_arm declaration fail, 45 fixed pass; 46 prepared arm states fail due test omitting torso limit, 47 fixed test + 10mm baked margin pass; 48 skirt-yield idle pass but visually elbows intersect torso; 49 torso solver fail (current priority).

## 6. GitHub connector operational notes

Use actual available tools; names/schema may change across chats. Previous working pattern (JavaScript orchestration, not shell):
```js
const repo = "AkitaAttribute/StorageGame";
const b = JSON.parse((await tools.mcp__GitHub__fetch({
  url: "https://api.github.com/repos/" + repo + "/branches/main"
})).result.content);
const path = "scripts/main.gd";
const content = (await tools.mcp__GitHub__fetch_file({
  repository_full_name: repo, path, ref: b.commit.sha
})).result.content;
// Make guarded replacements; fail if expected old text is missing.
const t = await tools.mcp__GitHub__create_tree({
  repository_full_name: repo, base_tree_sha: b.commit.commit.tree.sha,
  tree_elements: [{path, mode:"100644", type:"blob", content: revisedContent}]
});
const c = await tools.mcp__GitHub__create_commit({
  repository_full_name:repo, tree_sha:t.result.sha,
  parent_sha:b.commit.sha, message:"Describe actual change"
});
text(await tools.mcp__GitHub__update_ref({
  repository_full_name:repo, branch_name:"main",
  sha:c.result.sha, expected_sha:b.commit.sha
}));
```
- Workflow status: fetch https://api.github.com/repos/AkitaAttribute/StorageGame/actions/runs?per_page=5 , inspect workflow_runs head_sha, run_number, conclusion, html_url. Jobs: /actions/runs/<run_id>/jobs . Failure log: mcp__GitHub__fetch_workflow_job_logs({repo_full_name:repo,job_id:job.id}).result.content . Filter for SCRIPT ERROR, Parse Error, Compile Error, ERROR, FK_IDLE, ARM_SWING, ARM_CLIP, SECONDARY_COLLISION, HINGE_FACE_DOWN, STORAGE_SMOKE_PASS. Use full surrounding context where needed.
- Do not promise background work. If still queued, state that and link run. If practical follow to actual result in current turn; keep user updated if extended.
- This document describes source at the specified failed Build 49 commit, not any later change. Refresh main and CI when resuming.

## 7. Suggested first message in new chat

"Continue StorageGame in AkitaAttribute/StorageGame. Read CHATGPT_README.md and current main, inspect the latest GitHub Actions failure, fix resting elbow/torso contact without restoring the A-pose. Preserve the improved walking and carrying behavior. Commit fixes to main and report the actual build status."

## Follow-up to Build 49
The next code revision corrects the torso proxy selection (exclude blended sleeve/armhole attachments), measures limb radius from arm-weighted mesh vertices, assigns elbow clearance to the upper arm rather than testing an immovable pivot twice, uses measured correction leverage, and measures torso clearance after the final skirt contact pass. The 8 mm torso and 25 mm skirt regression limits remain unchanged. The idle baseline has a slight elbow-back bias. Verify the next workflow and actual front/side pose before considering the visual issue fixed.

## Mandatory build verification (user directive, 2026-11-27)
Until explicitly told otherwise, every code push must be followed through GitHub Actions to a successful build before reporting completion. If a run fails, inspect actual logs, fix the cause, push and verify the replacement run in the same conversation. Do not stop at queued/in progress. If a genuine tool/time/access blocker prevents this, disclose it and do not claim success. Build 50 failed at import because GDScript could not infer the type of key and child from Variant loop values; the next revision explicitly types these strings. Keep collision regressions intact.

Build 54 had adequate live arm samples but failed the same torso test. The next revision retains connected torso mesh triangles and evaluates exact lateral surface intersections in y/z, excludes torso-owned armhole vertices, and searches bounded lateral/sagittal shoulder corrections. Existing 8 mm clearance threshold is unchanged; verify complete CI and visual pose.

## Build 56 runtime regression and recovery
User reported extreme lag and return to T-pose in Build 56 despite green CI. Runtime torso triangle skinning, repeated shoulder candidate searches and forced skeleton updates are suspected causes; the previous automated checks missed gameplay performance and visual quality. Recovery restores the exact three rig/game scripts from Build 48 (30b5b1457e883677b7ceb6b2c7725d6e9b3f9852), including its prior regression suite. This deliberately removes the experimental torso solver and its solver-specific assertions, not a relaxation of a retained solver. Build 48 still had visually apparent elbow/torso clipping; do not claim that is resolved. Keep approved walking/carrying and hair/skirt behavior. Future torso work should use offline authored/calibrated poses or strictly bounded inexpensive proxy collision, with gameplay-frame CPU budget and visual verification before further changes. Do not reintroduce per-frame mesh triangle search.

## Build 57 user verification and next idle correction
User confirmed lag is gone; screenshot still shows inward/concave elbows. Next revision changes idle calibration only (upper lateral slope 0.20, slight back bias, lower nearly vertical with forward flexion), constrains upper arm direction in prepared idle keyframes only, and preserves wrist goal when adjusting elbows with a bounded forearm slope. Walking/carry clips, hair and skirt runtime code unchanged. Regression checks signed bilateral idle shoulder angle (5–30 degrees), not just absolute maximum. This is a modest pose adjustment, not proof of mesh clearance; verify visually. No per-frame torso search.

## Build 58 feedback and next arm revision
User reports right elbow still concave, left better but jerking during idle, walking arms still T/A-pose. Identified whole-skirt rectangular bake (up to 32 degrees extra abduction) and discontinuous per-tick skirt arm correction; previous walking test measured only sagittal swing before secondary collision. Replace with avatar rest-axis/flexion-plane orientation, source-timed sagittal motion, bounded lateral elbow and forward forearm flexion, circular smoothing of baked clips, smooth local fabric proximity and bounded low-pass arm contact. Test final walking upper/forearm spread and idle frame-to-frame global rotation. No runtime torso mesh searches. This changes free-arm pose only; held right aim remains excluded. Visual verification still needed.

## Build 59 user verification and subsequent changes
User explicitly approved walking animation. Reports hair clips through body again and right holding arm crosses torso when looking left. Preserve prepared locomotion clips unchanged. Carry overlay now uses avatar-local target side (55 mm center hysteresis), two independent hand weights, base clip on both arms, and same-side forward-clamped aiming during handoff. Prop physics and facing logic unchanged. Skirt excludes both hands during brief crossover. Hair now runs after final arms/skirt, uses broader torso and shoulder capsules and forearm proxies, three samples per link plus terminal tip approximation, max one bounded rotation per hair bone. No runtime mesh search. Added synthetic midpoint collision and bilateral hand selection/aim tests; actual visual hair clearance still needs testing.

## Build 60 feedback and historical hair restoration
User reports hair looks like a single glob pushed by body motion; explicitly requests historical comparison. Prior chat records “Hair is better” after Build 40 (69dd4ca55d76cbb6dc3c1ebc89e51c034e726be7). Compared actual files: original five hair capsule definitions and endpoint-only chain loop were unchanged from 432bad6 through Build 59, and the VRM asset conversion and retarget aim implementation stayed unchanged. Build 60 expanded to nine proxies, segment samples and terminal rotation; revert exactly the hair capsule definitions, endpoint loop, damping and pre-skirt ordering to Build 40, retaining current skirt and carry side-mask logic. Replace removed midpoint-specific test with original five-proxy and localized endpoint behavior assertions. Walking and carrying code untouched. Earlier torso limits changed from overall 5/8-degree to per-axis 5/8-degree pitch/roll and 20-degree yaw, which may explain prior clipping but do not revert this without user approval because walking is now approved. No claim of visual success before user tests.

## Build 61 feedback: shoulder/sleeve clipping specifically
User screenshot and clarification identify hair entering white sleeves at the shoulders, not primarily torso. Original 65 mm upper-arm capsule follows joint centers, not fabric. Add a one-time measured proximal sleeve radius per side from shoulder/upper-arm weighted rest mesh samples (92nd percentile plus 6 mm, bounded), two short sleeve-only capsules following current arm poses, and an extra contact sample at 65% of each existing hair link. Preserve the original five proxies, rest damping and per-chain rotation, no terminal bone rotations or broad torso expansion. Hair now runs after final skirt arm correction. Tests require actual mesh sample counts, local sleeve contact and untouched clear links. Visual verification remains necessary; no changes to approved gait or hand-switching code.

## Modular wardrobe prototype
User requested independently selectable tops, bottoms, and later arm/hand/face/leg/feet accessories. New `tools/wardrobe_assets.py` imports pinned CC0 Shibu uniform textures and HairSample_Male hoodie/trouser meshes into Shino GLB at build time, sharing original Body skin. Same-template variants retain Shino original geometry, differing hoodie/trouser geometry uses donor weighted bind transforms. `scripts/wardrobe.gd` defines stable slots/item IDs, visibility and persistence; Wardrobe button/V opens a side panel. Old saves default to original uniform. No animation replacement; skirt contact disabled when trousers selected. Initial fit and sleeve collision for alternate hoodie need visual verification. Existing default hairstyle and motion are unchanged. Diagnostic workflow on wardrobe-asset-inspection confirmed material layout and embedded CC0 licenses, run 46136347085.
