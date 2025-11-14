# RDC 构建配置错误分析

## 错误现象

运行构建配置命令时出现 CMake 配置错误：
```bash
amdgpu_families="gfx1151" package_version="7.10.0.dev0+..." \
BUILD_DIR="build-3" \
extra_cmake_options="-DTHEROCK_ENABLE_MATH_LIBS=OFF -DTHEROCK_ENABLE_ML_LIBS=OFF -DTHEROCK_ENABLE_RCCL=OFF -DTHEROCK_ENABLE_RDC=ON" \
python3 build_tools/github_actions/build_configure.py --manylinux

# 错误输出：
-- Configuring incomplete, errors occurred!
Traceback (most recent call last):
  File "/workspace/TheRock/build_tools/github_actions/build_configure.py", line 112, in <module>
    build_configure(manylinux=manylinux)
  File "/workspace/TheRock/build_tools/github_actions/build_configure.py", line 97, in build_configure
    subprocess.run(cmd, cwd=THEROCK_DIR, check=True)
```

## 根本原因分析

### 问题 1：目录加载顺序与依赖声明冲突

**CMakeLists.txt 第477-482行的目录加载顺序：**
```cmake
add_subdirectory(base)       # 第477行 - base 先加载
add_subdirectory(compiler)   # 第478行
add_subdirectory(core)       # 第479行
add_subdirectory(profiler)   # 第482行 - profiler 后加载
```

**base/CMakeLists.txt 中 RDC 的依赖声明（第200-206行）：**
```cmake
RUNTIME_DEPS
  ROCR-Runtime
  amdsmi
  rocprofiler-sdk          # ❌ 问题：此时 rocprofiler-sdk 还未被声明
  ${THEROCK_BUNDLED_LIBCAP}
  ${THEROCK_BUNDLED_ZLIB}
  ${THEROCK_BUNDLED_GRPC}
```

**profiler/CMakeLists.txt 中 rocprofiler-sdk 的声明（第1行和第64行）：**
```cmake
if(THEROCK_ENABLE_ROCPROFV3)          # 第1行 - 条件判断
  # ... 其他代码 ...
  
  therock_cmake_subproject_declare(rocprofiler-sdk  # 第64行
    USE_DIST_AMDGPU_TARGETS
    EXTERNAL_SOURCE_DIR "${THEROCK_ROCM_SYSTEMS_SOURCE_DIR}/projects/rocprofiler-sdk"
    # ...
  )
endif()
```

### 问题的执行流程

1. **CMake 处理 base/CMakeLists.txt**（第477行）
   - 检测到 `THEROCK_ENABLE_RDC=ON`
   - 执行 `therock_cmake_subproject_declare(rdc ...)`
   - 尝试验证 RUNTIME_DEPS 中的 `rocprofiler-sdk`
   - ❌ **失败**：`rocprofiler-sdk` 子项目尚未被声明

2. **CMake 还未处理 profiler/CMakeLists.txt**（第482行）
   - 此时 `rocprofiler-sdk` 还没有被声明

3. **依赖验证失败，配置中断**

### 问题 2：Feature 依赖与子项目依赖的时序差异

**RDC 的 Feature 定义（CMakeLists.txt 第266-270行）：**
```cmake
therock_add_feature(RDC
  GROUP SYS_TOOLS
  DESCRIPTION "Enables ROCm Data Center Tool (RDC)"
  REQUIRES CORE_RUNTIME ROCPROFV3    # Feature 层面的依赖
)
```

**Feature 依赖的自动解析（CMakeLists.txt 第356行）：**
```cmake
therock_finalize_features()  # 这会自动启用 ROCPROFV3
therock_report_features()
```

**问题：**
- Feature 系统会在 `therock_finalize_features()` 时自动启用 `ROCPROFV3`
- 这意味着 `THEROCK_ENABLE_ROCPROFV3` 会被设置为 `ON`
- 但这发生在 **feature 定义阶段**，早于 `add_subdirectory()` 阶段
- 当 `add_subdirectory(base)` 执行时，`rocprofiler-sdk` 子项目还未被声明
- CMake 的子项目依赖验证机制检测到未定义的依赖项，导致配置失败

## 解决方案

### 方案 A：调整目录加载顺序（推荐）✅

**改动：** 将 `add_subdirectory(profiler)` 移到 `add_subdirectory(base)` 之前

**原理：** 确保 `rocprofiler-sdk` 在 RDC 需要引用它之前就已经被声明

**优点：**
- ✅ 最小改动
- ✅ 逻辑清晰
- ✅ 不改变功能

**缺点：**
- ⚠️ 可能影响其他依赖关系（需要验证）
- ⚠️ base 中的 rocprofiler-register 是 profiler 的基础依赖，这种调整可能不符合逻辑层次

