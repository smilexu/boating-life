# Øresund local georeference

## Authority and projection

WGS84 latitude and longitude are the authoritative positions. The project converts each coordinate through the WGS84 ellipsoid into Earth-centred, Earth-fixed (ECEF), then rotates the difference from a local origin into an East-North-Up (ENU) tangent frame. This avoids selecting one national grid across the Denmark/Sweden border and keeps the conversion self-contained in GDScript.

The current origin is **55.700000° N, 12.750000° E, 0 m**. It lies in the Øresund water area near the centre of the playable region and coincides with the initial boat position. A future local-origin shift can change the `GeoReference` resource without changing the source longitude/latitude data.

| Local axis | Meaning | Godot axis |
| --- | --- | --- |
| East | metres east of the origin | +X |
| Up | metres above the origin ellipsoid position | +Y |
| North | metres north of the origin | -Z |

One Godot unit is one metre. Boat navigation remains in the same world frame, with Y for height. The local tangent plane is appropriate for this roughly 100 km regional tile; it is not a global Earth model. Recenter the local origin before extending to much larger regions.

## Region crop and geometry

The WGS84 crop is longitude 12.25°–13.22°, latitude 55.35°–56.10°. It covers the two city anchors, the Øresund crossing, Amager, Saltholm, Peberholm, and nearby shores. The offline processor densifies the crop frame before projection and clips the coastline. Because the fetched coastlines include open chains, it classifies a 15 m raster by coastline-crossing parity from the known-water map origin, dissolves the land runs, clips them to the projected crop boundary, and triangulates only triangles fully covered by land. Water holes remain outside the land mask.

The processor exports simplification tolerances of 15 m, 80 m, and 250 m for different map scales. The scene currently selects one mesh level in Inspector; runtime LOD switching is not part of this prototype.

## Reference anchors

These are display anchors, not navigation fixes or surveyed control points:

- Malmö: 55.60587° N, 13.00073° E (city reference).
- Copenhagen: 55.67605° N, 12.56883° E (Rådhuspladsen).
- Øresund Bridge: 55.57694° N, 12.82333° E (approximate bridge midpoint; the fixed link is a long crossing, not a point).

In map debug mode, the overview camera, 5 km local grid, origin marker, these anchors, their straight-line separation, and the boat's current approximate WGS84 latitude/longitude are shown together. The straight-line distance is a validation reference, not a sailing route.

## Coordinate checks

`GeoReference.geodetic_to_world()` and `GeoReference.world_to_geodetic()` use the same WGS84 ellipsoid constants. The round-trip error should be checked at the origin, both cities, the bridge anchor, and the crop corners whenever the georeference origin changes. The boat's position is converted only for display; navigation continues to use the existing Godot transform.

## Data licensing

See [`assets/geodata/README.md`](../assets/geodata/README.md) for the source, retrieval metadata, ODbL attribution, and distribution notes.
