extends RefCounted

## Seeded erosion stack for the island height field.
## A deterministic CPU stack combining shallow-water flux, particle droplets,
## multi-scale slope-aligned gullies and conservative thermal talus relaxation.
## The hydraulic stages adapt published model structures; no third-party shader
## kernels or the Rune Skovbo Johansen shader function are copied.

const WORLD_SIZE := 10000.0
const RESOLUTION := 1024
const COAST_RESOLUTION := 1024
const DROPLET_COUNT := 18000
const DROPLET_LIFETIME := 52
const OCTAVES := 5
const THERMAL_ITERATIONS := 8
const HYDRO_RESOLUTION := 256
const HYDRO_ITERATIONS := 28
const HYDRO_RAIN := 0.26
const HYDRO_FLOW_RATE := 0.14


func apply(
	base_heights: PackedFloat32Array,
	coast_sdf: PackedFloat32Array,
	seed_value: int
) -> PackedFloat32Array:
	var current := base_heights.duplicate()
	current = _apply_shallow_water_erosion(current, coast_sdf, seed_value)
	current = _apply_hydraulic_droplets(current, coast_sdf, seed_value)
	current = _apply_slope_aligned_gullies(current, coast_sdf, seed_value)
	current = _apply_thermal_relaxation(current, coast_sdf)
	return current


