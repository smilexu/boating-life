class_name BoatFishingFightProfileCatalog
extends RefCounted

## Small resource lookup for the first boat-fishing fight profiles.
## This catalog is not an autoload and does not participate in trolling.

const PROFILE_PATHS := {
	"herring": "res://resources/boat_fishing/fight_profiles/herring.tres",
	"sea_trout": "res://resources/boat_fishing/fight_profiles/sea_trout.tres",
	"needlefish": "res://resources/boat_fishing/fight_profiles/needlefish.tres",
}
const GENERIC_PROFILE_PATH := "res://resources/boat_fishing/fight_profiles/generic.tres"

static var _cache: Dictionary = {}
static var _fallback_cache: Dictionary = {}
static var _warned_missing_species: Dictionary = {}


static func load_profile(species_id: String, reference_length_m: float = -1.0) -> BoatFishingFightProfile:
	if PROFILE_PATHS.has(species_id):
		if _cache.has(species_id):
			return _cache[species_id] as BoatFishingFightProfile
		var profile := ResourceLoader.load(str(PROFILE_PATHS[species_id])) as BoatFishingFightProfile
		if profile == null or not profile.is_valid_for_species(species_id):
			push_error("Invalid boat-fishing fight profile for species: %s" % species_id)
			return null
		_cache[species_id] = profile
		return profile
	if species_id.is_empty():
		return null
	if _fallback_cache.has(species_id):
		return _fallback_cache[species_id] as BoatFishingFightProfile
	var generic := ResourceLoader.load(GENERIC_PROFILE_PATH) as BoatFishingFightProfile
	if generic == null or not generic.is_valid_for_species("generic"):
		push_error("Boat-fishing generic fight profile is unavailable")
		return null
	var fallback := generic.duplicate(true) as BoatFishingFightProfile
	fallback.species_id = species_id
	if is_finite(reference_length_m) and reference_length_m > 0.0:
		fallback.size_reference_length_m = reference_length_m
	_fallback_cache[species_id] = fallback
	if not _warned_missing_species.has(species_id):
		_warned_missing_species[species_id] = true
		push_warning("Boat fishing species '%s' uses the generic fight profile; add a tuned profile when appropriate." % species_id)
	return fallback


static func get_supported_species_ids() -> PackedStringArray:
	var ids := PackedStringArray()
	for species_id in PROFILE_PATHS.keys():
		ids.append(str(species_id))
	ids.sort()
	return ids
