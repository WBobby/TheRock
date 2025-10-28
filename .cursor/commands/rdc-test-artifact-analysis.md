# RDC 测试和 Artifact 问题分析

**日期**: 2025-11-09  
**Code Reviewer 关切**: 4个问题

---

## 📋 Code Reviewer 的关切点

### 关切 1: 测试添加方式不正确

**Reviewer 反馈**:
> "This is not how we add tests. With this you add tests at TheRock but those need to be bundled targets which are packed in artifacts. TheRock will not exec tests in current way."

**当前代码** (`profiler/CMakeLists.txt` Line 179-186):
```cmake
# RDC: use custom bash script to validate shared libraries
foreach(lib_name librdc_rocr.so librdc_rocp.so)
  add_test(
    NAME therock-validate-shared-lib-${lib_name}
    COMMAND
      "${CMAKE_CURRENT_SOURCE_DIR}/validate_rdc_library.sh"
        "${CMAKE_CURRENT_BINARY_DIR}/rdc/dist/lib/rdc/${lib_name}"
  )
endforeach()
```

### 关切 2: BUILD_TESTS 标志不正确

**Reviewer 反馈**:
> "-DBUILD_TESTS=ON 改为 -DBUILD_TESTS=${THEROCK_BUILD_TESTING}？"

**当前代码** (`profiler/CMakeLists.txt` Line 151):
```cmake
-DBUILD_TESTS=ON
```

### 关切 3: artifact-rdc.toml 组件划分不正确

**Reviewer 反馈**:
> "Those are included in components.lib. The artifact components.run will depend on components.lib and needs to use the libs there."

**当前代码** (`profiler/artifact-rdc.toml`):
```toml
[components.lib."profiler/rdc/stage"]
include = [
  "lib/*.so*",
  "lib/rdc/*.so*",
]
[components.run."profiler/rdc/stage"]
include = [
  "lib/*.so*",        # ❌ 重复！
  "lib/rdc/*.so*",    # ❌ 重复！
  "libexec/rdc/**",
  "share/rdc/**",
]
```

### 关切 4: validate_rdc_library.sh 测试方式不正确

**Reviewer 反馈**:
> "This is not how tests get executed in TheRock, see my previous comment."

**当前文件**: `profiler/validate_rdc_library.sh`

---

## 🔍 TheRock 测试和 Artifact 系统分析

### TheRock 如何处理测试

**文档**: `docs/development/adding_tests.md`

#### 1. 测试流程

```
构建 artifacts → 打包上传 → 下载测试 artifacts → 运行测试脚本
```

**关键点**:
- ✅ 测试**不在构建时运行**
- ✅ 测试在**独立的测试阶段**运行（test_artifacts.yml workflow）
- ✅ 测试通过**Python脚本**执行（在 `build_tools/github_actions/test_executable_scripts/`）
- ✅ 测试可执行文件打包在 **`components.test`** 中

#### 2. 测试添加步骤

**步骤 A**: 构建测试可执行文件
```cmake
therock_cmake_subproject_declare(rdc
  CMAKE_ARGS
    -DBUILD_TESTS=${THEROCK_BUILD_TESTING}  # 使用 TheRock 的测试标志
)
```

**步骤 B**: 在 artifact.toml 中添加 test 组件
```toml
[components.test."profiler/rdc/stage"]
include = [
  "bin/rdc-test",           # 测试可执行文件
  "share/rdc/tests/**",     # 测试数据文件
]
```

**步骤 C**: 创建测试脚本
```python
# build_tools/github_actions/test_executable_scripts/test_rdc.py
cmd = [f"{THEROCK_BIN_DIR}/rdc-test", "--gtest_filter=*"]
subprocess.run(cmd, check=True)
```

**步骤 D**: 在 fetch_test_configurations.py 中注册
```python
"rdc": {
    "job_name": "rdc",
    "fetch_artifact_args": "--profiler --tests",
    "timeout_minutes": 10,
    "test_script": f"python {_get_script_path('test_rdc.py')}",
    "platform": ["linux"],
}
```

