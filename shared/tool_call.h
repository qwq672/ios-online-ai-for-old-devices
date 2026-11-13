/**
 * tool_call.h — Shared tool call protocol (C)
 * v261113: 跨平台共享 C 层 — 工具调用逻辑
 *
 * 负责构造工具定义 JSON + 解析工具调用 + 构造工具结果。
 * 和 iOS NetworkService / Android NetworkService 共享同一份逻辑。
 */

#ifndef TOOL_CALL_H
#define TOOL_CALL_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ===== 工具定义构造 ===== */

/**
 * 构造 tools JSON 数组（OpenAI function calling 格式）
 *
 * @param flags  位掩码：1=tavily_search, 2=web_search, 4=fetch_url,
 *               8=get_current_time, 16=get_device_info, 32=generate_image,
 *               64=get_image
 * @param out    输出缓冲区
 * @param size   缓冲区大小
 * @return JSON 长度，0 = 失败
 */
size_t tool_build_definitions(int flags, char* out, size_t size);

/* ===== 工具状态标记 ===== */

/**
 * 构造工具调用"正在执行"标记
 * @param fn_name  函数名（如 "tavily_search"）
 * @param args     参数 JSON 字符串
 * @param out      输出缓冲区
 * @param size     缓冲区大小
 * @return 标记文本长度
 */
size_t tool_build_start_marker(const char* fn_name, const char* args,
                               char* out, size_t size);

/**
 * 构造工具调用"完成"标记
 * @param fn_name  函数名
 * @param args     参数 JSON 字符串
 * @param out      输出缓冲区
 * @param size     缓冲区大小
 * @return 标记文本长度
 */
size_t tool_build_done_marker(const char* fn_name, const char* args,
                              char* out, size_t size);

/* ===== 工具定义常量 ===== */

#define TOOL_TAVILY_SEARCH   0x01
#define TOOL_WEB_SEARCH      0x02
#define TOOL_FETCH_URL       0x04
#define TOOL_GET_TIME        0x08
#define TOOL_GET_DEVICE      0x10
#define TOOL_GENERATE_IMAGE  0x20
#define TOOL_GET_IMAGE       0x40

#ifdef __cplusplus
}
#endif

#endif /* TOOL_CALL_H */
