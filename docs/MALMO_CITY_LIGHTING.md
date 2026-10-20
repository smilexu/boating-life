# Malmö city night lighting V1

## What is in the scene

`MalmoCityDistrict` owns a `CityLightingController` child. The existing five GLB building instances, their transforms, imported materials and source textures are unchanged. The controller duplicates each imported `BaseMaterial3D` at runtime and chains one shared window-emission shader as a `next_pass` on the duplicated material.

The five GLBs each expose one mesh/surface and one material. Their window frames are baked into the albedo atlases, so the overlay samples a separate grayscale rank mask in the same UV space. It does not add window planes to an AABB, which keeps the Turning Torso mask attached to its actual twisted facade UVs. Window groups are selected from stable, deterministic ranks; each building profile has its own pattern offset and color mix.

| Building | Evening | Late night | Main window tone |
|---|---:|---:|---|
| Turning Torso | 22.5% | 11.25% | warm 3200 K look, occasional neutral white |
| White Apartment West | 40% | 18% | warm 2800 K look |
| White Apartment East | 35% | 15% | warm 3000 K look |
| Blue Glass Apartment / office | 40% | 10% | neutral 4000 K look |
| Brick Apartment | 30% | 15% | warm 2700 K look |

These are art-directed initial ratios, not measured occupancy data. The local night state follows the existing `DayNightVisualController` sun elevation, transitioning from +2° to -6°. Late-night occupancy follows the existing `WorldTimeManager` cycle time. No second clock is created.

## Street and landmark lighting

- Eight street lamp poles and eight lamp heads are rendered as two `MultiMeshInstance3D` batches; eight additional warm-white emissive points use a third batch for far view only.
- Three warm, shadowless `OmniLight3D` lights illuminate the plaza/entrance at low range.
- Two very weak, shadowless `SpotLight3D` up-lights can help the Turning Torso silhouette.
- Physical lamp heads, poles and real lighting use the same night factor and are hidden or disabled outside the 4 km detail range. Far emissive points follow the proxy distance fade and switch off in close view.
- No per-window real lights, building geometry changes, collisions, or ocean shader changes are added.

## Far-view lighting LOD

The near window pass remains attached to the original GLB surfaces. A second,
UV-aligned emissive proxy pass is chained only while the camera is beyond the
near-view range. Its mask is generated from the same detected window groups,
expanded to 1.75 times their atlas bounds, so it reads as larger window cards
while staying on the real (including twisted) facade mesh. It does not use
building AABBs or detached floating panels.

- 0–650 m: original window detail only; far proxy pass is detached.
- 650–1300 m: near windows fade out while the broad proxy fades in.
- 1300–5000 m: proxy windows are the primary building light pattern.
- 5000–7000 m: proxy fades out.
- Turning Torso gets one weak red emissive aviation beacon near the roof.
- Turning Torso uses shared rank values for nearby 2–4 window groups; its lit-window ratio is reduced by 25%, while per-window emission is compensated to keep approximate total luminance similar and reduce isolated speckles.
- Eight warm-white far-distance light points use one `MultiMeshInstance3D` batch. They follow the proxy distance fade, stay off in close view, and add no real light sources.
- Companion-building far-proxy emission is raised to 1.6–1.7× the initial values to strengthen the city-light base layer.
- The project WorldEnvironment already has Glow enabled; proxy emission uses
  that existing effect and adds no new light sources.

The mask generator now writes both the original fine window ranks and the
expanded far-proxy masks. Regenerate with the command below; no JSON layout
metadata or runtime image-processing dependency is needed.

## F3 controls

Open the existing F3 developer panel and scroll to **Malmö 城市夜间灯光**. It has a master toggle, automatic/forced day/twilight/night preview, global window intensity, automatic or custom 0–80% window density, per-category intensity controls, contour fill, street/plaza strength, and save/reset buttons. Forced modes affect only Malmö's city-light controller; they do not change the world clock, weather, sun or moon.

`诊断：亮紫色显示窗户遮罩` temporarily shows the generated UV mask over the actual building meshes. Use it to spot atlas areas that the heuristic detector may have mistaken for windows. It is off by default and is not persisted.

Saved debug tuning is stored at `user://malmo_city_lighting.cfg`.

## Window mask generation

The checked-in masks are derived from the existing albedo atlas images using color thresholds, connected-component filtering and deterministic ranking. Regenerate them with:

```sh
python3 tools/city_lighting/generate_window_rank_masks.py
```

The generation script requires ImageMagick's `magick` command. Runtime rendering has no ImageMagick or network dependency.

Current generated selections:

| Atlas | Detected window groups | Shared occupancy clusters | Near-mask pixels |
|---|---:|---:|---:|
| Turning Torso | 2,315 | 734 | 680,164 |
| White building | 663 | 257 | 468,673 |
| Blue glass building | 144 | 102 | 18,807 |
| Brown/brick building | 556 | 280 | 215,116 |

These are heuristic masks, not hand-authored architectural annotations. Review the purple F3 mask view if later texture or model revisions change UVs or atlas colors. The mask coverage stays the same, while nearby detected windows share one stable selection rank in small clusters of up to four. Far masks expand the detected window-group bounding boxes by 1.75× to create distant emissive cards; the UV masks remain attached to the actual mesh surface.

## Water reflection and known limits

The project environment has SSR enabled and the water shader already computes screen-space/environment reflection. This change does not touch either. A distinct, stable reflection of the city window proxy pass on the water was **not confirmed**. Godot SSR may omit or inconsistently capture transparent `next_pass` emission. No water-specific hint layer was added pending a Forward+ shoreline check.

The blue-glass window detector is intentionally conservative and produces fewer selected pixels than the other masks; if those windows need stronger coverage, tune that source threshold in the generator, inspect the purple mask, regenerate only after confirming the result.