### TheRock Artifact 组件类型

**文档**: `docs/development/artifacts.md`

#### 标准组件类型

| 组件 | 用途 | 包含内容 |
|------|------|----------|
| **dbg** | 调试符号 | .debug 文件 |
| **dev** | 开发依赖 | 头文件、CMake配置、静态库、构建工具 |
| **lib** | 运行时库 | 共享库 (.so, .dll) |
| **run** | 运行时工具 | CLI 工具、配置文件、数据文件 |
| **test** | 测试 | 测试可执行文件、测试数据 |

#### 组件依赖关系

```
dev = lib + 头文件 + CMake配置
run = lib + 可执行文件 + 数据文件
test = lib + 测试可执行文件
```

**重要原则**: 
- ❌ **不应该重复包含文件**
- ✅ `run` 和 `test` **依赖** `lib`，不需要重复包含 .so 文件

---

## ✅ 问题分析和解决方案

### 问题 1: add_test() 方式不正确 ❌

**当前问题**:
```cmake
add_test(NAME therock-validate-shared-lib-${lib_name} ...)
```

**为什么不对**:
1. ❌ `add_test()` 在**构建时**定义测试，但 TheRock 在**独立测试阶段**运行测试
2. ❌ `validate_rdc_library.sh` 是自定义脚本，不符合 TheRock 测试框架
3. ❌ 测试不会被打包到 artifacts 中
4. ❌ CI 流程无法发现和运行这些测试

**正确做法**:
- 让 RDC 构建自己的测试可执行文件（如果有）
- 将测试文件打包到 `components.test`
- 创建 Python 测试脚本调用测试可执行文件

**解决方案 1A: 如果 RDC 有自己的测试**
```cmake
# profiler/CMakeLists.txt
therock_cmake_subproject_declare(rdc
  CMAKE_ARGS
    -DBUILD_TESTS=${THEROCK_BUILD_TESTING}
)

# 删除 add_test() 调用
```

```toml
# profiler/artifact-rdc.toml
[components.test."profiler/rdc/stage"]
include = [
  "bin/rdctst",              # RDC 的测试可执行文件
  "share/rdc/tests/**",      # 测试数据（如果有）
]
```

```python
# build_tools/github_actions/test_executable_scripts/test_rdc.py
cmd = [f"{THEROCK_BIN_DIR}/rdctst"]
subprocess.run(cmd, check=True)
```

**解决方案 1B: 如果只是验证库加载**

这种验证应该作为 **smoke test** 或集成测试的一部分，不应该是独立的 `add_test()`。

```python
# 在测试脚本中验证
import ctypes

def test_rdc_libraries():
    lib_path = f"{THEROCK_LIB_DIR}/rdc/librdc_rocr.so"
    lib = ctypes.CDLL(lib_path)
    assert lib is not None
```

**推荐**: **删除 `add_test()` 和 `validate_rdc_library.sh`**，让 RDC 使用自己的测试套件。

---

### 问题 2: -DBUILD_TESTS=ON 应该使用 ${THEROCK_BUILD_TESTING} ✅

**当前代码**:
```cmake
-DBUILD_TESTS=ON
```

**为什么要改**:
- ✅ `THEROCK_BUILD_TESTING` 是 TheRock 的全局测试开关
- ✅ 允许用户控制是否构建测试（测试会增加构建时间）
- ✅ CI 可以选择性地启用测试构建
- ✅ 与其他 TheRock 子项目保持一致

**正确代码**:
```cmake
-DBUILD_TESTS=${THEROCK_BUILD_TESTING}
```

**优先级**: 🔴 **高** - 应该立即修改

---

### 问题 3: artifact-rdc.toml 组件划分不正确 ❌

**当前代码**:
```toml
[components.lib."profiler/rdc/stage"]
include = [
  "lib/*.so*",
  "lib/rdc/*.so*",
]

[components.run."profiler/rdc/stage"]
include = [
  "lib/*.so*",        # ❌ 重复包含
  "lib/rdc/*.so*",    # ❌ 重复包含
  "libexec/rdc/**",
  "share/rdc/**",
]
```

