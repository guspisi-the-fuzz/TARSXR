# First sequential vision increment — 2026-10-15

Base: feature/xr-bench-mode, 3cdd8bb3f4e3eaf7b49ff81e730627026a2170c4.

## Behavior

Use **Ativar visão local** in the normal HUD. Camera permission is requested through the existing camera path. The rear camera takes at most one sample every 3 seconds, using the existing VoiceStillCamera and AVCapturePhotoOutput. This is controlled sequential still sampling, not a video stream. A slow operation skips opportunities rather than accumulating work. Each frame is normalized to at most 480 pixels using ReferencePhoto and reduced to an 8×8 grayscale signature on the XR. Only the latest PNG and signature are retained in memory; sequential samples are not saved to Photos or disk.

**Descrever (API paga)** is a separate explicit action. Activation alone never sends images to AI. Admission requires a frame no older than 8 seconds, no outstanding capture/analysis, a mean grayscale change of at least 12/255 relative to the last submitted frame, at least 30 seconds since the previous attempt, and fewer than 5 attempts in the current app process. Stop/start does not reset this conservative budget. Failed requests also consume an attempt and mark the submitted scene to prevent accidental retry loops. This is a visual-change heuristic, not object recognition. Lighting changes can trigger it; small objects may not.

No Mac is required. Camera acquisition, normalization and comparison run on the XR. Semantic description still uses the repository's existing NativeAIService external API and therefore requires network and may incur charges. This increment does not introduce an on-device semantic model. Existing service validation, rate limiting and text-only/no-motion reply semantics remain unchanged.

## State and lifecycle

The normal HUD exposes CAMERA state, last successful frame age, FRESH/STALE/UNAVAILABLE, paid-attempt count and descriptive errors. States include OFF, STARTING, CAPTURING, OBSERVING, DENIED, UNAVAILABLE, APP_INACTIVE, LOW_POWER and THERMAL. Age refers to the last completed capture; it is not proof of current surroundings. The native service's REFERENCE contract is intentionally preserved: sampled images are not a live safety sensor. The HUD labels an active sequence SEQUENTIAL_LOCAL.

Explicit stop, app inactivity/background, disappearing HUD, Low Power Mode and serious/critical thermal state cancel the worker and analysis, invalidate pending results and discard the retained frame. Restart requires another explicit activation. The operation reservation remains held until cancellation completes. A voice photo/selfie/one-shot description stops sequential observation, waits up to 12 seconds for the prior operation to drain, then retains the original photo behavior. Concurrent voice still requests are rejected. A 10-second capture watchdog releases a stalled photo capture after session startup; permission dialogs remain under iOS control. Network cancellation cannot undo an already billed request.

The existing DEBUG reference panel is stopped before opening. No ESP32, motor, GPIO, command routing or safety-release code was changed. There is no connection from sampled descriptions to movement commands.

## Verification

`Tests/SequentialVisionChecks.swift` exercises simulated dark/light/near-identical frame signatures with explicit timestamps: capture cadence, single-flight exclusion, frame age and future timestamp rejection, invalid signatures, scene-change threshold, API cooldown and five-attempt budget. Added to `scripts/validate-runtime-boundary.sh`.

This Linux workspace initially lacked Swift. Swift 6.0.3 was obtained for portable checks, using the installed ncursesw library through a temporary loader alias. Swift syntax parsing of the changed iOS files and `git diff --check` passed. Parsing is not an iOS type-check or build.

The unmodified validation runner passed the new suite and existing speech cleanup, logic (307), memory reasoner, mail and reconnection suites, then failed in existing YouTubeMusic.swift because Linux requires FoundationNetworking. To continue verification without changing unrelated production code, a temporary copy of that file with the Linux import and a temporary runner were used. Final results are recorded below.

## Requires macOS/Xcode and physical iPhone XR

- Build Debug simulator and Release device with the repository runner; iOS SDK type-checking has not run here.
- Run existing ReferenceCameraChecks/VoiceCameraCommandChecks and confirm photo/selfie saving and authorization paths.
- Test initial permission grant/denial/revocation, unavailable/busy camera, capture failures and interruption recovery. Confirm visible camera indicator disappears after stop, lock, app switching and voice still capture.
- Exercise rapid start/stop/start, stop during permission prompt/capture/API request, and photo requests during sampling. Confirm no overlapping sessions, late result publication or automatic restart.
- Confirm rear-camera orientation, sharpness, frame age, change filtering, text layout at XR size and accessibility sizes.
- Measure battery drain, CPU/memory, temperature and camera startup cost for 15–30 minutes. Reopening a still session each sample is a deliberate reuse tradeoff, not a measured power optimization; compare with a low-rate video session before increasing frequency.
- Test offline operation: local frames should continue; descriptions should fail visibly without retries. With authorized API access, verify one explicit tap produces at most one request and that scene/cooldown/budget limits hold. No real API calls were made during this implementation.
- Verify Low Power Mode and thermal interruption behavior on device. Resume only explicitly.

### Final portable results

PASS with the temporary Linux compatibility import: sequential vision, spoken request, generic logic (307), memory reasoner, mail, reconnection, YouTube parser, pronunciation (22), voice (167 plus loops), device clock (1022), persistent memory (218), memory trace (48), memory speech intent (228), relational memory (384), and remote runtime (32). No live model calls or hardware operations were used. Concrete Apple HTTP checks and all iOS builds remain NOT RUN. Deterministic vision tests cover the admission policy; actual UIKit normalization, camera lifecycle and cancellation integration require the iOS checks above.


