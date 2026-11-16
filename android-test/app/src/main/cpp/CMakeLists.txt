cmake_minimum_required(VERSION 3.4.1)

# v261113: 共享 C 层（和 iOS 共享同一份源码）
# v261116-7: 加入 markdown_ast.c + tool_call.c（之前漏了）
add_library(aianywhere-native SHARED
    sse.c
    sse_jni.c
    openai_api.c
    markdown_ast.c
    tool_call.c
)

include_directories(${CMAKE_CURRENT_SOURCE_DIR})

# v261116-7: mbedTLS 集成（Android 2.3 不支持 TLS 1.2）
# 通过 CMake -DMBEDTLS_SRC_DIR=... 传入（build.gradle 的 externalNativeBuild.cmake.arguments）
# CI workflow 会在 build 前下载 mbedTLS v2.28.9 源码
if(NOT DEFINED MBEDTLS_SRC_DIR)
    set(MBEDTLS_SRC_DIR "")
endif()
if(EXISTS "${MBEDTLS_SRC_DIR}/CMakeLists.txt")
    message(STATUS "mbedTLS source found at ${MBEDTLS_SRC_DIR}, building with TLS support")

    # v261116-8: 关闭 mbedTLS tests + programs — 只编 library
    # 否则 tests/src/psa_exercise_key.c 的 -Werror 会因字符串初始化警告失败
    set(ENABLE_TESTING OFF CACHE BOOL "" FORCE)
    set(ENABLE_PROGRAMS OFF CACHE BOOL "" FORCE)

    # 编译 mbedTLS 静态库
    add_subdirectory(${MBEDTLS_SRC_DIR} ${CMAKE_BINARY_DIR}/mbedtls_build EXCLUDE_FROM_ALL)

    # mbedtls_jni.c — JNI wrapper（只在 mbedTLS 可用时编译）
    target_sources(aianywhere-native PRIVATE mbedtls_jni.c)
    target_include_directories(aianywhere-native PRIVATE ${MBEDTLS_SRC_DIR}/include)
    target_link_libraries(aianywhere-native mbedtls mbedx509 mbedcrypto)
    target_compile_definitions(aianywhere-native PRIVATE HAS_MBEDTLS=1)
else()
    message(STATUS "mbedTLS source NOT found (MBEDTLS_SRC_DIR='${MBEDTLS_SRC_DIR}'), building without TLS support")
    message(STATUS "  Android 2.3 will fall back to system TLS (likely fails for TLS 1.2 servers)")
endif()

find_library(log-lib log)

target_link_libraries(aianywhere-native
    ${log-lib}
)