**问题分析**:
1. ❌ `.so` 文件在 `lib` 和 `run` 中**重复包含**
2. ❌ 违反了"lib 组件包含共享库"的原则
3. ❌ `run` 组件应该只包含可执行文件和数据，**依赖** `lib` 获取共享库

**参考例子**: `artifact-rocprofiler-sdk.toml`
```toml
[components.lib."profiler/rocprofiler-sdk/stage"]
include = [
  "libexec/rocprofiler-sdk/**",
]

[components.run."profiler/rocprofiler-sdk/stage"]
include = [
  "bin/**",
  "share/rocprofiler-sdk/**",
  "lib/python*/**",
]
# 注意: run 组件没有重复包含 lib/*.so
```

**正确代码**:
```toml
[components.lib."profiler/rdc/stage"]
include = [
  "lib/*.so*",
  "lib/rdc/*.so*",
]

[components.run."profiler/rdc/stage"]
include = [
  "bin/rdcd",              # RDC daemon
  "bin/rdci",              # RDC CLI tool
  "libexec/rdc/**",        # 辅助可执行文件
  "share/rdc/**",          # 配置文件、文档等
]
# 删除 lib/*.so* - 这些在 lib 组件中
```

**注意**: 还需要检查 RDC 实际安装的文件：

```bash
$ ls -R build-3/profiler/rdc/stage/
bin/        # 可执行文件
lib/        # 共享库
libexec/    # 辅助程序
share/      # 数据文件
```

**优先级**: 🔴 **高** - 应该立即修改

---

### 问题 4: validate_rdc_library.sh 不是 TheRock 测试方式 ❌

**当前文件**: `profiler/validate_rdc_library.sh`

**问题**:
1. ❌ 这是一个 bash 脚本，不符合 TheRock 的 Python 测试框架
2. ❌ 通过 `add_test()` 调用，不会被打包到 artifacts
3. ❌ 无法在 CI 的测试阶段运行

**解决方案 A: 删除此文件**（推荐）

如果 RDC 有自己的测试套件（`rdctst`），应该使用那个：

```python
# build_tools/github_actions/test_executable_scripts/test_rdc.py
cmd = [f"{THEROCK_BIN_DIR}/rdctst"]
subprocess.run(cmd, check=True)
```

**解决方案 B: 将验证逻辑集成到 Python 测试脚本**

如果需要验证库加载：

```python
# test_rdc.py
import ctypes
import os

def test_rdc_libraries_load():
    """Test that RDC shared libraries can be loaded"""
    libs = ["librdc_rocr.so", "librdc_rocp.so"]
    for lib_name in libs:
        lib_path = os.path.join(THEROCK_LIB_DIR, "rdc", lib_name)
        try:
            lib = ctypes.CDLL(lib_path)
            print(f"✓ Successfully loaded {lib_name}")
        except Exception as e:
            print(f"✗ Failed to load {lib_name}: {e}")
            raise
```

**推荐**: **删除 `validate_rdc_library.sh` 和相关的 `add_test()` 调用**

**优先级**: 🟡 **中** - 可以暂时保留，但最终应该删除或改用正确方式

---

## 📊 改进方案总结

### 方案 A: 最小改动（推荐）

**优点**: 快速修复主要问题，保持简单  
**适用**: 如果时间紧迫或RDC测试还在开发中

**改动**:

1. ✅ **修改 profiler/CMakeLists.txt Line 151**:
   ```cmake
   -DBUILD_TESTS=${THEROCK_BUILD_TESTING}
   ```

2. ✅ **删除 profiler/CMakeLists.txt Line 178-186**:
   ```cmake
   # 删除整个 foreach(lib_name...) add_test(...) endforeach() 块
   ```

3. ✅ **修改 profiler/artifact-rdc.toml**:
   ```toml
   [components.lib."profiler/rdc/stage"]
   include = [
     "lib/*.so*",
     "lib/rdc/*.so*",
   ]
   
   [components.run."profiler/rdc/stage"]
   include = [
     "bin/**",              # CLI 工具
     "libexec/rdc/**",      # 辅助程序
     "share/rdc/**",        # 数据文件
   ]
   # 删除 lib/*.so* 重复项
   ```

