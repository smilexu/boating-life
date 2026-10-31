# Fishing P3.3c.1 — Final Review

## Delivered

- The old deck landing target and over-rail landing arc are removed from both mount profiles. One temporary fish transitions from the existing surface scene into a hanging pose.
- The mouth anchor is calculated from the current bent rod tip and the per-boat `landing_min_line_length_m` (`0.45 m`). The visible line follows that same anchor. The hanging pose rotates around the mouth so the head points up and the tail down; the tail clearance adjustment samples the local WaveSampler surface and uses the configured margin.
- Hanging struggle now bends the catch mesh itself around its body center. Vertex displacement follows a smooth S profile along the fish length: head and tail move in opposite lateral directions while the middle remains close to the pivot. The bend reverses in seeded pulses for both Sea Trout and Needlefish, then returns to the imported mesh shape. The fish's inferred mouth offset follows the bend and the fishing line terminates there. Whole-body swinging is limited to a small secondary motion.
- Real settlement continues through the existing P2 contract exactly once. Only a successful `CatchResult` is shown as “Catch confirmed” and only that signal updates the session-only Last catch line. F3 simulation shows a distinct “Simulation preview” card, does not settle, and does not update Last catch.
- The result card is a `BoatHUD` CanvasLayer control, independent of the active camera. Real and simulated cards remain on-screen through the eight-second fish display and for twelve seconds after the fish is cleaned up. The session-only Last catch summary updates only for real catches and remains after the card clears. No forced Fight Camera switch was added for the result card.
- Localized English and Simplified Chinese keys cover title, length, weight, and recent catch.

## Vessel and species settings

- Starter cargo boat and Nordic 28 both use `0.45 m` minimum hanging line, `0.10 m` water-clearance margin, and a `12°` mount clearance cap.
- Sea Trout hanging profile: 4 s struggle, `0.09 m` body deformation at `2.1 Hz`, up to `4°` whole-body sway and `6°` axial twist.
- Needlefish hanging profile: 4 s struggle, `0.075 m` body deformation at `3.0 Hz`, up to `4°` whole-body sway and `7°` axial twist.
- The vertex deformation uses `ArrayMesh` dynamic vertex updates on the temporary catch model only. Imported normals are retained rather than recomputed; live lighting and silhouette quality still need visual review.

## Validation

P3.1 and P3.3c.1 Headless tests were rerun after the body-centered S-bend change and passed with `failures=0`. The S-bend test samples the deformed catch vertices for opposite head/tail movement, a centered body, reversal, and mouth-line attachment. P3, P3.2, and P2 were not rerun for this small visual-only follow-up. See [TEST_RESULTS.md](TEST_RESULTS.md) for commands and environment warnings.

Actual Forward+ visual acceptance is `NOT RUN`. The code tests do not prove the S curve reads clearly in the rendered models, that static normals shade naturally during deformation, or that the fish clears the rail/deck and remains framed on both boats. Please inspect the 0.5× and 1× simulation in the running game before treating the visual acceptance as complete. Windows runtime validation is also `NOT RUN`.

## Remaining limits

- The final hanging point uses a world-down line from the actual rod tip. If an individual boat's tip lies over a rail or deck region, the mount's rod position may require a small data adjustment; the implementation does not teleport or detach the fish to hide that collision.
- The mouth hook location is inferred at 45% of the measured model length along the existing nose-axis mapping; these GLBs do not provide an authored mouth marker. Pulse timing ratios/strengths, the 3.5 s sway decay, and card hold/fade values are fixed presentation values; struggle duration, line length, sway cap, and species sway/twist/residual values are resource-configurable.
- The GLBs have no bones or blend shapes. The temporary catch mesh is bent directly along the imported vertices and the original normals remain unchanged, so large bends could show lighting artifacts even though the silhouette moves. The amplitude is capped at `0.18 m`.
- The water clearance is a sampled point/length safety adjustment, not collision detection against boat geometry. Live inspection remains necessary.

