# RDC 库验证解决方案

**日期**: 2025-11-09  
**需求**: 验证 RDC 生成的共享库和静态库

---

## 🔍 TheRock 标准验证机制

### 现有的共享库验证

**函数**: `therock_test_validate_shared_lib()` (定义在 `cmake/therock_testing.cmake`)

**功能**:
- 使用 `Python3` + `build_tools/validate_shared_library.py`
- 通过 `ctypes.cdll.LoadLibrary()` 验证库能否加载
- 使用 `add_test()` 集成到 CMake 测试系统

**使用示例** (来自 `core/CMakeLists.txt`):
```cmake
therock_test_validate_shared_lib(
  PATH ROCR-Runtime/dist/lib
  LIB_NAMES libhsa-runtime64.so
)
```

### 为什么这种方式是正确的？

1. ✅ **标准化**: TheRock 所有项目都这样做
2. ✅ **使用 add_test()**: 是的，但这是 CMake 的标准测试机制
3. ✅ **构建时运行**: 通过 `ctest` 或 `cmake --build . --target test` 运行
4. ✅ **不影响 CI**: 这些是本地构建验证，不是打包到 artifacts 的测试

**与 CI 测试的区别**:

| 特性 | 构建验证 (Validation) | CI 测试 (Test) |
|------|----------------------|----------------|
| 时机 | 构建后立即运行 | 独立测试阶段 |
| 方式 | `add_test()` + `ctest` | Python 脚本 + artifacts |
| 目的 | 验证库基本可用 | 验证功能正确性 |
| 打包 | 不打包 | 打包到 `components.test` |

---

## ✅ 方案 1: RDC 共享库验证（推荐）

### 使用标准的 `therock_test_validate_shared_lib()`

**实现**:

```cmake
# profiler/CMakeLists.txt
if(THEROCK_ENABLE_RDC)
  therock_cmake_subproject_declare(rdc
    # ... 现有配置 ...
  )
  
  therock_cmake_subproject_activate(rdc)

  # 验证 RDC 共享库
  therock_test_validate_shared_lib(
    PATH rdc/dist/lib/rdc
    LIB_NAMES
      librdc.so
      librdc_rocr.so
      librdc_rocp.so
      librdc_bootstrap.so
  )

  # Provide RDC artifact
  therock_provide_artifact(rdc ...)
endif()
```

**优点**:
- ✅ 使用 TheRock 标准方式
- ✅ 与其他项目一致
- ✅ 无需创建新脚本
- ✅ 自动集成到 CTest

**运行方式**:
```bash
# 构建后自动运行（如果启用了测试）
cmake --build build-3 --target rdc
ctest -R therock-validate-shared-lib-librdc

# 或者运行所有测试
cmake --build build-3 --target test
```

---

## 🆕 方案 2: 静态库验证（可选）

### 创建新的验证函数和脚本

#### A. 创建静态库验证脚本

**文件**: `build_tools/validate_static_library.py`

```python
#!/usr/bin/env python3
"""Validates that a static library is well-formed."""

import argparse
import os
import subprocess
import sys


def run(args: argparse.Namespace):
    """Validate static libraries."""
    for static_lib in args.static_libs:
        print(f"Validating static library: {static_lib}")
        
        # Check if file exists
        if not os.path.exists(static_lib):
            print(f"  ✗ File does not exist: {static_lib}")
            sys.exit(1)
        print(f"  ✓ File exists")
        
        # Check if file is not empty
        size = os.path.getsize(static_lib)
        if size == 0:
            print(f"  ✗ File is empty: {static_lib}")
            sys.exit(1)
        print(f"  ✓ File size: {size} bytes")
        
        # Check if it's a valid archive using 'ar'
        try:
            result = subprocess.run(
                ["ar", "t", static_lib],
                capture_output=True,
                text=True,
                check=True
            )
            obj_count = len(result.stdout.strip().split('\n'))
            print(f"  ✓ Valid archive with {obj_count} object files")
        except subprocess.CalledProcessError as e:
            print(f"  ✗ Not a valid archive: {e}")
            sys.exit(1)
        
        # Check symbols using 'nm'
        try:
            result = subprocess.run(
                ["nm", "--defined-only", static_lib],
                capture_output=True,
                text=True,
                check=True
            )
            symbol_count = len([line for line in result.stdout.split('\n') 
                               if line.strip() and not line.startswith(' ')])
            print(f"  ✓ Contains {symbol_count} defined symbols")
        except subprocess.CalledProcessError as e:
            print(f"  ⚠ Warning: Could not read symbols: {e}")
        
        print(f"  ✓ Validation passed: {static_lib}\n")


def main(argv):
    p = argparse.ArgumentParser(
        description="Validate static library files (.a)"
    )
    p.add_argument("static_libs", nargs="+", 
                   help="Static libraries to validate")
    args = p.parse_args(argv)
    run(args)


if __name__ == "__main__":
    main(sys.argv[1:])
```

#### B. 创建 CMake 辅助函数

**添加到** `cmake/therock_testing.cmake`:

```cmake
# Adds a test for static libraries under a common path.
# PATH: Common path (relative to CMAKE_CURRENT_BINARY_DIR if not absolute)
# LIB_NAMES: Library names to validate
function(therock_test_validate_static_lib)
  cmake_parse_arguments(
    PARSE_ARGV 0 ARG
    ""
    "PATH"
    "LIB_NAMES"
  )
  
  if(NOT IS_ABSOLUTE ARG_PATH)
    cmake_path(ABSOLUTE_PATH ARG_PATH BASE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}")
  endif()

  foreach(lib_name ${ARG_LIB_NAMES})
    add_test(
      NAME therock-validate-static-lib-${lib_name}
      COMMAND
        "${Python3_EXECUTABLE}" "${THEROCK_SOURCE_DIR}/build_tools/validate_static_library.py"
          "${ARG_PATH}/${lib_name}"
    )
  endforeach()
endfunction()
```