4. ✅ **删除 profiler/validate_rdc_library.sh**

**不添加测试**（因为可能还不完善）

---

### 方案 B: 完整实现（理想）

**优点**: 完全符合 TheRock 规范，支持完整测试  
**适用**: 如果 RDC 测试已经准备好

**改动**: 方案 A 的所有改动，加上：

5. ✅ **在 profiler/artifact-rdc.toml 添加 test 组件**:
   ```toml
   [components.test."profiler/rdc/stage"]
   include = [
     "bin/rdctst",           # RDC 测试可执行文件
     "share/rdc/tests/**",   # 测试数据（如果有）
   ]
   ```

6. ✅ **创建 build_tools/github_actions/test_executable_scripts/test_rdc.py**:
   ```python
   #!/usr/bin/env python3
   """Test RDC (ROCm Data Center Tool)"""
   
   import logging
   import shlex
   import subprocess
   from pathlib import Path
   
   from github_actions_utils import *
   
   logging.basicConfig(level=logging.INFO)
   
   # Run RDC test suite
   cmd = [f"{THEROCK_BIN_DIR}/rdctst"]
   logging.info(f"++ Exec [{THEROCK_DIR}]$ {shlex.join(cmd)}")
   subprocess.run(cmd, cwd=THEROCK_DIR, check=True)
   ```

7. ✅ **在 build_tools/github_actions/fetch_test_configurations.py 注册**:
   ```python
   "rdc": {
       "job_name": "rdc",
       "fetch_artifact_args": "--profiler --tests",
       "timeout_minutes": 10,
       "test_script": f"python {_get_script_path('test_rdc.py')}",
       "platform": ["linux"],
   }
   ```

8. ✅ **更新 build_tools/install_rocm_from_artifacts.py**（如果需要）

---

## 🎯 推荐行动计划

### 立即执行（方案 A）

1. ✅ 修改 `CMAKE_ARGS`: `-DBUILD_TESTS=${THEROCK_BUILD_TESTING}`
2. ✅ 删除 `add_test()` 调用和 `foreach` 循环
3. ✅ 修改 `artifact-rdc.toml` 移除 `run` 组件中的重复 `.so` 文件
4. ✅ 删除 `validate_rdc_library.sh`

### 后续完善（方案 B）

5. ⏳ 验证 RDC 测试是否构建成功（`rdctst` 等）
6. ⏳ 添加 `components.test` 到 artifact
7. ⏳ 创建 `test_rdc.py` 测试脚本
8. ⏳ 在 `fetch_test_configurations.py` 中注册测试

---

## ✅ 验证检查清单

完成改动后，验证：

- [ ] RDC 构建成功（`cmake --build build-3 --target rdc`）
- [ ] artifact 包含正确的组件（`ls build-3/artifacts/rdc_*`）
- [ ] `lib` 组件包含 `.so` 文件
- [ ] `run` 组件**不**包含 `.so` 文件
- [ ] `run` 组件包含可执行文件（`bin/rdcd`, `bin/rdci`）
- [ ] 如果 `THEROCK_BUILD_TESTING=OFF`，RDC 测试不构建
- [ ] 如果 `THEROCK_BUILD_TESTING=ON`，RDC 测试构建成功

---

## 📝 总结

| 关切 | 合理性 | 优先级 | 行动 |
|------|--------|--------|------|
| 1. 测试添加方式 | ✅ 完全合理 | 🔴 高 | 删除 add_test() |
| 2. BUILD_TESTS 标志 | ✅ 完全合理 | 🔴 高 | 改为 ${THEROCK_BUILD_TESTING} |
| 3. artifact 组件划分 | ✅ 完全合理 | 🔴 高 | 移除 run 中的重复 .so |
| 4. validate 脚本 | ✅ 完全合理 | 🟡 中 | 删除脚本文件 |

**所有关切都完全合理！** 应该立即实施方案 A 的修改。

