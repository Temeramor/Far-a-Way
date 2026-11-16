extends Node

func _ready() -> void:
	_run()

func _run() -> void:
	var scheduler := MeshJobScheduler.new()
	var errors: Array[String] = []
	var coord := Vector2i(12, 4)
	var request := {"lod": 0, "step_voxels": 1, "collision": true, "shadow_proxy": true}
	var record := {"coord": coord, "request": request.duplicate(true), "epoch": 7, "seed": 1337}

	if not scheduler.register_running(101, record):
		errors.append("A fresh worker job should register.")
	if scheduler.register_running(102, record):
		errors.append("A duplicate coordinate must not start a second worker job.")
	if not scheduler.running_by_coord.has(coord):
		errors.append("The running-coordinate index must point at the active task.")
	if not scheduler.is_record_current(record, request, 7, 1337):
		errors.append("An unchanged epoch/seed/request should remain current.")
	if scheduler.is_record_current(record, request, 8, 1337):
		errors.append("An older generation epoch must be rejected.")
	if scheduler.is_record_current(record, request, 7, 1338):
		errors.append("An older seed must be rejected.")
	var changed_request := request.duplicate(true)
	changed_request["collision"] = false
	if scheduler.is_record_current(record, changed_request, 7, 1337):
		errors.append("A changed collision request must invalidate the result.")

	var taken := scheduler.take_running(101)
	if taken.is_empty() or scheduler.running_by_coord.has(coord) or not scheduler.running_tasks.is_empty():
		errors.append("Taking a completed worker must clear both running indexes.")

	var cache_result := {"coord": coord, "request": request.duplicate(true), "epoch": 7, "seed": 1337, "data": {"vertices": PackedVector3Array([Vector3.ZERO])}}
	scheduler.publish_completed(coord, cache_result)
	var cached := scheduler.take_completed(coord)
	if cached.get("data", {}).is_empty() or not scheduler.completed_jobs.is_empty():
		errors.append("Cache hits must use the normal completion/apply path.")

	var wanted := {coord: request.duplicate(true)}
	if not scheduler.queue_retry(coord, wanted, 9001):
		errors.append("An empty-result retry should requeue a still-wanted coordinate.")
	elif int(scheduler.queued[coord].get("queued_usec", -1)) != 9001:
		errors.append("Retry must refresh queued_usec.")
	if scheduler.queue_retry(coord, {}, 9002):
		errors.append("A coordinate removed from wanted must not be retried.")

	scheduler.publish_completed(coord, cache_result)
	var stale := scheduler.take_completed(coord)
	if scheduler.is_record_current(stale, request, 8, 1337):
		errors.append("Stale completion must fail validation before apply.")

	scheduler.queued.clear()
	var near_coord := Vector2i(1, 1)
	var far_coord := Vector2i(8, 8)
	scheduler.queued[near_coord] = request.duplicate(true)
	scheduler.queued[far_coord] = request.duplicate(true)
	var selected := scheduler.select_next_queued(
		Vector2.ZERO, Vector2.UP, Vector2.ZERO,
		Callable(self, "_center_for"), Callable(self, "_priority_for")
	)
	if selected.get("coord", Vector2i(-1, -1)) != near_coord:
		errors.append("Scheduler must select the highest-priority queued request.")

	if scheduler.available_worker_slots(3, 1) != 2:
		errors.append("Shared worker budget must subtract active decor jobs.")
	if scheduler.available_worker_slots(3, 3) != 0:
		errors.append("Worker budget must never become negative.")

	if not errors.is_empty():
		for message in errors:
			push_error(message)
		get_tree().quit(1)
		return
	print("PASS: mesh_job_scheduler_test")
	get_tree().quit(0)

func _center_for(coord: Vector2i) -> Vector2:
	return Vector2(float(coord.x), float(coord.y))

func _priority_for(center: Vector2, _request: Dictionary, _player_xz: Vector2, _heading: Vector2, _velocity: Vector2) -> float:
	return center.length()
