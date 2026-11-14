cmake_minimum_required(VERSION 3.4.1)

# v261113: 共享 C 层（和 iOS 共享同一份源码）
add_library(aianywhere-native SHARED
    sse.c
    sse_jni.c
    openai_api.c
)

include_directories(${CMAKE_CURRENT_SOURCE_DIR})

find_library(log-lib log)

target_link_libraries(aianywhere-native
    ${log-lib}
)
