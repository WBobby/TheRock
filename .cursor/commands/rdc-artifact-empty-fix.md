# RDC Artifact 空包问题分析与解决方案

## 🐛 问题

RDC 的 artifact tar 包只有 264 字节，几乎为空：

```bash
$ ls -lh build-3/artifacts/rdc*.tar.xz
-rw-r--r-- 1 root root 264 Nov 10 02:05 rdc_dbg_generic.tar.xz
-rw-r--r-- 1 root root 264 Nov 10 02:05 rdc_dev_generic.tar.xz
-rw-r--r-- 1 root root 264 Nov 10 02:05 rdc_doc_generic.tar.xz
-rw-r--r-- 1 root root 264 Nov 10 02:05 rdc_lib_generic.tar.xz
-rw-r--r-- 1 root root 264 Nov 10 02:05 rdc_run_generic.tar.xz

$ tar -tf rdc_lib_generic.tar.xz
artifact_manifest.txt  # ← 只有一个 manifest 文件！
```

---

## 🔍 根本原因

### RDC 构建路径配置错误

**问题文件**: `profiler/CMakeLists.txt` Line 141-143

```cmake
therock_cmake_subproject_declare(rdc
  EXTERNAL_SOURCE_DIR "${THEROCK_ROCM_SYSTEMS_SOURCE_DIR}/projects/rdc"
  BACKGROUND_BUILD
  # ❌ 缺少 BINARY_DIR 配置！
```

### 对比其他 profiler 子项目

| 子项目 | BINARY_DIR 配置 | 安装目录 |
|--------|----------------|----------|
| **aqlprofile** | `BINARY_DIR "${CMAKE_CURRENT_BINARY_DIR}/aqlprofile"` | `profiler/aqlprofile/stage/` ✅ |
| **rocprofiler-sdk** | `BINARY_DIR "${CMAKE_CURRENT_BINARY_DIR}/rocprofiler-sdk"` | `profiler/rocprofiler-sdk/stage/` ✅ |
| **roctracer** | `BINARY_DIR "${CMAKE_CURRENT_BINARY_DIR}/roctracer"` | `profiler/roctracer/stage/` ✅ |
| **rdc** | ❌ **未指定** | `profiler/stage/` ❌ **错误位置** |

---

## 📂 当前 RDC 文件位置

### 实际安装位置（错误）

```bash
$ ls build-3/profiler/stage/
bin/
├── rdcd          # ← RDC daemon
├── rdci          # ← RDC CLI
lib/
├── librdc_bootstrap.so.1.2
├── librdc_client.so.1.2
├── librdc.so.1.2
└── rdc/
    ├── librdc_rocr.so.1.2
    └── librdc_rocp.so.1.2
```

**路径**: `build-3/profiler/stage/`

### artifact-rdc.toml 期望的位置

**文件**: `profiler/artifact-rdc.toml`

```toml
[components.lib."profiler/rdc/stage"]  # ← 期望在 profiler/rdc/stage
include = [
  "lib/*.so*",
  "lib/rdc/*.so*",
]

[components.run."profiler/rdc/stage"]  # ← 期望在 profiler/rdc/stage
include = [
  "bin/**",
  "libexec/rdc/**",
  "share/rdc/**",
]
```

**期望路径**: `build-3/profiler/rdc/stage/`

### 路径不匹配！

```
实际:  build-3/profiler/stage/bin/rdcd
期望:  build-3/profiler/rdc/stage/bin/rdcd
        ^^^^^^^^^^^^^^^   ^^^^
                          缺少 rdc/
```

**结果**: Artifact 打包时找不到任何文件！ ❌

---

## ✅ 解决方案

### 方案 A: 添加 BINARY_DIR（推荐） ⭐

**优点**:
- ✅ 符合 TheRock 标准模式
- ✅ 与其他 profiler 子项目一致
- ✅ 无需修改 artifact-rdc.toml
- ✅ 目录结构清晰

**缺点**:
- 需要重新构建 RDC

**修改**: `profiler/CMakeLists.txt` Line 141-143

```cmake
therock_cmake_subproject_declare(rdc
  EXTERNAL_SOURCE_DIR "${THEROCK_ROCM_SYSTEMS_SOURCE_DIR}/projects/rdc"
  BINARY_DIR "${CMAKE_CURRENT_BINARY_DIR}/rdc"  # ← 添加这一行
  BACKGROUND_BUILD
```