#### C. 在 RDC 中使用

```cmake
# profiler/CMakeLists.txt
if(THEROCK_ENABLE_RDC)
  # ... 现有配置 ...
  
  therock_cmake_subproject_activate(rdc)

  # 验证共享库
  therock_test_validate_shared_lib(
    PATH rdc/dist/lib/rdc
    LIB_NAMES
      librdc.so
      librdc_rocr.so
      librdc_rocp.so
  )
  
  # 验证静态库（如果 RDC 构建了静态库）
  therock_test_validate_static_lib(
    PATH rdc/dist/lib/rdc
    LIB_NAMES
      librdc.a
      librdc_bootstrap.a
  )

  # Provide RDC artifact
  therock_provide_artifact(rdc ...)
endif()
```

---

## 🎯 推荐的实施方案

### 阶段 1: 立即实施（共享库验证）

**只需添加**:

```cmake
# profiler/CMakeLists.txt Line 177 之后
therock_cmake_subproject_activate(rdc)

# Validate RDC shared libraries
therock_test_validate_shared_lib(
  PATH rdc/dist/lib/rdc
  LIB_NAMES
    librdc.so
    librdc_rocr.so
    librdc_rocp.so
    librdc_bootstrap.so
)

# Provide RDC artifact
```

**优点**:
- ✅ 简单：只需 7 行代码
- ✅ 标准：使用 TheRock 现有机制
- ✅ 立即可用：无需创建新文件

**验证**:
```bash
# 重新配置
rm -rf build-3/profiler/rdc build-3/profiler/build
cmake --build build-3 --target rdc

# 运行验证
ctest --test-dir build-3 -R therock-validate-shared-lib-librdc -V
```

---

### 阶段 2: 可选（静态库验证）

**如果需要验证静态库**，实施方案 2:

1. 创建 `build_tools/validate_static_library.py`
2. 在 `cmake/therock_testing.cmake` 添加 `therock_test_validate_static_lib()`
3. 在 `profiler/CMakeLists.txt` 中调用

**时机**: 
- ⏳ 当 RDC 有静态库需要验证时
- ⏳ 或者作为 TheRock 的通用改进

---

## 📊 对比原来的方案

### 原来的做法（已删除）

```cmake
# ❌ 不标准
foreach(lib_name librdc_rocr.so librdc_rocp.so)
  add_test(
    NAME therock-validate-shared-lib-${lib_name}
    COMMAND
      "${CMAKE_CURRENT_SOURCE_DIR}/validate_rdc_library.sh"
        "${CMAKE_CURRENT_BINARY_DIR}/rdc/dist/lib/rdc/${lib_name}"
  )
endforeach()
```

**问题**:
- ❌ 自定义 bash 脚本（不可移植）
- ❌ 手动调用 `add_test()`（不符合规范）
- ❌ 需要维护额外的脚本文件

### 新的做法（推荐）

```cmake
# ✅ 标准
therock_test_validate_shared_lib(
  PATH rdc/dist/lib/rdc
  LIB_NAMES librdc_rocr.so librdc_rocp.so
)
```

**优点**:
- ✅ 使用标准函数
- ✅ Python 脚本（跨平台）
- ✅ 与其他项目一致
- ✅ 无需额外维护

---

## ❓ FAQ

### Q1: 这和 code reviewer 说的冲突吗？

**不冲突！** Code reviewer 说的是：
- ❌ 不要用自定义的验证脚本
- ❌ 不要把验证当成 CI 测试

我们的方案：
- ✅ 使用 TheRock 标准函数
- ✅ 这是构建验证，不是 CI 测试

### Q2: 什么时候运行这些验证？

**构建时**（如果 `THEROCK_BUILD_TESTING=ON`）:
```bash
cmake -DTHEROCK_BUILD_TESTING=ON ...
cmake --build build-3 --target rdc
ctest --test-dir build-3
```

**不会影响**:
- CI 的测试阶段（那是独立的 Python 脚本）
- Artifacts 打包（验证不打包）

### Q3: 如果 RDC 测试还在开发中怎么办？

**完全没问题！**
- 验证（validation）≠ 测试（test）
- 验证只是检查库能否加载，很简单
- RDC 测试可以以后再加

### Q4: 需要验证哪些库？

**查看 RDC 安装的库**:
```bash
$ ls build-3/profiler/rdc/dist/lib/rdc/
librdc.so
librdc_bootstrap.so
librdc_rocr.so
librdc_rocp.so
```

**全部验证**:
```cmake
therock_test_validate_shared_lib(
  PATH rdc/dist/lib/rdc
  LIB_NAMES
    librdc.so
    librdc_bootstrap.so
    librdc_rocr.so
    librdc_rocp.so
)
```

### Q5: 静态库验证是必需的吗？

**不是必需的**:
- 如果 RDC 不生成或不关心静态库，跳过
- 如果需要，可以后续添加
- 大多数项目只验证共享库

---

## ✅ 最终推荐

### 立即添加（3 分钟）

```cmake
# profiler/CMakeLists.txt
# 在 therock_cmake_subproject_activate(rdc) 之后添加：

therock_test_validate_shared_lib(
  PATH rdc/dist/lib/rdc
  LIB_NAMES
    librdc.so
    librdc_rocr.so
    librdc_rocp.so
    librdc_bootstrap.so
)
```

**就这么简单！**

