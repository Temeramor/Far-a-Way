# Native builder

Публичный GDExtension-класс `VoxEnNativeBuilder` и его методы сохранены в `voxen_native_builder.cpp` / `.h`.

- `voxen_terrain_sampler.h`: NoiseSet, PG-Island sampling, terrain detail и surface material evaluation.
- `voxen_heightfield_mesher.h`: текущая heightfield-геометрия, LOD skirts и shadow proxy.
- `voxen_heightfield_collision_builder.h`: отдельная сборка HeightMap collision data.

SCons по-прежнему собирает `src/*.cpp`; внутренние модули header-only и подключаются из публичного translation unit. Публичный API и формат Dictionary/Array не меняются. Текущая геометрия остаётся heightfield: здесь нет 3D density field, Marching Cubes или реальных пещер.
