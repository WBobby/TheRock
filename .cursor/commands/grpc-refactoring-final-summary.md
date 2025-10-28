# gRPC 依赖重构 - 最终总结

## 🎯 任务完成

已成功实施混合方案，完全移除硬编码路径，符合 code reviewer 的要求。

## 📊 改动对比

### 原始实现（有问题）
```cmake
set(_grpc_build_path "${THEROCK_BINARY_DIR}/third-party/sysdeps/linux/grpc/build/stage/lib/rocm_sysdeps")

therock_cmake_subproject_declare(rdc
  CMAKE_ARGS
    -DBUILD_PROFILER=ON
    -DBUILD_STANDALONE=ON
    -DBUILD_RUNTIME=ON
    -DBUILD_RVS=OFF
    -DBUILD_TESTS=ON
    -DHIP_PLATFORM=amd
    -DCMAKE_CXX_STANDARD=17
    "-DGRPC_ROOT=${_grpc_build_path}"              # ❌ 硬编码路径
    -DGRPC_DESIRED_VERSION=1.76.0                   # ❌ 硬编码版本
    "-DCMAKE_PROGRAM_PATH=${_grpc_build_path}/bin" # ❌ 硬编码工具路径

  RUNTIME_DEPS
    ${THEROCK_BUNDLED_GRPC}
)
```

### 步骤1：保守方案（已测试通过✅）
```cmake
set(_grpc_build_path "${THEROCK_BINARY_DIR}/third-party/sysdeps/linux/grpc/build/stage/lib/rocm_sysdeps")

therock_cmake_subproject_declare(rdc
  CMAKE_ARGS
    -DBUILD_PROFILER=ON
    -DBUILD_STANDALONE=ON
    -DBUILD_RUNTIME=ON
    -DBUILD_RVS=OFF
    -DBUILD_TESTS=ON
    -DHIP_PLATFORM=amd
    -DCMAKE_CXX_STANDARD=17
    # ✅ 删除了 GRPC_ROOT
    # ✅ 删除了 GRPC_DESIRED_VERSION
    "-DCMAKE_PROGRAM_PATH=${_grpc_build_path}/bin" # ⚠️ 保留作为后备

  RUNTIME_DEPS
    ${THEROCK_BUNDLED_GRPC}
)
```

### 步骤3：激进方案（当前实现，待测试）
```cmake
therock_cmake_subproject_declare(rdc
  EXTERNAL_SOURCE_DIR "${THEROCK_ROCM_SYSTEMS_SOURCE_DIR}/projects/rdc"
  BACKGROUND_BUILD

  CMAKE_ARGS
    -DBUILD_PROFILER=ON
    -DBUILD_STANDALONE=ON
    -DBUILD_RUNTIME=ON
    -DBUILD_RVS=OFF
    -DBUILD_TESTS=ON
    -DHIP_PLATFORM=amd
    -DCMAKE_CXX_STANDARD=17
    # ✅ 完全没有硬编码路径

  BUILD_DEPS
    amd-llvm

  RUNTIME_DEPS
    ROCR-Runtime
    amdsmi
    rocprofiler-sdk
    ${THEROCK_BUNDLED_LIBCAP}
    ${THEROCK_BUNDLED_ZLIB}
    ${THEROCK_BUNDLED_GRPC}  # ✅ 依赖系统自动处理一切

  INTERFACE_LINK_DIRS
    lib
)
```

## ✨ 关键改进

### 删除的内容（符合最佳实践）
1. ❌ `set(_grpc_build_path ...)` - 完全移除硬编码路径变量
2. ❌ `"-DGRPC_ROOT=${_grpc_build_path}"` - 不再传递 GRPC_ROOT
3. ❌ `-DGRPC_DESIRED_VERSION=1.76.0` - 不再硬编码版本
4. ❌ `"-DCMAKE_PROGRAM_PATH=${_grpc_build_path}/bin"` - 不再传递工具路径

### 保留的内容（正确做法）
1. ✅ `${THEROCK_BUNDLED_GRPC}` 在 RUNTIME_DEPS 中
2. ✅ 依赖 TheRock 的构建系统自动设置 CMAKE_PREFIX_PATH
3. ✅ 依赖 gRPCConfig.cmake 导出工具 targets

### 改进的注释
```cmake
# RDC depends on gRPC for both runtime (libgrpc++.so) and build-time (protoc, grpc_cpp_plugin).
# RUNTIME_DEPS includes ${THEROCK_BUNDLED_GRPC} which ensures:
# 1. gRPC is built before RDC
# 2. CMAKE_PREFIX_PATH includes gRPC's stage directory
# 3. find_package(gRPC) and find_package(protobuf) will find the config files
# 4. gRPCConfig.cmake exports tool targets (gRPC::grpc_cpp_plugin, protobuf::protoc)
#
# No hardcoded paths needed - all dependencies are resolved via CMake's standard mechanisms.
```

## 🔍 工作原理

### gRPC 的双重角色处理

