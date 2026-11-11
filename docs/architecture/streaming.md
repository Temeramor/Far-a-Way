# Streaming scripts

Точки входа и карта слоёв перечислены в [обзоре архитектуры](README.md). Исходные пути сохранены, чтобы не менять ссылки сцен и preload. State-файлы содержат общие поля; слои наследования организованы по зависимостям локальных методов.

**Отдельные сервисы:**
- `MeshDataCache` владеет LRU-данными мешей, лимитами памяти/записей и ключом кэша.
- `ChunkResourceManager` владеет очередью отложенного освобождения, detached chunks и пулом повторного использования.

`StreamingPlanner` и `MeshJobScheduler` пока остаются в слоях координатора. Контракты и безопасная последовательность extraction описаны в [ADR-018](../decisions/ADR-018.md): сначала characterization tests и immutable inputs, затем planner, затем scheduler. `VoxelWorld` сохраняет ownership seed, generator, `generation_epoch` и применение Node/mesh/collision результатов. Механический перенос без этих контрактов создаст риск регрессий.
