extends Node3D
## Applies a restrained fiberglass finish to imported hull materials while
## preserving their embedded base-colour, normal, and roughness textures.

@export var warm_fiberglass_tint := Color(1.0, 0.99, 0.97, 1.0)
@export_range(0.0, 1.0, 0.01) var hull_metallic := 0.0
@export_range(0.0, 1.0, 0.01) var hull_roughness := 0.68
@export_range(0.0, 1.0, 0.01) var hull_specular := 0.32


func _ready() -> void:
	_apply_to_meshes(self)


func _apply_to_meshes(root_node: Node) -> void:
	if root_node is MeshInstance3D:
		var mesh_instance := root_node as MeshInstance3D
		if mesh_instance.mesh != null:
			for surface_index in range(mesh_instance.mesh.get_surface_count()):
				var source := mesh_instance.get_active_material(surface_index)
				if source is StandardMaterial3D:
					var adapted := (source as StandardMaterial3D).duplicate() as StandardMaterial3D
					adapted.albedo_color = adapted.albedo_color * warm_fiberglass_tint
					adapted.metallic = hull_metallic
					adapted.roughness = hull_roughness
					adapted.metallic_specular = hull_specular
					mesh_instance.set_surface_override_material(surface_index, adapted)
	for child in root_node.get_children():
		_apply_to_meshes(child)
