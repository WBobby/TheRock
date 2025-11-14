# RDC 依赖验证分析

**问题**: 是否应该验证 RDC 的依赖（libcap 和 gRPC）以确保它们被创建？

---

## 🎯 核心原则：每个包负责验证自己

### TheRock 的设计哲学

**包职责边界**:
- ✅ 每个包验证**自己**的库文件
- ❌ 包**不应该**验证依赖的库文件
- ✅ 依赖管理由 CMake 的 `RUNTIME_DEPS` 系统处理

**原因**:
1. **单一职责**: 每个包只关心自己的输出
2. **避免重复**: 如果 RDC 验证 libcap，而 libcap 自己也验证，就重复了
3. **构建顺序**: CMake 已经通过依赖系统保证了构建顺序
4. **失败传播**: 如果依赖构建失败，依赖它的包不会开始构建

---

## 📊 当前状态

### 1. libcap 的验证状态 ✅

**已有验证**: `third-party/sysdeps/linux/libcap/CMakeLists.txt`

```cmake
therock_cmake_subproject_activate(therock-libcap)

therock_test_validate_shared_lib(
  PATH build/dist/lib/rocm_sysdeps/lib
  LIB_NAMES libcap.so
)
```

**结论**: ✅ libcap 已经验证自己，RDC 不需要重复验证

---

### 2. gRPC 的验证状态 ❌

**当前状态**: `third-party/sysdeps/linux/grpc/CMakeLists.txt` **没有验证**

**问题**: 
- gRPC 构建了多个共享库（libgrpc++.so, libprotobuf.so 等）
- gRPC 构建了工具（grpc_cpp_plugin, protoc）
- 但**没有验证**这些是否正确生成

**影响**:
- 如果 gRPC 构建不完整，可能在运行时才发现
- RDC 依赖 gRPC，但 gRPC 没有自我验证

**建议**: ✅ 应该为 gRPC 添加验证（在 gRPC 自己的 CMakeLists.txt 中）

---

### 3. RDC 的验证状态 ⏳

**当前状态**: 刚刚删除了自定义验证脚本

**应该做的**:
- ✅ 验证 RDC 自己的库（librdc.so, librdc_rocr.so 等）
- ❌ **不**验证依赖的库（libcap, gRPC）

---

## ✅ 完整的验证方案

### 方案：三层验证架构

```
libcap (sysdeps)    → 验证 libcap.so
   ↓
gRPC (sysdeps)      → 验证 libgrpc++.so, libprotobuf.so, grpc_cpp_plugin
   ↓
RDC (profiler)      → 验证 librdc.so, librdc_rocr.so, librdc_rocp.so
```

**每个包验证自己，依赖由 CMake 保证**

---

## 🔧 具体实施

### A. 为 gRPC 添加验证（推荐）

**文件**: `third-party/sysdeps/linux/grpc/CMakeLists.txt`

**添加位置**: 在 `therock_cmake_subproject_activate(therock-grpc)` 之后

```cmake
therock_cmake_subproject_activate(therock-grpc)

# Validate gRPC shared libraries and tools
therock_test_validate_shared_lib(
  PATH build/dist/lib/rocm_sysdeps/lib
  LIB_NAMES
    libgrpc++.so
    libprotobuf.so
    libgrpc.so
    libaddress_sorting.so
    libre2.so
    libupb.so
)

# Note: grpc_cpp_plugin and protoc are executables in bin/
# They will be validated when RDC uses them during build
```

**优点**:
- ✅ gRPC 验证自己的输出
- ✅ 如果 gRPC 构建不完整，立即发现
- ✅ 符合 TheRock 的设计原则

---

### B. 为 RDC 添加验证（必需）

**文件**: `profiler/CMakeLists.txt`

**添加位置**: 在 `therock_cmake_subproject_activate(rdc)` 之后

```cmake
therock_cmake_subproject_activate(rdc)

# Validate RDC shared libraries
therock_test_validate_shared_lib(
  PATH rdc/dist/lib/rdc
  LIB_NAMES
    librdc.so
    librdc_bootstrap.so
    librdc_rocr.so
    librdc_rocp.so
)

# Provide RDC artifact
```

**优点**:
- ✅ RDC 验证自己的输出
- ✅ 使用标准方式
- ✅ 不验证依赖（避免重复）

---

## ❓ 为什么不在 RDC 中验证依赖？

### 场景分析

#### 场景 1: 依赖构建失败

```bash
# 构建 libcap 失败
cmake --build build-3 --target therock-libcap
# ❌ 失败，停止

# RDC 不会开始构建（因为 RUNTIME_DEPS）
cmake --build build-3 --target rdc
# CMake 报错: therock-libcap 未构建
```

**结论**: ✅ CMake 依赖系统已经处理了这种情况