**预期结果**:
```bash
build-3/profiler/rdc/stage/
├── bin/
│   ├── rdcd
│   └── rdci
├── lib/
│   ├── librdc_bootstrap.so.1.2
│   ├── librdc_client.so.1.2
│   ├── librdc.so.1.2
│   └── rdc/
│       ├── librdc_rocr.so.1.2
│       └── librdc_rocp.so.1.2
├── include/
│   └── rdc/
│       └── rdc.h
└── share/
    └── rdc/
        └── ...
```

---

### 方案 B: 修改 artifact-rdc.toml

**优点**:
- 不需要重新构建 RDC

**缺点**:
- ❌ 与 TheRock 标准模式不一致
- ❌ profiler/stage 会混入 RDC 文件
- ❌ 不符合 profiler 其他子项目的结构

**修改**: `profiler/artifact-rdc.toml`

```toml
# 将所有 "profiler/rdc/stage" 改为 "profiler/stage"
[components.lib."profiler/stage"]
include = [
  "lib/librdc*.so*",      # 需要更精确的匹配避免冲突
  "lib/rdc/*.so*",
]

[components.run."profiler/stage"]
include = [
  "bin/rdcd",             # 需要精确指定避免包含其他文件
  "bin/rdci",
  "libexec/rdc/**",
  "share/rdc/**",
]
```

**问题**: 会导致 profiler/stage 目录混乱，不推荐。

---

## 🔧 推荐实施步骤

### 使用方案 A（推荐）

#### 步骤 1: 修改 CMakeLists.txt

```bash
# 在 profiler/CMakeLists.txt 的 therock_cmake_subproject_declare(rdc ...) 中添加：
BINARY_DIR "${CMAKE_CURRENT_BINARY_DIR}/rdc"
```

#### 步骤 2: 清理旧构建

```bash
# 清理 RDC 旧的构建产物
rm -rf build-3/profiler/build
rm -rf build-3/profiler/stage
rm -rf build-3/profiler/dist

# 或者只清理 RDC 相关
cmake --build build-3 --target profiler/rdc+expunge
```

#### 步骤 3: 重新配置和构建

```bash
# 重新配置（更新 CMake 缓存）
cmake --build build-3 --target reconfigure

# 或完全重新配置
cmake -B build-3 -GNinja . \
  -DTHEROCK_AMDGPU_FAMILIES=gfx1151 \
  -DTHEROCK_ENABLE_MATH_LIBS=OFF \
  -DTHEROCK_ENABLE_ML_LIBS=OFF \
  -DTHEROCK_ENABLE_RCCL=OFF \
  -DTHEROCK_ENABLE_RDC=ON

# 构建 RDC
cmake --build build-3 --target rdc

# 打包 artifacts
cmake --build build-3 --target archive-rdc
```

#### 步骤 4: 验证

```bash
# 检查文件位置
ls -la build-3/profiler/rdc/stage/bin/
# 应该看到: rdcd, rdci

# 检查 artifact 大小
ls -lh build-3/artifacts/rdc*.tar.xz
# 应该看到: 几百 KB 或 MB，不是 264 字节

# 检查 artifact 内容
tar -tf build-3/artifacts/rdc_run_generic.tar.xz | head -10
# 应该看到: bin/rdcd, bin/rdci, libexec/rdc/...
```

---

## 📝 代码修改详情

### 修改文件: profiler/CMakeLists.txt

**Line 141-169** (修改前):

```cmake
  if(THEROCK_ENABLE_RDC)
    # RDC depends on gRPC for both runtime (libgrpc++.so) and build-time (protoc, grpc_cpp_plugin).
    # RUNTIME_DEPS includes ${THEROCK_BUNDLED_GRPC} which ensures:
    # 1. gRPC is built before RDC
    # 2. CMAKE_PREFIX_PATH includes gRPC's stage directory
    # 3. find_package(gRPC) and find_package(protobuf) will find the config files
    # 4. gRPCConfig.cmake exports tool targets (gRPC::grpc_cpp_plugin, protobuf::protoc)
    #
    # No hardcoded paths needed - all dependencies are resolved via CMake's standard mechanisms.

    therock_cmake_subproject_declare(rdc
      EXTERNAL_SOURCE_DIR "${THEROCK_ROCM_SYSTEMS_SOURCE_DIR}/projects/rdc"
      BACKGROUND_BUILD

      CMAKE_ARGS
        -DBUILD_PROFILER=ON
        # Enable rdcd and rdci with standalone mode
        -DBUILD_STANDALONE=ON
        -DBUILD_RUNTIME=ON
        -DBUILD_RVS=OFF
        -DBUILD_TESTS=${THEROCK_BUILD_TESTING}
        -DHIP_PLATFORM=amd
        -DCMAKE_CXX_STANDARD=17

      BUILD_DEPS
        amd-llvm

      RUNTIME_DEPS
        ROCR-Runtime
```

