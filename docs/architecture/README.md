# Архитектура кода

## Стабильные точки входа GDScript

Пути, на которые ссылаются сцены и другие скрипты, сохранены:
- `scripts/streaming/voxel_world.gd` — `VoxelWorld`.
- `scripts/rendering/voxel_surface_scatter.gd` — `VoxelSurfaceScatter`.
- `scripts/world/world_controller.gd` — `WorldController`.

Каждая точка входа наследует цепочку небольших файлов в одноимённой подпапке. `*_state.gd` содержит исходные сигналы, константы, exports и поля; следующие слои содержат методы в порядке зависимостей. Вызванный локальный метод расположен в том же или родительском слое. Публичные class_name, exports, сигналы и пути сцен сохранены.

### VoxelWorld

- `scripts/streaming/mesh_data_cache.gd` — самостоятельный LRU-кэш с бюджетом 48 MiB / 32 записи.
- `scripts/streaming/chunk_resource_manager.gd` — очередь retirement, detached resources и пул оболочек чанков.

- `scripts/streaming/voxel_world/voxel_world_layer_01_core.gd`: is_terrain_preparing, regenerate_with_seed, set_shadow_mode, get_lod_boundary_m, _current_viewport_pixel_size, get_mesh_step_voxels, _apply_seed_to_material, get_surface_height, get_voxel_material, is_startup_loading, get_loaded_chunk_count, surface_sample_at_world
- `scripts/streaming/voxel_world/voxel_world_layer_02_mesh_data.gd`: _chunk_has_collision_resource, _distance_to_tile_xz, _make_mesh_cache_key, _estimate_mesh_data_bytes, _get_cached_mesh, _create_mesh_builder, _job_record_matches_current, _running_job_matches, _completed_job_matches, _chunk_center, _player_xz, _make_lod_key
- `scripts/streaming/voxel_world/voxel_world_layer_03_resource_lifetime.gd`: _decode_lod_key, _get_streaming_heading, _estimated_build_usec, _record_timing, _avg_ms, _p95_usec, _queue_chunk_retirement, _exit_tree, regenerate_with_random_seed, get_lod_boundary_m_for_height, can_move_to_position
- `scripts/streaming/voxel_world/voxel_world_layer_04_streaming.gd`: _chunk_bounds, _store_cached_mesh, _lod_neighbor_key, _find_target_lod_key_at_point, _mark_hierarchy_dirty_for, _refresh_build_estimate_cache, _estimated_lod_pipeline_usec, _p95_ms, _retire_stale_resources, _place_player_on_surface, _lod_for_distance, _lod_boundary_for
- `scripts/streaming/voxel_world/voxel_world_layer_05_lod.gd`: _unhandled_input, _refresh_lod_boundaries, _find_visible_lod_key_at_point, _collect_lod_tiles, _deadline_priority, _effective_prediction_seconds, _ready, get_debug_text, _should_show_chunk_skirt, _target_lod_for_neighbor, _get_lod_tile_children, _update_chunk_skirt_visibility
- `scripts/streaming/voxel_world/voxel_world_layer_06_runtime.gd`: _neighbor_lods_for, _all_lod_children_ready, _lod_tile_coverage_ready, is_world_coverage_ready, get_startup_progress, _update_neighbor_chunk_skirts, _process_chunk_jobs, _fallback_children_ready, is_terrain_shadow_ready, _try_finish_startup_loading, _refresh_streaming, _poll_worker_tasks
- `scripts/streaming/voxel_world/voxel_world_layer_07_orchestration.gd`: _apply_completed_jobs, _update_lod_subtree_visibility, _prepare_world_for_epoch, refresh_lod_boundaries, set_render_distance_m, _reconcile_hierarchy_visibility, _poll_terrain_prepare_jobs, set_lod_settings, set_lod_target_pixels, _process

### VoxelSurfaceScatter

- `scripts/rendering/voxel_surface_scatter/voxel_surface_scatter_layer_01_lod_geometry.gd`: set_weather_mode, _on_terrain_seed_changed, _plant_is_requested, _desired_plant_lod, _prop_lod_for_distance, _schedule_plant_tile, _create_decor_collision_shapes, _make_palette, _make_object_grid, _surface_info, _can_reserve, _append_transformed_mesh
- `scripts/rendering/voxel_surface_scatter/voxel_surface_scatter_layer_02_runtime.gd`: _make_noise, _near_spawn, _mix, _ready, _should_generate_rocks, _prop_lod_for_distance_with_hysteresis, _schedule_rock_tile, _poll_decor_tasks, _reconcile_entries, _build_one_pending_tile, _process

### WorldController

- `scripts/world/world_controller/world_controller_layer_01_environment.gd`: set_lod_target_pixels, _apply_view_distance_environment, _configure_sky_system, _on_generation_started, _on_generation_progress, _build_flight_status, _on_flight_mode_changed, _make_control_button, _apply_weather, _update_weather_button_styles, _update_time_button_styles, _set_weather_menu_open
- `scripts/world/world_controller/world_controller_layer_02_ui_generation.gd`: _style_button, _process, _build_voxen_debug_ui, _toggle_voxen_debug, _on_pause_menu_opened, _on_pause_menu_closed, _return_to_menu, set_view_distance_m, begin_generation, _on_generation_finished, _on_weather_button_pressed, _on_time_preset_pressed
- `scripts/world/world_controller/world_controller_layer_03_runtime.gd`: _on_time_changed, _toggle_weather_menu, _unhandled_input, _build_pause_menu_ui, _open_pause_menu, _begin_pending_game_if_requested, _on_weather_selection_changed, _on_time_selection_changed, _setup_weather_controls, _ready

## Native builder

- `native/src/voxen_native_builder.cpp` — GDExtension API, binding и публичные методы.
- `native/src/voxen_terrain_sampler.h` — NoiseSet, PG-Island sampling, terrain detail и материалы.
- `native/src/voxen_heightfield_mesher.h` — текущий heightfield MeshBuild, верхние/боковые грани, LOD skirts и shadow proxy.
- `native/src/voxen_heightfield_collision_builder.h` — отдельная сборка HeightMap collision data.

Текущая модель остаётся heightfield. Разделение не создаёт объёмный SDF, Marching Cubes или пещеры. Публичные методы GDExtension и формат результатов сохранены.

## Правила

1. Не менять алгоритмы и порядок вычислений при структурном переносе.
2. Сохранять прежние публичные пути и имена классов.
3. Обновлять ссылки, тесты и документацию согласованно.
4. Не создавать Godot Node, ArrayMesh или физические ресурсы в worker thread.
5. Сохранять generation_epoch, экранный LOD, детерминированность и буферизованную замену чанков.
6. Не называть coast SDF объёмным SDF.