#### 场景 2: 依赖构建成功但验证失败

```bash
# 构建 libcap 成功
cmake --build build-3 --target therock-libcap
# ✅ 成功

# 验证 libcap 失败（假设它有验证）
ctest -R therock-validate-shared-lib-libcap
# ❌ 失败

# RDC 会构建（因为 CMake 只看构建是否成功）
cmake --build build-3 --target rdc
# ✅ 可能成功构建，但运行时会失败
```

**问题**: 
- ⚠️ 如果依赖的验证失败，但构建标记为成功
- ⚠️ RDC 会继续构建，但可能在运行时失败

**解决方案**:
1. **最佳**: 让 CI 在构建后运行所有验证（`ctest`）
2. **次优**: RDC 验证自己的库，运行时会暴露依赖问题
3. **不推荐**: RDC 重复验证依赖

---

## 💡 推荐的最终方案

### 立即实施

#### 1. 为 RDC 添加验证 ✅

```cmake
# profiler/CMakeLists.txt
therock_cmake_subproject_activate(rdc)

therock_test_validate_shared_lib(
  PATH rdc/dist/lib/rdc
  LIB_NAMES
    librdc.so
    librdc_bootstrap.so
    librdc_rocr.so
    librdc_rocp.so
)
```

**理由**: 
- RDC 是您的包，必须验证
- 这是标准做法

#### 2. 为 gRPC 添加验证 ✅

```cmake
# third-party/sysdeps/linux/grpc/CMakeLists.txt
therock_cmake_subproject_activate(therock-grpc)

therock_test_validate_shared_lib(
  PATH build/dist/lib/rocm_sysdeps/lib
  LIB_NAMES
    libgrpc++.so
    libprotobuf.so
    libgrpc.so
)
```

**理由**:
- gRPC 目前没有验证（遗漏）
- 应该补上（这是 TheRock 的改进）

#### 3. libcap 不需要改动 ✅

**理由**: libcap 已经有验证

---

### CI 层面的保证

**在 CI 中运行所有验证**:

```bash
# 构建所有目标
cmake --build build-3

# 运行所有验证测试
ctest --test-dir build-3 -R therock-validate
```

**这样确保**:
- ✅ 每个包都验证了自己
- ✅ 依赖关系正确
- ✅ 如果任何验证失败，CI 会报错

---

## 📊 验证覆盖表

| 包 | 验证状态 | 验证内容 | 行动 |
|----|---------|---------|------|
| **libcap** | ✅ 已有 | libcap.so | 无需改动 |
| **gRPC** | ❌ 缺失 | libgrpc++.so, libprotobuf.so | **添加验证** |
| **RDC** | ⏳ 待添加 | librdc*.so | **添加验证** |

---

## 🎯 总结回答

### 您的问题：是否应该考虑验证 RDC 的依赖？

**简短答案**: ❌ **不需要**在 RDC 中验证依赖

**完整答案**:

1. **设计原则**: 每个包验证自己，不验证依赖
   - ✅ libcap 验证 libcap
   - ✅ gRPC 验证 gRPC（需要添加）
   - ✅ RDC 验证 RDC（需要添加）

2. **依赖保证**: 由 CMake 的 `RUNTIME_DEPS` 系统保证
   - 构建顺序自动正确
   - 如果依赖未构建，RDC 不会开始构建

3. **应该做的**:
   - ✅ 为 RDC 添加验证（验证 RDC 自己的库）
   - ✅ 为 gRPC 添加验证（gRPC 目前缺失验证）
   - ✅ 在 CI 中运行 `ctest` 确保所有验证通过

4. **不应该做的**:
   - ❌ 在 RDC 中验证 libcap（libcap 已经验证自己）
   - ❌ 在 RDC 中验证 gRPC（gRPC 应该验证自己）

---

## ✅ 立即行动

### 改动 1: RDC 验证（profiler/CMakeLists.txt）

```cmake
therock_cmake_subproject_activate(rdc)

# Validate RDC shared libraries
therock_test_validate_shared_lib(
  PATH rdc/dist/lib/rdc
  LIB_NAMES
    librdc.so
    librdc_bootstrap.so
    librdc_rocr.so
    librdc_rocp.so
)

# Provide RDC artifact
```

### 改动 2: gRPC 验证（third-party/sysdeps/linux/grpc/CMakeLists.txt）

```cmake
therock_cmake_subproject_activate(therock-grpc)

# Validate gRPC shared libraries
therock_test_validate_shared_lib(
  PATH build/dist/lib/rocm_sysdeps/lib
  LIB_NAMES
    libgrpc++.so
    libprotobuf.so
    libgrpc.so
    libaddress_sorting.so
    libre2.so
    libupb.so
)

therock_provide_artifact(...)
```

**就这两个改动！** ✅