**Line 141-169** (修改后):

```cmake
  if(THEROCK_ENABLE_RDC)
    # RDC depends on gRPC for both runtime (libgrpc++.so) and build-time (protoc, grpc_cpp_plugin).
    # RUNTIME_DEPS includes ${THEROCK_BUNDLED_GRPC} which ensures:
    # 1. gRPC is built before RDC
    # 2. CMAKE_PREFIX_PATH includes gRPC's stage directory
    # 3. find_package(gRPC) and find_package(protobuf) will find the config files
    # 4. gRPCConfig.cmake exports tool targets (gRPC::grpc_cpp_plugin, protobuf::protoc)
    #
    # No hardcoded paths needed - all dependencies are resolved via CMake's standard mechanisms.

    therock_cmake_subproject_declare(rdc
      EXTERNAL_SOURCE_DIR "${THEROCK_ROCM_SYSTEMS_SOURCE_DIR}/projects/rdc"
      BINARY_DIR "${CMAKE_CURRENT_BINARY_DIR}/rdc"  # ← 添加这一行
      BACKGROUND_BUILD

      CMAKE_ARGS
        -DBUILD_PROFILER=ON
        # Enable rdcd and rdci with standalone mode
        -DBUILD_STANDALONE=ON
        -DBUILD_RUNTIME=ON
        -DBUILD_RVS=OFF
        -DBUILD_TESTS=${THEROCK_BUILD_TESTING}
        -DHIP_PLATFORM=amd
        -DCMAKE_CXX_STANDARD=17

      BUILD_DEPS
        amd-llvm

      RUNTIME_DEPS
        ROCR-Runtime
```

---

## 🧪 测试清单

构建完成后，验证以下内容：

### 1. 目录结构

```bash
$ ls -la build-3/profiler/
drwxr-xr-x aqlprofile/
drwxr-xr-x rdc/           # ← 应该存在
drwxr-xr-x rocprofiler-sdk/
drwxr-xr-x roctracer/
```

### 2. RDC Stage 目录

```bash
$ ls build-3/profiler/rdc/stage/
bin/
include/
lib/
libexec/
share/
```

### 3. Artifact 大小

```bash
$ ls -lh build-3/artifacts/rdc*.tar.xz
-rw-r--r-- 1 root root  XXK Nov 10 XX:XX rdc_dbg_generic.tar.xz
-rw-r--r-- 1 root root XXXK Nov 10 XX:XX rdc_dev_generic.tar.xz
-rw-r--r-- 1 root root  XXK Nov 10 XX:XX rdc_doc_generic.tar.xz
-rw-r--r-- 1 root root XXXK Nov 10 XX:XX rdc_lib_generic.tar.xz
-rw-r--r-- 1 root root XXXK Nov 10 XX:XX rdc_run_generic.tar.xz
# 应该是 KB 或 MB，不是 264 字节
```

### 4. Artifact 内容

```bash
$ tar -tf build-3/artifacts/rdc_run_generic.tar.xz
artifact_manifest.txt
bin/rdcd
bin/rdci
libexec/rdc/...
share/rdc/...
# 应该包含实际文件，不只是 manifest
```

### 5. Validation 测试

```bash
$ ctest --test-dir build-3 -R "therock-validate-shared-lib-librdc"
Test #16: therock-validate-shared-lib-librdc_bootstrap.so ... Passed
Test #17: therock-validate-shared-lib-librdc_client.so ..... Passed

100% tests passed, 0 tests failed out of 2
```

---

## ✅ 总结

| 项目 | 状态 |
|------|------|
| **问题原因** | ✅ 已找到：RDC 缺少 `BINARY_DIR` 配置 |
| **推荐方案** | ✅ 方案 A：添加 `BINARY_DIR` |
| **代码修改** | ✅ 仅需 1 行改动 |
| **影响范围** | ✅ 仅影响 RDC，无副作用 |
| **修复难度** | ✅ 简单 |

**下一步**: 选择方案后立即实施！