### 方案 B：将 RDC 移到 profiler 目录（推荐）✅✅

**改动：** 将 RDC 的构建配置从 `base/CMakeLists.txt` 移到 `profiler/CMakeLists.txt`

**位置：** 在 `profiler/CMakeLists.txt` 的 `if(THEROCK_ENABLE_ROCPROFV3)` 块内

**原理：** 
- RDC 依赖 rocprofiler-sdk，两者都需要 ROCPROFV3
- 将它们放在同一个条件块和同一个 CMakeLists.txt 中更合理

**优点：**
- ✅ 逻辑上更合理：RDC 是数据中心工具，依赖 profiler SDK
- ✅ 依赖关系清晰：都在同一个条件块内
- ✅ 符合功能分组：RDC 使用 profiler 功能

**缺点：**
- ⚠️ RDC 不再属于 base 层，而是属于 profiler 层
- ⚠️ 需要更新 artifact 路径

### 方案 C：移除 rocprofiler-sdk 的 RUNTIME_DEPS（需验证）

**改动：** 从 RDC 的 RUNTIME_DEPS 中移除 `rocprofiler-sdk`

**前提：** 需要验证 RDC 是否真的需要 rocprofiler-sdk 作为运行时依赖

**优点：**
- ✅ 最小代码改动

**缺点：**
- ❌ 可能破坏 RDC 的功能（如果确实需要这个依赖）
- ❌ 不解决根本问题

### 方案 D：延迟依赖验证（复杂）

**改动：** 修改 TheRock 的子项目系统，延迟 RUNTIME_DEPS 的验证

**优点：**
- ✅ 彻底解决跨目录依赖问题

**缺点：**
- ❌ 需要修改核心构建系统
- ❌ 工作量大
- ❌ 可能引入新问题

## 推荐方案详解：方案 B - 将 RDC 移到 profiler 目录

### 实施步骤

#### 1. 从 base/CMakeLists.txt 移除 RDC 配置

删除第 167-230 行的 RDC 配置块：
```cmake
# 删除这整段
################################################################################
# RDC (ROCm Data Center Tool)
################################################################################

if(THEROCK_ENABLE_RDC)
  # ... 整个 RDC 配置 ...
endif()
```

删除第 243-245 行的依赖添加：
```cmake
# 删除这段
if(THEROCK_ENABLE_RDC)
  list(APPEND _optional_subproject_deps rdc)
endif()
```

#### 2. 将 RDC 配置添加到 profiler/CMakeLists.txt

在 `if(THEROCK_ENABLE_ROCPROFV3)` 块内，rocprofiler-sdk 之后添加：

```cmake
# 在 profiler/CMakeLists.txt 中，找到 rocprofiler-sdk 的声明后，添加：

##############################################################################
# RDC (ROCm Data Center Tool)
##############################################################################

if(THEROCK_ENABLE_RDC)
  # Point GRPC_ROOT to the actual gRPC build location
  set(_grpc_build_path "${THEROCK_BINARY_DIR}/third-party/sysdeps/linux/grpc/build/stage/lib/rocm_sysdeps")

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
      "-DGRPC_ROOT=${_grpc_build_path}"
      -DGRPC_DESIRED_VERSION=1.76.0
      "-DCMAKE_PROGRAM_PATH=${_grpc_build_path}/bin"

    BUILD_DEPS
      amd-llvm

    RUNTIME_DEPS
      ROCR-Runtime
      amdsmi
      rocprofiler-sdk  # 现在这个依赖已经在同一个文件中声明了
      ${THEROCK_BUNDLED_LIBCAP}
      ${THEROCK_BUNDLED_ZLIB}
      ${THEROCK_BUNDLED_GRPC}

    INTERFACE_LINK_DIRS
      lib
  )

  therock_cmake_subproject_glob_c_sources(rdc
    SUBDIRS .
  )

  therock_cmake_subproject_provide_package(rdc rdc lib/cmake/rdc)

  therock_cmake_subproject_activate(rdc)

  # RDC: use custom bash script to validate shared libraries
  foreach(lib_name librdc_rocr.so librdc_rocp.so)
    add_test(
      NAME therock-validate-shared-lib-${lib_name}
      COMMAND
        "${CMAKE_SOURCE_DIR}/profiler/validate_rdc_library.sh"
          "${CMAKE_CURRENT_BINARY_DIR}/rdc/dist/lib/rdc/${lib_name}"
    )
  endforeach()

endif()
```

#### 3. 移动测试脚本

```bash
mv base/validate_rdc_library.sh profiler/validate_rdc_library.sh
```