# Coarse shallow-water erosion inspired by grid-based hydraulic models.
# Water flux, suspended sediment and terrain are kept in separate fields so each
# simulation step reads a stable previous state and writes a deterministic next state.
func _apply_shallow_water_erosion(
	heights: PackedFloat32Array,
	coast_sdf: PackedFloat32Array,
	seed_value: int
) -> PackedFloat32Array:
	var count := HYDRO_RESOLUTION * HYDRO_RESOLUTION
	var terrain := PackedFloat32Array()
	var initial_terrain := PackedFloat32Array()
	var coast := PackedFloat32Array()
	var water := PackedFloat32Array()
	var sediment := PackedFloat32Array()
	var hardness := PackedFloat32Array()
	var rain_map := PackedFloat32Array()
	terrain.resize(count)
	initial_terrain.resize(count)
	coast.resize(count)
	water.resize(count)
	sediment.resize(count)
	hardness.resize(count)
	rain_map.resize(count)

	for y in range(HYDRO_RESOLUTION):
		var source_y := int(round(float(y) / float(HYDRO_RESOLUTION - 1) * float(RESOLUTION - 1)))
		for x in range(HYDRO_RESOLUTION):
			var source_x := int(round(float(x) / float(HYDRO_RESOLUTION - 1) * float(RESOLUTION - 1)))
			var source_index := source_x + source_y * RESOLUTION
			var index := x + y * HYDRO_RESOLUTION
			terrain[index] = heights[source_index]
			initial_terrain[index] = heights[source_index]
			coast[index] = coast_sdf[source_index]
			hardness[index] = 0.72 + _hash01(x, y, seed_value, 0, 3) * 0.56
			rain_map[index] = 0.78 + _hash01(x, y, seed_value, 0, 4) * 0.44

	var flux_left := PackedFloat32Array()
	var flux_right := PackedFloat32Array()
	var flux_up := PackedFloat32Array()
	var flux_down := PackedFloat32Array()
	flux_left.resize(count)
	flux_right.resize(count)
	flux_up.resize(count)
	flux_down.resize(count)
	var cell_world_size := WORLD_SIZE / float(HYDRO_RESOLUTION - 1)

	for iteration in range(HYDRO_ITERATIONS):
		# Rainfall replenishes the shallow water layer over land.
		for index in range(count):
			if coast[index] > 0.0:
				water[index] += HYDRO_RAIN * rain_map[index]

		# Pass A: compute outgoing water flux from the local water-surface gradient.
		for y in range(1, HYDRO_RESOLUTION - 1):
			for x in range(1, HYDRO_RESOLUTION - 1):
				var index := x + y * HYDRO_RESOLUTION
				if coast[index] <= 0.0:
					flux_left[index] = 0.0
					flux_right[index] = 0.0
					flux_up[index] = 0.0
					flux_down[index] = 0.0
					continue

				var surface := terrain[index] + water[index]
				var left := index - 1
				var right := index + 1
				var up := index - HYDRO_RESOLUTION
				var down := index + HYDRO_RESOLUTION
				var raw_left := maxf(surface - terrain[left] - water[left], 0.0) * HYDRO_FLOW_RATE
				var raw_right := maxf(surface - terrain[right] - water[right], 0.0) * HYDRO_FLOW_RATE
				var raw_up := maxf(surface - terrain[up] - water[up], 0.0) * HYDRO_FLOW_RATE
				var raw_down := maxf(surface - terrain[down] - water[down], 0.0) * HYDRO_FLOW_RATE
				var raw_total := raw_left + raw_right + raw_up + raw_down
				var flow_scale := minf(1.0, water[index] * 0.78 / maxf(raw_total, 0.00001))
				flux_left[index] = raw_left * flow_scale
				flux_right[index] = raw_right * flow_scale
				flux_up[index] = raw_up * flow_scale
				flux_down[index] = raw_down * flow_scale

		# Pass B: update water, erode/deposit sediment, and advect suspended material.
		var next_water := PackedFloat32Array()
		var next_sediment := PackedFloat32Array()
		var next_terrain := terrain.duplicate()
		next_water.resize(count)
		next_sediment.resize(count)

		for y in range(1, HYDRO_RESOLUTION - 1):
			for x in range(1, HYDRO_RESOLUTION - 1):
				var index := x + y * HYDRO_RESOLUTION
				if coast[index] <= 0.0:
					continue

				var left := index - 1
				var right := index + 1
				var up := index - HYDRO_RESOLUTION
				var down := index + HYDRO_RESOLUTION
				var incoming := flux_right[left] + flux_left[right] + flux_down[up] + flux_up[down]
				var outgoing := flux_left[index] + flux_right[index] + flux_up[index] + flux_down[index]
				next_water[index] = maxf(water[index] + incoming - outgoing, 0.0) * 0.988

				var max_drop := maxf(
					maxf(absf(terrain[index] - terrain[left]), absf(terrain[index] - terrain[right])),
					maxf(absf(terrain[index] - terrain[up]), absf(terrain[index] - terrain[down]))
				)
				var slope := max_drop / cell_world_size
				var flow_strength := incoming + outgoing
				var capacity := flow_strength * (0.25 + slope * 8.0)
				var carried := sediment[index]
				if flow_strength > 0.008 and carried < capacity:
					var eroded := minf((capacity - carried) * 0.20 * hardness[index], 0.42)
					eroded = minf(eroded, maxf(terrain[index] - 0.35, 0.0))
					next_terrain[index] -= eroded
					carried += eroded
				elif carried > capacity:
					var deposited := minf(carried, (carried - capacity) * 0.24)
					next_terrain[index] += deposited
					carried -= deposited

				var transport_fraction := clampf(
					outgoing / maxf(water[index] + incoming, 0.02) * 0.52,
					0.0,
					0.78
				)
				var transported := carried * transport_fraction
				next_sediment[index] += carried - transported
				if outgoing > 0.00001:
					if coast[left] > 0.0:
						next_sediment[left] += transported * flux_left[index] / outgoing
					if coast[right] > 0.0:
						next_sediment[right] += transported * flux_right[index] / outgoing
					if coast[up] > 0.0:
						next_sediment[up] += transported * flux_up[index] / outgoing
					if coast[down] > 0.0:
						next_sediment[down] += transported * flux_down[index] / outgoing

		terrain = next_terrain
		water = next_water
		sediment = next_sediment
		if iteration % 7 == 6:
			_thermal_relax_coarse(terrain, coast, cell_world_size)

	# Bilinearly upsample the simulated height change, preserving all fine-scale detail.
	var delta_field := PackedFloat32Array()
	delta_field.resize(count)
	for index in range(count):
		delta_field[index] = terrain[index] - initial_terrain[index]

	var scale := float(HYDRO_RESOLUTION - 1) / float(RESOLUTION - 1)
	for y in range(RESOLUTION):
		var gy := float(y) * scale
		var y0 := mini(int(floor(gy)), HYDRO_RESOLUTION - 2)
		var ty := gy - float(y0)
		for x in range(RESOLUTION):
			var gx := float(x) * scale
			var x0 := mini(int(floor(gx)), HYDRO_RESOLUTION - 2)
			var tx := gx - float(x0)
			var a := lerpf(
				delta_field[x0 + y0 * HYDRO_RESOLUTION],
				delta_field[x0 + 1 + y0 * HYDRO_RESOLUTION],
				tx
			)
			var b := lerpf(
				delta_field[x0 + (y0 + 1) * HYDRO_RESOLUTION],
				delta_field[x0 + 1 + (y0 + 1) * HYDRO_RESOLUTION],
				tx
			)
			var index := x + y * RESOLUTION
			if coast_sdf[index] > 0.0:
				heights[index] = maxf(heights[index] + lerpf(a, b, ty) * 0.92, 0.35)

	return heights


