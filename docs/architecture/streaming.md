# Streaming scripts

Точки входа и карта слоёв перечислены в [обзоре архитектуры](README.md). Исходные пути сохранены, чтобы не менять ссылки сцен и preload. State-файлы содержат общие поля; слои наследования организованы по зависимостям локальных методов.

**Отдельные сервисы:**
- `MeshDataCache` владеет LRU-данными мешей, лимитами памяти/записей и ключом кэша.
- `ChunkResourceManager` владеет очередью отложенного освобождения, detached chunks и пулом повторного использования.

`StreamingPlanner` выделен в `scripts/streaming/streaming_planner.gd` как `RefCounted`-сервис. `VoxelWorld` передаёт ему явный config snapshot, предыдущий wanted set, результат surface sampler через `Callable` и output Dictionary. Сервис не владеет SceneTree, чанками, задачами или генератором. Текущий extraction сохраняет формат request Dictionary и LOD key. Новый сервис ещё ожидает Windows CI после переноса. `MeshJobScheduler` пока остаётся в слоях координатора. Контракты и последовательность описаны в [ADR-018](../decisions/ADR-018.md). `VoxelWorld` сохраняет ownership seed, generator, `generation_epoch` и применение Node/mesh/collision результатов.