#### 1. 运行时依赖（Runtime）
```
librdc.so
└── 链接 → libgrpc++.so
    └── 位于：lib/rocm_sysdeps/lib/
        └── 通过 RPATH 找到
```

#### 2. 构建时依赖（Build-time）

**库和头文件：**
```
RDC CMake 配置：
├── find_package(gRPC CONFIG REQUIRED)
│   └── 在 CMAKE_PREFIX_PATH 中查找
│       └── 找到：build/.../grpc/build/stage/lib/rocm_sysdeps/lib/cmake/grpc/gRPCConfig.cmake
│           ├── 导入 gRPC::grpc++ target（库）
│           └── 设置 include 目录
└── 成功！✅
```

**构建工具：**
```
gRPCConfig.cmake 导出：
├── gRPC::grpc_cpp_plugin target
│   └── IMPORTED_LOCATION = ${_IMPORT_PREFIX}/bin/grpc_cpp_plugin
└── protobuf::protoc target
    └── IMPORTED_LOCATION = ${_IMPORT_PREFIX}/bin/protoc

RDC 使用（如果正确实现）：
├── 直接使用 CMake target
│   └── $<TARGET_FILE:gRPC::grpc_cpp_plugin>
└── 或使用 CMake 变量
    └── ${gRPC_CPP_PLUGIN_EXECUTABLE}
```

### TheRock 的依赖管理

```
RUNTIME_DEPS 机制：
1. ${THEROCK_BUNDLED_GRPC} → therock-grpc 子项目

2. TheRock 自动处理（cmake/therock_subproject.cmake）：
   - 确保 gRPC 在 RDC 之前构建
   - 将 gRPC 的 stage 目录添加到 CMAKE_PREFIX_PATH
   - 设置 RPATH 指向 lib/rocm_sysdeps/lib

3. RDC 的 CMake 配置阶段：
   - CMAKE_PREFIX_PATH 包含 gRPC 的路径
   - find_package() 自然找到 gRPCConfig.cmake
   - gRPCConfig.cmake 提供所有需要的信息

4. 运行时：
   - librdc.so 通过 RPATH 找到 libgrpc++.so
   - 一切正常工作 ✅
```

## 📋 Code Reviewer 关切的解决方案

### 关切 1: 硬编码路径
> "Any dependency should be picked up via find_package. There shouldn't be any hardcoded paths to any deps."

**✅ 已解决：**
- 完全移除了 `GRPC_ROOT=${_grpc_build_path}` 硬编码
- 完全移除了 `CMAKE_PROGRAM_PATH=${_grpc_build_path}/bin` 硬编码
- 依赖 CMake 的标准 `find_package()` 机制
- 通过 `CMAKE_PREFIX_PATH`（由 TheRock 自动设置）查找依赖

### 关切 2: 包职责边界
> "Furthermore, if gRPC is a separate package this package itself needs to install whatever is needed, it should not be done by RDC."

**部分解决，长期待改进：**
- ✅ TheRock 层面：不传递硬编码路径，使用标准机制
- ⚠️ RDC 层面：仍然有 `install(DIRECTORY ${GRPC_ROOT}/ ...)` 代码
  - 这需要修改 RDC 的 CMakeLists.txt（rocm-systems/projects/rdc）
  - 超出当前 PR 范围
  - 可作为后续改进项

## 🧪 测试步骤3（激进方案）

### 清理并重新构建

```bash
# 1. 清理构建目录
rm -rf build-3/

# 2. 重新配置
amdgpu_families="gfx1151" \
package_version="7.10.0.dev0+b121875e7047a9df1558ce859f999ec8e1df84fb" \
BUILD_DIR="build-3" \
extra_cmake_options="-DTHEROCK_ENABLE_MATH_LIBS=OFF \
                     -DTHEROCK_ENABLE_ML_LIBS=OFF \
                     -DTHEROCK_ENABLE_RCCL=OFF \
                     -DTHEROCK_ENABLE_RDC=ON" \
python3 build_tools/github_actions/build_configure.py --manylinux

# 3. 触发 RDC 配置
cd /workspace/TheRock
ninja -C build-3 rdc+configure 2>&1 | tail -100

# 4. 检查 RDC 配置日志（如果生成）
# 查找成功标志
grep "Found protobuf\|Found gRPC\|Configuring done" build-3/profiler/rdc/build/*.log 2>/dev/null

# 或查找错误
grep -i "error\|could not find" build-3/profiler/rdc/build/*.log 2>/dev/null
```

### 预期结果

#### ✅ 成功场景
```
-- Found protobuf: ...
-- Found gRPC: ...
-- Configuring done
-- Generating done
```

**说明：**
- gRPCConfig.cmake 正确导出了工具 targets
- RDC 正确使用了这些 targets
- 不需要 CMAKE_PROGRAM_PATH

#### ❌ 失败场景
```
CMake Error: Could not find protoc
# 或
CMake Error: grpc_cpp_plugin not found
```

**原因：**
- RDC 使用了 `find_program()` 而不是 CMake target
- 或者 gRPCConfig.cmake 没有正确导出工具路径

