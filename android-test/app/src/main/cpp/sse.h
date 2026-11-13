/**
 * sse.h — Shared SSE (Server-Sent Events) parser
 * v261113: 跨平台共享 C 层 — SSE 流式解析
 *
 * 两层架构：
 *   共享 C 层（本文件）：SSE 解析，无平台依赖
 *   各平台 UI 层：iOS UIKit / Android View / UWP XAML（不共享）
 *
 * 用法：
 *   sse_parser* p = sse_parser_create(callback, user_data);
 *   sse_parser_feed(p, raw_bytes, len);  // 收到网络数据时调
 *   sse_parser_destroy(p);               // 结束时调
 *
 * callback 在 feed 内同步调用，每完成一个 data 事件调一次。
 * 线程安全：parser 实例不共享，每个网络请求一个实例。
 */

#ifndef SSE_H
#define SSE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct sse_parser sse_parser;

/**
 * 回调：每完成一个 SSE data 事件时调用。
 * @param data  事件数据（不含 "data: " 前缀，不含末尾换行）
 * @param len   数据长度
 * @param done  1 = "data: [DONE]" 收到（流结束），0 = 普通数据
 * @param user  创建 parser 时传入的 user_data
 */
typedef void (*sse_data_callback)(const char* data, size_t len, int done, void* user);

/** 创建 parser 实例 */
sse_parser* sse_parser_create(sse_data_callback cb, void* user_data);

/** 销毁 parser 实例 */
void sse_parser_destroy(sse_parser* p);

/** 喂数据（收到网络数据时调，可多次调用） */
void sse_parser_feed(sse_parser* p, const char* data, size_t len);

/** 重置（复用实例时调） */
void sse_parser_reset(sse_parser* p);

#ifdef __cplusplus
}
#endif

#endif /* SSE_H */
