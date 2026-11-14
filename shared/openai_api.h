/**
 * openai_api.h — Shared OpenAI API protocol (C)
 * v261113: 跨平台共享 C 层 — OpenAI chat completion API 协议
 *
 * 负责构造请求 body + 解析响应 chunk（JSON delta）。
 * 不依赖任何平台 JSON 库——用极简手写 JSON（足够 OpenAI API 格式）。
 *
 * 两层架构：
 *   共享 C 层（本文件）：API 协议，无平台依赖
 *   各平台 UI 层：调用本模块构造/解析，自己渲染
 */

#ifndef OPENAI_API_H
#define OPENAI_API_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ===== 请求构造 ===== */

/**
 * 构造 chat completion 请求 body（JSON 字符串）
 *
 * @param model         模型名（如 "gpt-3.5-turbo"）
 * @param messages_json 已构造好的 messages JSON 数组字符串
 *                      （[{"role":"user","content":"hello"},...]）
 * @param temperature   温度（0.0-2.0，传 -1 用默认）
 * @param max_tokens    最大 token（<=0 不传）
 * @param stream        是否流式
 * @param tools_json    工具定义 JSON（NULL = 不传工具）
 * @param out_buf       输出缓冲区
 * @param buf_size      缓冲区大小
 * @return JSON 字符串长度，0 = 失败
 */
size_t openai_build_request(const char* model,
                            const char* messages_json,
                            float temperature,
                            int max_tokens,
                            int stream,
                            const char* tools_json,
                            char* out_buf,
                            size_t buf_size);

/* ===== 响应解析（SSE chunk） ===== */

/**
 * 从 SSE data 行解析出 content / reasoning_content / finish_reason
 *
 * @param sse_data       SSE data 行内容（不含 "data: " 前缀）
 * @param content_out    输出 content delta（缓冲区，NULL = 不需要）
 * @param content_size   content 缓冲区大小
 * @param reasoning_out  输出 reasoning_content delta（NULL = 不需要）
 * @param reasoning_size reasoning 缓冲区大小
 * @param finish_out     输出 finish_reason（NULL = 不需要）
 * @param finish_size    finish_reason 缓冲区大小
 * @return 0 = 正常解析, 1 = [DONE], -1 = 解析失败
 */
int openai_parse_chunk(const char* sse_data,
                       char* content_out, size_t content_size,
                       char* reasoning_out, size_t reasoning_size,
                       char* finish_out, size_t finish_size);

/* ===== 极简 JSON 工具（给 messages 构造用） ===== */

/**
 * JSON 字符串转义（处理 " \ \n \r \t）
 * @param src    原始字符串
 * @param out    输出缓冲区
 * @param size   缓冲区大小
 * @return 输出长度
 */
size_t json_escape(const char* src, char* out, size_t size);

/**
 * 构造一条 message JSON 对象
 * @param role    "user" / "assistant" / "system"
 * @param content 消息内容
 * @param out     输出缓冲区
 * @param size    缓冲区大小
 * @return 输出长度
 */
size_t json_build_message(const char* role, const char* content,
                          char* out, size_t size);

#ifdef __cplusplus
}
#endif

#endif /* OPENAI_API_H */