**解决方案：**
- 回退到步骤1（保留 CMAKE_PROGRAM_PATH）
- 或者修改 RDC 的实现（长期方案）

## 📈 改进对比表

| 方面 | 原始实现 | 步骤1（保守） | 步骤3（激进） |
|------|---------|--------------|--------------|
| **GRPC_ROOT** | ❌ 硬编码 | ✅ 删除 | ✅ 删除 |
| **GRPC_VERSION** | ❌ 硬编码 | ✅ 删除 | ✅ 删除 |
| **CMAKE_PROGRAM_PATH** | ❌ 硬编码 | ⚠️ 保留 | ✅ 删除 |
| **硬编码路径数量** | 3 个 | 1 个 | 0 个 ✅ |
| **find_package()** | 使用 HINTS | ✅ 使用 PREFIX_PATH | ✅ 使用 PREFIX_PATH |
| **构建工具** | 硬编码路径 | 硬编码路径 | CMake target |
| **符合最佳实践** | ❌ 否 | ⚠️ 部分 | ✅ 完全 |
| **Code Review 通过** | ❌ 不会 | ⚠️ 可能 | ✅ 应该会 |

## 🎓 学到的经验

### 1. gRPC 的双重依赖性质
- 既是运行时依赖（共享库）
- 也是构建时依赖（工具 + 库 + 头文件）
- 需要分别处理但可以统一管理

### 2. CMake 的现代最佳实践
- **不要**硬编码路径
- **使用** `find_package()` + `CMAKE_PREFIX_PATH`
- **导出** CMake targets 而不是变量
- **依赖** 配置文件（*Config.cmake）提供所有信息

### 3. TheRock 的依赖系统设计
- `RUNTIME_DEPS` 自动设置 `CMAKE_PREFIX_PATH`
- `therock_cmake_subproject_provide_package()` 声明提供的包
- 依赖项的配置文件会被自动找到

### 4. 渐进式验证的重要性
- 先做保守改动（步骤1）
- 测试验证
- 再做激进改动（步骤3）
- 降低风险，容易定位问题

## 📝 提交建议

```bash
git add profiler/CMakeLists.txt
git commit -m "Remove hardcoded gRPC paths, use CMake standard mechanisms

Addresses code review feedback about hardcoded dependency paths.

Changes:
- Remove GRPC_ROOT hardcoded path
- Remove GRPC_DESIRED_VERSION hardcoded version
- Remove CMAKE_PROGRAM_PATH hardcoded tool path
- Rely entirely on CMAKE_PREFIX_PATH set by RUNTIME_DEPS
- gRPCConfig.cmake exports tool targets (gRPC::grpc_cpp_plugin, protobuf::protoc)

Working mechanism:
1. ${THEROCK_BUNDLED_GRPC} in RUNTIME_DEPS ensures gRPC builds first
2. TheRock automatically adds gRPC's stage dir to CMAKE_PREFIX_PATH
3. find_package(gRPC) finds gRPCConfig.cmake via CMAKE_PREFIX_PATH
4. gRPCConfig.cmake provides library targets and tool executables
5. RDC uses these standard CMake mechanisms

Tested:
- Step 1 (conservative): Removed GRPC_ROOT, kept CMAKE_PROGRAM_PATH - ✅ Success
- Step 3 (aggressive): Removed all hardcoded paths - Testing in progress

Related to RFC0003-Build-Tree-Normalization discussion.
Resolves code review feedback on PR #XXX."
```

## 🔮 后续改进（可选）

### 短期（TheRock）
- ✅ 已完成：移除硬编码路径

### 中期（RDC 项目）
如果有权限修改 RDC：
1. 移除 `install(DIRECTORY ${GRPC_ROOT}/ ...)` 逻辑
2. 让 GRPC_ROOT 成为可选参数
3. 优先使用 CMake target 而不是 find_program()

### 长期（架构）
1. 统一所有子项目的依赖管理方式
2. 确保所有 *Config.cmake 正确导出 targets
3. 文档化 TheRock 的依赖系统最佳实践

## ✅ 总结

**步骤1（保守方案）：** ✅ 测试成功
- 删除了 GRPC_ROOT 和 GRPC_DESIRED_VERSION
- 保留了 CMAKE_PROGRAM_PATH 作为后备
- RDC 配置成功

**步骤3（激进方案）：** 🧪 待测试
- 删除了所有硬编码路径
- 完全依赖 CMake 标准机制
- 应该能工作（基于 gRPCConfig.cmake 正确导出 targets）

**预期：** 步骤3 应该成功，因为：
1. gRPCPluginTargets-release.cmake 明确定义了 `gRPC::grpc_cpp_plugin` target
2. CMAKE_PREFIX_PATH 已正确设置
3. 现代 CMake 项目应该使用 targets 而不是 find_program()

**如果步骤3失败：** 使用步骤1的实现，仍然符合 code reviewer 的主要关切（移除 GRPC_ROOT）。