func _thermal_relax_coarse(
	terrain: PackedFloat32Array,
	coast: PackedFloat32Array,
	cell_world_size: float
) -> void:
	var delta := PackedFloat32Array()
	delta.resize(HYDRO_RESOLUTION * HYDRO_RESOLUTION)
	var talus_height := maxf(cell_world_size * 0.075, 2.8)
	for y in range(1, HYDRO_RESOLUTION - 1):
		for x in range(1, HYDRO_RESOLUTION - 1):
			var index := x + y * HYDRO_RESOLUTION
			if coast[index] <= 0.0:
				continue
			var right := index + 1
			var down := index + HYDRO_RESOLUTION
			if coast[right] > 0.0:
				var right_difference := terrain[index] - terrain[right]
				if absf(right_difference) > talus_height:
					var right_transfer := minf((absf(right_difference) - talus_height) * 0.12, 0.75)
					if right_difference > 0.0:
						delta[index] -= right_transfer
						delta[right] += right_transfer
					else:
						delta[index] += right_transfer
						delta[right] -= right_transfer
			if coast[down] > 0.0:
				var difference_down := terrain[index] - terrain[down]
				if absf(difference_down) > talus_height:
					var transfer_down := minf((absf(difference_down) - talus_height) * 0.12, 0.75)
					if difference_down > 0.0:
						delta[index] -= transfer_down
						delta[down] += transfer_down
					else:
						delta[index] += transfer_down
						delta[down] -= transfer_down
	for index in range(terrain.size()):
		if coast[index] > 0.0:
			terrain[index] = maxf(terrain[index] + delta[index], 0.35)


