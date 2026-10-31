# Fishing P3.3c — Final Review

## Outcome

Implemented the near-boat path, sampled-water surface struggle, fish-following splashes, short curved lift over the stern rail, and deck catch presentation. The fishing line is thinner than the rod tip, visually differentiated by a warm amber material, curved through fixed control points, and tension-adjusted. Sea Trout and Needlefish share the same path/state machine while retaining different Resource-driven movement and surface behavior.

The display model still uses the hook-time natural length. Real catches still settle through the existing P2 API once; debug simulations still create no real PendingCatch, CatchResult, or population decrement. The five-phase duration and P2 probabilities are unchanged.

## Main changes

- Progressive retrieval: fish appears in the configured late-retrieval window, starts farther behind the boat, and approaches the stern below the sampled surface.
- Surface sequence: deterministic lateral struggle and burst response; splashes follow the fish's actual water position; Sea Trout retains breach and gill-wash.
- Lift/display: Bezier curve goes from the local water surface over the stern rail to the hull-specific deck target, followed by a short fading struggle and stable display.
- Line: 1.2 mm radius, amber contrast, three sag controls, tension-dependent sag, and a water entry between tip and fish during a catch.
- Camera: small aft focus shift over retrieval; existing O-cycle and Fight Camera lifecycle remain unchanged.

## Validation

P2, P3, P3.1, and P3.2 targeted headless tests passed. The headless editor scan and `git diff --check` passed. The editor scan reported duplicate translation UIDs in unrelated sailing docs and a shutdown ObjectDB leak; details are in `TEST_RESULTS.md`.

Forward+ visual acceptance is **NOT RUN**. Manually confirm that the fine line remains readable at the normal camera distance, that the fish's water-to-deck route clears each hull's rail without looking airborne, and that the landing pose is visible rather than occluded. No physics, weather, P2 resource, catch probability, or settlement behavior was changed.
