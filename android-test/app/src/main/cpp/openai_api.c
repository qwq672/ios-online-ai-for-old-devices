/**
 * openai_api.c — Shared OpenAI API protocol (C)
 * v261113: 跨平台共享 C 层
 *
 * 极简手写 JSON（不依赖 cJSON 等库，减小体积 + 提高可移植性）
 * 只处理 OpenAI chat completion API 需要的格式。
 */

#include "openai_api.h"
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

/* ===== JSON 转义 ===== */
size_t json_escape(const char* src, char* out, size_t size) {
    if (!src || !out || size == 0) return 0;
    size_t j = 0;
    for (size_t i = 0; src[i] && j < size - 1; i++) {
        char c = src[i];
        if (c == '"') {
            if (j + 2 >= size) break;
            out[j++] = '\\'; out[j++] = '"';
        } else if (c == '\\') {
            if (j + 2 >= size) break;
            out[j++] = '\\'; out[j++] = '\\';
        } else if (c == '\n') {
            if (j + 2 >= size) break;
            out[j++] = '\\'; out[j++] = 'n';
        } else if (c == '\r') {
            if (j + 2 >= size) break;
            out[j++] = '\\'; out[j++] = 'r';
        } else if (c == '\t') {
            if (j + 2 >= size) break;
            out[j++] = '\\'; out[j++] = 't';
        } else if ((unsigned char)c < 0x20) {
            /* 控制字符跳过（防止 JSON 破坏） */
        } else {
            out[j++] = c;
        }
    }
    out[j] = '\0';
    return j;
}

/* ===== 构造 message JSON ===== */
size_t json_build_message(const char* role, const char* content,
                          char* out, size_t size) {
    if (!role || !content || !out || size == 0) return 0;

    /* 转义 content */
    size_t escaped_size = strlen(content) * 2 + 1;
    char* escaped = (char*)malloc(escaped_size);
    if (!escaped) return 0;
    json_escape(content, escaped, escaped_size);

    int n = snprintf(out, size,
        "{\"role\":\"%s\",\"content\":\"%s\"}", role, escaped);
    free(escaped);
    return (n > 0 && (size_t)n < size) ? (size_t)n : 0;
}

/* ===== 构造请求 body ===== */
size_t openai_build_request(const char* model,
                            const char* messages_json,
                            float temperature,
                            int max_tokens,
                            int stream,
                            const char* tools_json,
                            char* out_buf,
                            size_t buf_size) {
    if (!model || !messages_json || !out_buf || buf_size == 0) return 0;

    int n = 0;
    const char* tools_part = tools_json ? tools_json : "";

    if (temperature >= 0 && max_tokens > 0 && tools_json) {
        n = snprintf(out_buf, buf_size,
            "{\"model\":\"%s\",\"messages\":%s,\"stream\":%s,"
            "\"temperature\":%.2f,\"max_tokens\":%d,\"tools\":%s,\"tool_choice\":\"auto\"}",
            model, messages_json, stream ? "true" : "false",
            temperature, max_tokens, tools_part);
    } else if (temperature >= 0 && max_tokens > 0) {
        n = snprintf(out_buf, buf_size,
            "{\"model\":\"%s\",\"messages\":%s,\"stream\":%s,"
            "\"temperature\":%.2f,\"max_tokens\":%d}",
            model, messages_json, stream ? "true" : "false",
            temperature, max_tokens);
    } else if (temperature >= 0) {
        n = snprintf(out_buf, buf_size,
            "{\"model\":\"%s\",\"messages\":%s,\"stream\":%s,"
            "\"temperature\":%.2f}",
            model, messages_json, stream ? "true" : "false", temperature);
    } else {
        n = snprintf(out_buf, buf_size,
            "{\"model\":\"%s\",\"messages\":%s,\"stream\":%s}",
            model, messages_json, stream ? "true" : "false");
    }

    return (n > 0 && (size_t)n < buf_size) ? (size_t)n : 0;
}

/* ===== 极简 JSON 字段提取 ===== */
/* 在 json 字符串里找 "key":"value" 或 "key":value
 * 不处理嵌套，只找顶层（够 OpenAI delta 格式用）
 */
static const char* find_field(const char* json, const char* key) {
    if (!json || !key) return NULL;
    char pattern[64];
    snprintf(pattern, sizeof(pattern), "\"%s\"", key);
    const char* p = strstr(json, pattern);
    if (!p) return NULL;
    p += strlen(pattern);
    /* 跳过 : 和空白 */
    while (*p && (*p == ':' || *p == ' ' || *p == '\t')) p++;
    return p;
}

/* 提取字符串值（"xxx" 格式） */
static size_t extract_string(const char* json, const char* key,
                             char* out, size_t out_size) {
    const char* p = find_field(json, key);
    if (!p || *p != '"') return 0;
    p++; /* 跳过开头的 " */
    size_t j = 0;
    while (*p && j < out_size - 1) {
        if (*p == '\\' && *(p+1)) {
            p++;
            if (*p == 'n') out[j++] = '\n';
            else if (*p == 'r') out[j++] = '\r';
            else if (*p == 't') out[j++] = '\t';
            else if (*p == '"') out[j++] = '"';
            else if (*p == '\\') out[j++] = '\\';
            else out[j++] = *p;
            p++;
        } else if (*p == '"') {
            break;
        } else {
            out[j++] = *p++;
        }
    }
    out[j] = '\0';
    return j;
}

/* 提取字符串值（可能是 null） */
static int extract_string_or_null(const char* json, const char* key,
                                  char* out, size_t out_size) {
    const char* p = find_field(json, key);
    if (!p) return 0;
    if (strncmp(p, "null", 4) == 0) return -1; /* null */
    if (*p == '"') return (int)extract_string(json, key, out, out_size);
    return 0;
}

/* ===== 解析 SSE chunk ===== */
int openai_parse_chunk(const char* sse_data,
                       char* content_out, size_t content_size,
                       char* reasoning_out, size_t reasoning_size,
                       char* finish_out, size_t finish_size) {
    if (!sse_data) return -1;

    /* 检查 [DONE] */
    if (strcmp(sse_data, "[DONE]") == 0) return 1;

    /* OpenAI SSE chunk 格式：
     * {"choices":[{"delta":{"content":"xxx","reasoning_content":"yyy"},
     *   "finish_reason":"stop"}]}
     */
    int has_content = 0;
    int has_reasoning = 0;
    int has_finish = 0;

    /* content（可能是 null） */
    if (content_out && content_size > 0) {
        content_out[0] = '\0';
        int r = extract_string_or_null(sse_data, "content", content_out, content_size);
        if (r > 0) has_content = 1;
    }

    /* reasoning_content（可能是 null，某些 API 用 "reasoning" 或 "thinking"） */
    if (reasoning_out && reasoning_size > 0) {
        reasoning_out[0] = '\0';
        int r = extract_string_or_null(sse_data, "reasoning_content", reasoning_out, reasoning_size);
        if (r <= 0) {
            r = extract_string_or_null(sse_data, "reasoning", reasoning_out, reasoning_size);
        }
        if (r <= 0) {
            r = extract_string_or_null(sse_data, "thinking", reasoning_out, reasoning_size);
        }
        if (r > 0) has_reasoning = 1;
    }

    /* finish_reason */
    if (finish_out && finish_size > 0) {
        finish_out[0] = '\0';
        int r = extract_string_or_null(sse_data, "finish_reason", finish_out, finish_size);
        if (r > 0) has_finish = 1;
    }

    return 0;
}