# Droplets follow the negative height gradient, pick up sediment on downhill
# segments and deposit it when their transport capacity falls.
func _apply_hydraulic_droplets(
	heights: PackedFloat32Array,
	coast_sdf: PackedFloat32Array,
	seed_value: int
) -> PackedFloat32Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value + 17011

	for droplet_index in range(DROPLET_COUNT):
		var position := Vector2.ZERO
		var spawned := false
		for attempt in range(24):
			var candidate := Vector2(
				rng.randf_range(1.0, float(RESOLUTION - 2)),
				rng.randf_range(1.0, float(RESOLUTION - 2))
			)
			if _sample_coast(coast_sdf, candidate) > 95.0 and _sample_height(heights, candidate) > 24.0:
				position = candidate
				spawned = true
				break
		if not spawned:
			continue

		var direction := Vector2.ZERO
		var speed := 1.0
		var water := 1.0
		var sediment := 0.0

		for lifetime in range(DROPLET_LIFETIME):
			var height_before := _sample_height(heights, position)
			var gradient := Vector2(
				_sample_height(heights, position + Vector2.RIGHT) - _sample_height(heights, position - Vector2.RIGHT),
				_sample_height(heights, position + Vector2.DOWN) - _sample_height(heights, position - Vector2.DOWN)
			) * 0.5
			direction = direction * 0.12 - gradient * 0.88
			if direction.length_squared() < 0.000001:
				break
			direction = direction.normalized()

			var next_position := position + direction
			if next_position.x < 1.0 or next_position.y < 1.0:
				break
			if next_position.x >= float(RESOLUTION - 2) or next_position.y >= float(RESOLUTION - 2):
				break
			if _sample_coast(coast_sdf, next_position) <= 8.0:
				break

			var height_after := _sample_height(heights, next_position)
			var delta_height := height_after - height_before
			var sediment_capacity := maxf(-delta_height * speed * water * 4.0, 0.035)

			if sediment > sediment_capacity or delta_height > 0.0:
				var deposit := minf(delta_height, sediment) if delta_height > 0.0 else (sediment - sediment_capacity) * 0.34
				deposit = maxf(deposit, 0.0)
				_deposit_bilinear(heights, position, deposit)
				sediment -= deposit
			else:
				var erode_amount := minf((sediment_capacity - sediment) * 0.38, -delta_height)
				if erode_amount > 0.0:
					sediment += _erode_brush(heights, position, erode_amount)

			speed = sqrt(maxf(speed * speed - delta_height * 4.0, 0.01))
			water *= 0.99
			position = next_position
			if water < 0.05:
				break

	return heights


func _sample_height(heights: PackedFloat32Array, position: Vector2) -> float:
	var x0 := clampi(int(floor(position.x)), 0, RESOLUTION - 1)
	var y0 := clampi(int(floor(position.y)), 0, RESOLUTION - 1)
	var x1 := mini(x0 + 1, RESOLUTION - 1)
	var y1 := mini(y0 + 1, RESOLUTION - 1)
	var tx := clampf(position.x - float(x0), 0.0, 1.0)
	var ty := clampf(position.y - float(y0), 0.0, 1.0)
	var a := lerpf(heights[x0 + y0 * RESOLUTION], heights[x1 + y0 * RESOLUTION], tx)
	var b := lerpf(heights[x0 + y1 * RESOLUTION], heights[x1 + y1 * RESOLUTION], tx)
	return lerpf(a, b, ty)


func _sample_coast(coast_sdf: PackedFloat32Array, position: Vector2) -> float:
	var x := clampi(int(round(position.x / float(RESOLUTION - 1) * float(COAST_RESOLUTION - 1))), 0, COAST_RESOLUTION - 1)
	var y := clampi(int(round(position.y / float(RESOLUTION - 1) * float(COAST_RESOLUTION - 1))), 0, COAST_RESOLUTION - 1)
	return coast_sdf[x + y * COAST_RESOLUTION]


func _deposit_bilinear(heights: PackedFloat32Array, position: Vector2, amount: float) -> void:
	if amount <= 0.0:
		return
	var x0 := clampi(int(floor(position.x)), 0, RESOLUTION - 2)
	var y0 := clampi(int(floor(position.y)), 0, RESOLUTION - 2)
	var tx := clampf(position.x - float(x0), 0.0, 1.0)
	var ty := clampf(position.y - float(y0), 0.0, 1.0)
	heights[x0 + y0 * RESOLUTION] += amount * (1.0 - tx) * (1.0 - ty)
	heights[x0 + 1 + y0 * RESOLUTION] += amount * tx * (1.0 - ty)
	heights[x0 + (y0 + 1) * RESOLUTION] += amount * (1.0 - tx) * ty
	heights[x0 + 1 + (y0 + 1) * RESOLUTION] += amount * tx * ty


