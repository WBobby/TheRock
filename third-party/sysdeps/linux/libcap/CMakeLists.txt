if(NOT CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
  # When included in TheRock, we download sources and set up the sub-project.
  set(_source_dir "${CMAKE_CURRENT_BINARY_DIR}/source")
  set(_download_stamp "${_source_dir}/download.stamp")

  therock_subproject_fetch(therock-libcap-sources
    SOURCE_DIR "${_source_dir}"
    URL "https://git.kernel.org/pub/scm/libs/libcap/libcap.git/snapshot/libcap-2.69.tar.gz"
    URL_HASH "SHA256=9cc2fa3ee744d881629cdac1a1b54c302e7684fda3e3622056218c7681642ffb"
    TOUCH "${_download_stamp}"
  )

  therock_cmake_subproject_declare(therock-libcap
    EXTERNAL_SOURCE_DIR .
    BINARY_DIR build
    NO_MERGE_COMPILE_COMMANDS
    BACKGROUND_BUILD
    OUTPUT_ON_FAILURE
    CMAKE_ARGS
      "-DSOURCE_DIR=${_source_dir}"
      "-DPATCHELF=${PATCHELF}"
      "-DTHEROCK_SOURCE_DIR=${THEROCK_SOURCE_DIR}"
      "-DPython3_EXECUTABLE=${Python3_EXECUTABLE}"
    INSTALL_DESTINATION
      lib/rocm_sysdeps
    INTERFACE_INCLUDE_DIRS
      lib/rocm_sysdeps/include
    INTERFACE_LINK_DIRS
      lib/rocm_sysdeps/lib
    INTERFACE_INSTALL_RPATH_DIRS
      lib/rocm_sysdeps/lib
    INTERFACE_PKG_CONFIG_DIRS
      lib/rocm_sysdeps/lib/pkgconfig
    EXTRA_DEPENDS
      "${_download_stamp}"
  )
  therock_cmake_subproject_provide_package(therock-libcap Libcap lib/rocm_sysdeps/lib/cmake/Libcap)
  therock_cmake_subproject_activate(therock-libcap)

  therock_test_validate_shared_lib(
    PATH build/dist/lib/rocm_sysdeps/lib
    LIB_NAMES libcap.so
  )
  return()
endif()

# Otherwise, this is the sub-project build.
cmake_minimum_required(VERSION 3.25)
project(LIBCAP_BUILD)

include(ProcessorCount)
ProcessorCount(PAR_JOBS)
if(NOT PAR_JOBS OR PAR_JOBS EQUAL 0)
  set(PAR_JOBS 1)
endif()

if(CMAKE_MAKE_PROGRAM)
  set(_libcap_make "${CMAKE_MAKE_PROGRAM}")
else()
  find_program(_libcap_make make REQUIRED)
endif()

if(NOT PATCHELF)
  message(FATAL_ERROR "Missing PATCHELF from super-project")
endif()

# Safety check: Prevent accidental deletion of directories outside the build tree.
cmake_path(CONVERT "${CMAKE_INSTALL_PREFIX}" TO_ABSOLUTE_PATH _libcap_install_abs)
cmake_path(CONVERT "${CMAKE_CURRENT_BINARY_DIR}" TO_ABSOLUTE_PATH _libcap_build_abs)
cmake_path(IS_PREFIX "${_libcap_build_abs}" "${_libcap_install_abs}" NORMALIZE _libcap_prefix_guard)
if(NOT _libcap_prefix_guard)
  message(FATAL_ERROR
    "libcap: CMAKE_INSTALL_PREFIX (${CMAKE_INSTALL_PREFIX}) must reside under ${CMAKE_CURRENT_BINARY_DIR} to safely run rm -rf.")
endif()

set(_libcap_make_args
  prefix=<INSTALL_DIR>
  lib=lib
  GOLANG=no
  PAM_CAP=no
  RAISE_SETFCAP=no
)

ExternalProject_Add(libcap-build
  DOWNLOAD_COMMAND ""
  SOURCE_DIR "${SOURCE_DIR}/libcap"
  CONFIGURE_COMMAND ""
  BUILD_COMMAND
    "${_libcap_make}" -C "<SOURCE_DIR>" -j "${PAR_JOBS}" ${_libcap_make_args}
  INSTALL_COMMAND
    "${_libcap_make}" -C "<SOURCE_DIR>" install ${_libcap_make_args}
    COMMAND
      "${CMAKE_COMMAND}" -E env
        "PATCHELF=${PATCHELF}"
        "THEROCK_SOURCE_DIR=${THEROCK_SOURCE_DIR}"
        "Python3_EXECUTABLE=${Python3_EXECUTABLE}" --
      bash "${CMAKE_CURRENT_SOURCE_DIR}/patch_install.sh" "<INSTALL_DIR>"
  INSTALL_DIR "${CMAKE_INSTALL_PREFIX}"
  BUILD_ALWAYS ON
  LOG_BUILD ON
  LOG_INSTALL ON
)

add_custom_target(libcap ALL DEPENDS libcap-build)
