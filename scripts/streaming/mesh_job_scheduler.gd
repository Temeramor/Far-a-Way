extends RefCounted
class_name MeshJobScheduler

# Owns the mutable queue and job-lifecycle registries. VoxelWorld retains aliases
# for compatibility with diagnostics and the decoration scheduler.
var queued: Dictionary = {}
var running_tasks: Dictionary = {}
var running_by_coord: Dictionary = {}
var completed_jobs: Dictionary = {}

func clear_pending() -> void:
	queued.clear()
	completed_jobs.clear()

func available_worker_slots(worker_limit: int, active_decor_jobs: int) -> int:
	return maxi(0, worker_limit - running_tasks.size() - maxi(0, active_decor_jobs))

func select_next_queued(player_xz: Vector2, heading: Vector2, velocity: Vector2, center_for: Callable, priority_for: Callable) -> Dictionary:
	var best_coord := Vector2i(-1, -1)
	var best_priority: float = INF
	for queued_key in queued.keys():
		var coord: Vector2i = queued_key
		if running_by_coord.has(coord):
			continue
		var center: Vector2 = center_for.call(coord)
		var request: Dictionary = queued[coord]
		var priority: float = float(priority_for.call(center, request, player_xz, heading, velocity))
		if priority < best_priority:
			best_priority = priority
			best_coord = coord
	if best_coord.x < 0:
		return {}
	return {"coord": best_coord, "priority": best_priority}

func register_running(task_id: int, record: Dictionary) -> bool:
	var coord: Vector2i = record.get("coord", Vector2i(-1, -1))
	if coord.x < 0 or running_by_coord.has(coord) or running_tasks.has(task_id):
		return false
	running_tasks[task_id] = record
	running_by_coord[coord] = task_id
	return true

func take_running(task_id: int) -> Dictionary:
	if not running_tasks.has(task_id):
		return {}
	var record: Dictionary = running_tasks[task_id]
	running_tasks.erase(task_id)
	var coord: Vector2i = record.get("coord", Vector2i(-1, -1))
	if int(running_by_coord.get(coord, -1)) == task_id:
		running_by_coord.erase(coord)
	return record

func publish_completed(coord: Vector2i, record: Dictionary) -> void:
	if not record.is_empty():
		completed_jobs[coord] = record

func take_completed(coord: Vector2i) -> Dictionary:
	if not completed_jobs.has(coord):
		return {}
	var record: Dictionary = completed_jobs[coord]
	completed_jobs.erase(coord)
	return record

func is_record_current(record: Dictionary, current_request: Dictionary, epoch: int, seed_value: int) -> bool:
	if record.is_empty() or current_request.is_empty():
		return false
	if int(record.get("epoch", -1)) != epoch or int(record.get("seed", -1)) != seed_value:
		return false
	var request: Dictionary = record.get("request", {})
	return (
		int(current_request.get("lod", -1)) == int(request.get("lod", -2))
		and int(current_request.get("step_voxels", -1)) == int(request.get("step_voxels", -2))
		and bool(current_request.get("collision", false)) == bool(request.get("collision", false))
		and bool(current_request.get("shadow_proxy", false)) == bool(request.get("shadow_proxy", false))
	)

func queue_retry(coord: Vector2i, wanted: Dictionary, now_usec: int) -> bool:
	if not wanted.has(coord):
		return false
	var retry: Dictionary = wanted[coord].duplicate(true)
	retry["queued_usec"] = now_usec
	queued[coord] = retry
	return true