func _erode_brush(heights: PackedFloat32Array, position: Vector2, amount: float) -> float:
	var centre_x := int(floor(position.x))
	var centre_y := int(floor(position.y))
	var total_weight := 0.0
	for oy in range(-1, 2):
		for ox in range(-1, 2):
			var sample_x := centre_x + ox
			var sample_y := centre_y + oy
			if sample_x < 1 or sample_y < 1 or sample_x >= RESOLUTION - 1 or sample_y >= RESOLUTION - 1:
				continue
			var sample_weight := maxf(1.0 - Vector2(float(ox), float(oy)).length() / 1.65, 0.0)
			if heights[sample_x + sample_y * RESOLUTION] > 0.5:
				total_weight += sample_weight

	if total_weight <= 0.0001:
		return 0.0

	var removed := 0.0
	for oy in range(-1, 2):
		for ox in range(-1, 2):
			var target_x := centre_x + ox
			var target_y := centre_y + oy
			if target_x < 1 or target_y < 1 or target_x >= RESOLUTION - 1 or target_y >= RESOLUTION - 1:
				continue
			var target_index := target_x + target_y * RESOLUTION
			var target_weight := maxf(1.0 - Vector2(float(ox), float(oy)).length() / 1.65, 0.0)
			var available := maxf(heights[target_index] - 0.5, 0.0)
			var take := minf(available, amount * target_weight / total_weight)
			heights[target_index] -= take
			removed += take
	return removed


# Multi-scale drainage gullies and dividing ridges. Neighboring jittered pivots are
# blended as cosine/sine pairs, following Runevision's published filter principles.
func _apply_slope_aligned_gullies(
	heights: PackedFloat32Array,
	coast_sdf: PackedFloat32Array,
	seed_value: int
) -> PackedFloat32Array:
	var current := heights
	var world_step := WORLD_SIZE / float(RESOLUTION - 1)

	for octave in range(OCTAVES):
		var previous := current.duplicate()
		var next_heights := previous.duplicate()
		var cell_size := 620.0 / pow(2.0, float(octave))
		var stripe_period := cell_size * 0.34
		var stripe_frequency := TAU / stripe_period
		var amplitude := 8.0 / pow(2.0, float(octave))

		for y in range(1, RESOLUTION - 1):
			var world_z := (float(y) / float(RESOLUTION - 1) - 0.5) * WORLD_SIZE
			for x in range(1, RESOLUTION - 1):
				var index := x + y * RESOLUTION
				var terrain_height := previous[index]
				if terrain_height < 38.0:
					continue

				var gradient := Vector2(
					previous[index + 1] - previous[index - 1],
					previous[index + RESOLUTION] - previous[index - RESOLUTION]
				) / (2.0 * world_step)
				var slope := gradient.length()
				if slope < 0.012:
					continue
				var tangent := Vector2(-gradient.y, gradient.x) / maxf(slope, 0.0001)
				var world_x := (float(x) / float(RESOLUTION - 1) - 0.5) * WORLD_SIZE
				var position := Vector2(world_x, world_z)
				var cell_x := int(floor(world_x / cell_size))
				var cell_y := int(floor(world_z / cell_size))
				var cosine_sum := 0.0
				var sine_sum := 0.0
				var weight_sum := 0.0

				for oy in range(2):
					for ox in range(2):
						var cx := cell_x + ox
						var cy := cell_y + oy
						var jitter_x := _hash01(cx, cy, seed_value, octave, 0)
						var jitter_y := _hash01(cx, cy, seed_value, octave, 1)
						var pivot := Vector2(
							(float(cx) + 0.20 + jitter_x * 0.60) * cell_size,
							(float(cy) + 0.20 + jitter_y * 0.60) * cell_size
						)
						var distance_weight := 1.0 - clampf(position.distance_to(pivot) / (cell_size * 1.65), 0.0, 1.0)
						var weight := distance_weight * distance_weight
						if weight > 0.0001:
							var phase := (position - pivot).dot(tangent) * stripe_frequency
							phase += _hash01(cx, cy, seed_value, octave, 2) * TAU
							cosine_sum += cos(phase) * weight
							sine_sum += sin(phase) * weight
							weight_sum += weight

				if weight_sum <= 0.0001:
					continue
				var wave := Vector2(cosine_sum, sine_sum) / weight_sum
				var wave_length := wave.length()
				if wave_length > 0.5:
					wave *= minf(2.0 * wave_length, 1.0) / wave_length
				var fade_target := _smoothstep(45.0, 270.0, terrain_height) * 2.0 - 1.0
				var slope_mask := _ease_out(_smoothstep(0.018, 0.20, slope))
				var coast_x := int(round(float(x) / float(RESOLUTION - 1) * float(COAST_RESOLUTION - 1)))
				var coast_y := int(round(float(y) / float(RESOLUTION - 1) * float(COAST_RESOLUTION - 1)))
				var inland_mask := _smoothstep(25.0, 190.0, coast_sdf[coast_x + coast_y * COAST_RESOLUTION])
				var erosion_offset := (wave.x - fade_target) * amplitude * 0.56 * slope_mask * inland_mask
				next_heights[index] = maxf(terrain_height + erosion_offset, 0.35)

		current = next_heights
	return current