## Video sampling update — 2026-10-16

This section supersedes the still-sampling acquisition described above. SequentialSessionCamera now uses AVCaptureVideoDataOutput at VGA resolution, rear camera, portrait orientation, requesting 5 fps (or the nearest supported rate). There is no movie recording, audio input or still shutter call. The existing SequentialVisionPolicy still requests at most one normalized sample every 3 seconds. Non-requested frames are discarded before conversion. A serial queue and VideoFrameGate admit one sample per request, reject duplicate timestamps, invalidate pending work on cancellation, and reject requests after close. Interruption/runtime-error notifications close the session; activation must remain explicit.

Voice photo/selfie capture remains in ReferenceCamera.swift and is unchanged. This update does not modify SequentialVision.swift (including on-device diagnostic changes), the AI API service, ESP32 or safety controls.

Tests/VideoFrameGateChecks.swift uses simulated frame timestamps for admission, duplication, invalid timestamps, cancellation and closure, and is added to the existing validation runner. The existing policy tests continue to cover cadence, age, change filtering and paid-call limits. iOS API type-checking/builds must run on the Mac.

Physical XR checks still required: no shutter sound during local video sampling; upright images when described; first startup and stop timing; sustained 3-second sample cadence; stop/restart, background, permission, interruption and thermal handling; photo/selfie after stopping video; battery and temperature compared with the still-session baseline, preferably from NOMINAL at fixed brightness and charging conditions. The first startup may still take about 9 seconds. No energy improvement is claimed without measurements.


## Local image quality — 2026-10-16

SequentialVision now measures mean luminance and Laplacian variance on a 96x96 grayscale thumbnail, locally. Initial thresholds: mean luminance below 25/255 rejects dark samples, above 240 rejects overexposed samples, sharpness variance below 60 rejects blur or low detail. These are heuristics requiring calibration, not reliable identification of motion, objects or safe paths. Flat surfaces can be rejected; noise can appear sharp.

Every acquired frame updates last-frame age, even when rejected. A rejected latest sample clears the retained analysis image, enters WAITING_QUALITY, exposes status and numerical scores, and waits for the next normally scheduled sample. It does not retain an older good scene for description or send rejected images to AI. There are no automatic extra captures, AI retries, paid calls or motor actions. A new accepted sample restores OBSERVING. The explicit description button remains necessary and existing API cooldown, budget and duplicate-scene checks remain unchanged.

Deterministic tests cover sharp texture, repeated box blur, flat surfaces, gradients, dark/overexposed texture and malformed inputs. UIKit conversion and thresholds require physical XR validation: stationary textured scene; motion; low light; white wall; quality recovery; zero paid-attempt increments for rejected frames. Check camera stop/restart and thermal state. Speech integration and the full-description UI remain separate pending work.

## Current-frame voice interaction — 2026-10-16

Base checkpoint: 0f54233 (quality filter physically confirmed by Gustavo). VoiceCameraAction now routes describe/findMel to SequentialVision.answerCurrent before the still-photo path. The existing parser and hands-free conversation pipeline already recognize those commands and speak returned text. This change reuses that path and never implicitly enables the camera. Photo/selfie saving remains on the existing still path. The reference-image test panel remains separate.

Button and voice share the same frame admission, reservation and API limits. Requests are refused with specific text for off/inactive, thermal, low power, unavailable/denied camera, missing/rejected/stale frames, work in progress, cooldown, unchanged scene and exhausted budget. No rejected request calls the vision API or falls back to a photograph. The limits apply to image description attempts; the existing natural speech service can have its own charges.

The button now says “Descrever e falar” and uses existing speech delivery while preserving the user's hands-free mode. It is disabled while another audio response is busy. A separate pending latch prevents duplicate button requests. The visual API task is owned by SequentialVision, so stop cancels both button and spoken requests, invalidates late replies and holds its operation reservation until completion. Cancellation cannot undo an already billed request. Generated text never reaches movement commands.

“Ler descrição completa” opens a scrollable, selectable view. The last successful description includes its capture time and remains readable after status/error messages change; it is historical text, not proof of present surroundings.

Software verification: new deterministic VisionDescriptionChecks exercise availability, age boundaries, invalid timestamps, rejected-quality frames and shared single-flight/cooldown/scene/budget admission. Existing sampling and quality suites are retained. Additional assertions were added to the existing DEBUG simulated audio cycle suite for preserving hands-free mode, empty output and overlapping speech. iOS syntax parsing is distinct from an iOS build; macOS/Xcode builds and the simulated audio suite require the Mac.

Physical XR verification pending: with an approved frame, ask “TARS, o que você está vendo?” and confirm spoken description with no photo sound/camera restart; try “procura a Mel” only against what is actually visible, without treating the answer as identity confirmation; read a description longer than three lines; use the button and verify listening returns; try off, poor-quality, stale, thermal, cooldown and duplicate requests; stop or background the app during analysis and confirm no late speech. Recheck photo/selfie saving. Temperature/battery endurance remains pending independently of these interaction tests.
