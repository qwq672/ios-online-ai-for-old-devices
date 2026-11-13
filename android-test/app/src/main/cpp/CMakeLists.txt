cmake_minimum_required(VERSION 3.4.1)

# v261113: 共享 C 层 — SSE 解析器（和 iOS 共享同一份 sse.c）
add_library(aianywhere-native SHARED
    sse.c
)

# 包含 shared 目录的头文件
include_directories(${CMAKE_CURRENT_SOURCE_DIR})

# 链接 Android log 库（JNI 需要）
find_library(log-lib log)

target_link_libraries(aianywhere-native
    ${log-lib}
)