# Conservative talus relaxation transfers excess height difference downhill.
func _apply_thermal_relaxation(
	heights: PackedFloat32Array,
	coast_sdf: PackedFloat32Array
) -> PackedFloat32Array:
	var current := heights
	var world_step := WORLD_SIZE / float(RESOLUTION - 1)
	var talus_height := world_step * 0.34

	for iteration in range(THERMAL_ITERATIONS):
		var delta := PackedFloat32Array()
		delta.resize(RESOLUTION * RESOLUTION)
		for y in range(1, RESOLUTION - 1):
			var coast_y := int(round(float(y) / float(RESOLUTION - 1) * float(COAST_RESOLUTION - 1)))
			for x in range(1, RESOLUTION - 1):
				var index := x + y * RESOLUTION
				if current[index] <= 0.0:
					continue
				var coast_x := int(round(float(x) / float(RESOLUTION - 1) * float(COAST_RESOLUTION - 1)))
				if coast_sdf[coast_x + coast_y * COAST_RESOLUTION] <= 0.0:
					continue

				var right := index + 1
				var down := index + RESOLUTION
				var right_coast_x := int(round(float(x + 1) / float(RESOLUTION - 1) * float(COAST_RESOLUTION - 1)))
				var down_coast_y := int(round(float(y + 1) / float(RESOLUTION - 1) * float(COAST_RESOLUTION - 1)))
				if coast_sdf[right_coast_x + coast_y * COAST_RESOLUTION] > 0.0:
					var right_difference := current[index] - current[right]
					if absf(right_difference) > talus_height:
						var right_transfer := minf((absf(right_difference) - talus_height) * 0.22, 1.5)
						if right_difference > 0.0:
							delta[index] -= right_transfer
							delta[right] += right_transfer
						else:
							delta[index] += right_transfer
							delta[right] -= right_transfer
				if coast_sdf[coast_x + down_coast_y * COAST_RESOLUTION] > 0.0:
					var down_difference := current[index] - current[down]
					if absf(down_difference) > talus_height:
						var down_transfer := minf((absf(down_difference) - talus_height) * 0.22, 1.5)
						if down_difference > 0.0:
							delta[index] -= down_transfer
							delta[down] += down_transfer
						else:
							delta[index] += down_transfer
							delta[down] -= down_transfer

		for index in range(current.size()):
			if current[index] > 0.0:
				current[index] = maxf(current[index] + delta[index], 0.35)
	return current


func _hash01(x: int, y: int, seed_value: int, octave: int, lane: int) -> float:
	var reduced_seed := seed_value % 65521
	var value: int = (x * 374761393 + y * 668265263 + reduced_seed * 69069 + octave * 362437 + lane * 1013904223) & 0x7fffffff
	value = ((value ^ (value >> 13)) * 1274126177) & 0x7fffffff
	value = value ^ (value >> 16)
	return float(value & 0x7fffffff) / 2147483647.0


func _ease_out(value: float) -> float:
	var inverse := 1.0 - clampf(value, 0.0, 1.0)
	return 1.0 - inverse * inverse


func _smoothstep(edge_a: float, edge_b: float, value: float) -> float:
	var t := clampf((value - edge_a) / (edge_b - edge_a), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)