#### 4. 更新 artifact 配置

从 `base/artifact.toml` 移除 RDC 部分（第77-100行）

在 `profiler/artifact-rdc.toml` 中创建或更新：
```toml
# profiler/artifact-rdc.toml
[components.dbg."profiler/rdc/stage"]
[components.dev."profiler/rdc/stage"]
include = [
  "include/**",
  "lib/cmake/**",
  "lib/rdc/grpc/**",
]
[components.doc."profiler/rdc/stage"]
include = [
  "share/doc/rdc/**",
]
[components.lib."profiler/rdc/stage"]
include = [
  "lib/*.so*",
  "lib/rdc/*.so*",
]
[components.run."profiler/rdc/stage"]
include = [
  "lib/*.so*",
  "lib/rdc/*.so*",
  "libexec/rdc/**",
  "share/rdc/**",
]
```

#### 5. 在 profiler/CMakeLists.txt 末尾添加 artifact 声明

```cmake
# 在 profiler/CMakeLists.txt 的 if(THEROCK_ENABLE_ROCPROFV3) 块末尾
# （但仍在 endif() 之前）添加：

if(THEROCK_ENABLE_RDC)
  therock_provide_artifact(rdc
    TARGET_NEUTRAL
    DESCRIPTOR artifact-rdc.toml
    COMPONENTS
      dbg
      dev
      doc
      lib
      run
    SUBPROJECT_DEPS
      amdsmi
      rocprofiler-sdk
      rdc
  )
endif()
```

### 路径变化

| 项目 | 当前路径（错误的） | 新路径（修正后） |
|------|-------------------|-----------------|
| 构建目录 | `build/base/rdc/` | `build/profiler/rdc/` |
| Stage | `base/rdc/stage/` | `profiler/rdc/stage/` |
| 测试脚本 | `base/validate_rdc_library.sh` | `profiler/validate_rdc_library.sh` |
| Artifact | base artifact 的一部分 | 独立的 rdc artifact |

## 为什么方案 B 更合理？

### 1. 功能定位
- RDC (ROCm Data Center Tool) 的核心功能包括**性能监控和分析**
- RDC 依赖 `rocprofiler-sdk` 来提供 profiling 能力
- 将 RDC 放在 profiler 目录下更符合其功能定位

### 2. 依赖关系
```
profiler/
  ├── rocprofiler-sdk    (提供 profiling API)
  └── rdc                (使用 profiling API 的工具)
```

### 3. 条件编译
- RDC 的 Feature 要求 `REQUIRES ROCPROFV3`
- profiler 的所有内容都在 `if(THEROCK_ENABLE_ROCPROFV3)` 内
- 将 RDC 也放在这个条件块内，逻辑更清晰

### 4. 与 RFC0003 的关系
虽然 RFC0003 建议不同的目录结构，但在当前架构下：
- `profiler/` 是 profiling 相关工具的自然归属
- `base/` 应该是更基础的、不依赖 profiler 的组件
- RDC 依赖 profiler，所以不应该在 base 层

## 临时快速修复（如果不想大改）

如果不想进行方案 B 的大改动，可以使用这个临时方案：

**在运行构建命令时显式启用 ROCPROFV3：**
```bash
extra_cmake_options="-DTHEROCK_ENABLE_MATH_LIBS=OFF \
                     -DTHEROCK_ENABLE_ML_LIBS=OFF \
                     -DTHEROCK_ENABLE_RCCL=OFF \
                     -DTHEROCK_ENABLE_RDC=ON \
                     -DTHEROCK_ENABLE_ROCPROFV3=ON"  # 添加这一行
```

**原理：**
- 显式启用 ROCPROFV3 确保在处理 profiler/CMakeLists.txt 时会声明 rocprofiler-sdk
- 虽然 Feature 系统会自动启用，但显式指定可以确保时序正确

**局限性：**
- ⚠️ 这不是根本解决方案
- ⚠️ 仍然存在依赖顺序问题
- ⚠️ 可能在某些情况下仍然失败

## 总结

**根本原因：**
RDC 在 `base/` 中声明，但依赖在 `profiler/` 中声明的 `rocprofiler-sdk`，而 `base/` 在 `profiler/` 之前被处理。

**推荐解决方案：**
采用**方案 B**，将 RDC 从 `base/` 移到 `profiler/`，因为：
1. ✅ 功能上更合理（RDC 是 profiling 工具）
2. ✅ 彻底解决依赖顺序问题
3. ✅ 逻辑上更清晰（都在 ROCPROFV3 条件块内）
4. ✅ 符合软件分层原则

**临时解决方案：**
在命令行中添加 `-DTHEROCK_ENABLE_ROCPROFV3=ON`

