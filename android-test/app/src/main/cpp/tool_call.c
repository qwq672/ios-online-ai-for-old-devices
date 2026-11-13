/**
 * tool_call.c — Shared tool call protocol (C)
 * v261113: 跨平台共享 C 层 — 工具调用逻辑
 *
 * 构造 OpenAI function calling 格式的工具定义 + 状态标记。
 * 纯 C，无平台依赖，双端共享。
 */

#include "tool_call.h"
#include <string.h>
#include <stdio.h>

/* ===== 工具定义构造 ===== */

size_t tool_build_definitions(int flags, char* out, size_t size) {
    if (!out || size == 0) return 0;
    size_t pos = 0;
    int first = 1;

    pos += snprintf(out + pos, size - pos, "[");
    if (pos >= size) return 0;

    #define ADD_TOOL(name, desc_json) \
        if (!first) { pos += snprintf(out + pos, size - pos, ","); } \
        first = 0; \
        pos += snprintf(out + pos, size - pos, \
            "{\"type\":\"function\",\"function\":{\"name\":\"%s\",\"description\":%s}}", \
            name, desc_json); \
        if (pos >= size) return 0;

    if (flags & TOOL_TAVILY_SEARCH) {
        ADD_TOOL("tavily_search",
            "\"Search the web for current information using Tavily API. Use when the user asks about recent events or things you don't know.\"");
    }
    if (flags & TOOL_WEB_SEARCH) {
        ADD_TOOL("web_search",
            "\"Search the web using the provider's built-in search. Returns titles, URLs, and content snippets.\"");
    }
    if (flags & TOOL_FETCH_URL) {
        ADD_TOOL("fetch_url",
            "\"Fetch the content of a URL. Use when the user asks to read a webpage.\"");
    }
    if (flags & TOOL_GET_TIME) {
        ADD_TOOL("get_current_time",
            "\"Get the current date and time.\"");
    }
    if (flags & TOOL_GET_DEVICE) {
        ADD_TOOL("get_device_info",
            "\"Get basic device information (model, OS version, language).\"");
    }
    if (flags & TOOL_GENERATE_IMAGE) {
        ADD_TOOL("generate_image",
            "\"Generate an image from a text prompt.\"");
    }
    if (flags & TOOL_GET_IMAGE) {
        ADD_TOOL("get_image",
            "\"Fetch and analyze an image from a URL. Use when the user asks to see or analyze an image.\"");
    }

    #undef ADD_TOOL

    pos += snprintf(out + pos, size - pos, "]");
    if (pos >= size) return 0;
    return pos;
}

/* ===== 工具状态标记 ===== */

/* 从参数 JSON 提取 query/url 等显示文本 */
static void extract_display_text(const char* fn_name, const char* args,
                                 char* out, size_t size) {
    if (!fn_name || !args || !out || size == 0) { if (out && size) out[0] = '\0'; return; }

    /* 简单提取 "query":"xxx" 或 "url":"xxx" */
    const char* keys[] = {"query", "search_query", "url", "prompt", NULL};
    for (int i = 0; keys[i]; i++) {
        char pattern[32];
        snprintf(pattern, sizeof(pattern), "\"%s\"", keys[i]);
        const char* p = strstr(args, pattern);
        if (p) {
            p += strlen(pattern);
            while (*p && (*p == ':' || *p == ' ')) p++;
            if (*p == '"') {
                p++;
                size_t j = 0;
                while (*p && *p != '"' && j < size - 1) {
                    out[j++] = *p++;
                }
                out[j] = '\0';
                return;
            }
        }
    }
    /* 没找到 → 空字符串 */
    out[0] = '\0';
}

size_t tool_build_start_marker(const char* fn_name, const char* args,
                               char* out, size_t size) {
    if (!fn_name || !out || size == 0) return 0;

    char display[256];
    extract_display_text(fn_name, args, display, sizeof(display));

    const char* action = "正在调用工具";
    if (strstr(fn_name, "search")) action = "正在搜索";
    else if (strstr(fn_name, "fetch")) action = "正在读取";
    else if (strstr(fn_name, "time")) action = "获取时间中";
    else if (strstr(fn_name, "device")) action = "获取设备信息中";
    else if (strstr(fn_name, "generate_image")) action = "正在生成图片";
    else if (strstr(fn_name, "get_image")) action = "正在解析图片";

    if (display[0]) {
        return (size_t)snprintf(out, size, "\n\n:::tool\n%s"%s"…\n:::\n\n", action, display);
    } else {
        return (size_t)snprintf(out, size, "\n\n:::tool\n%s…\n:::\n\n", action);
    }
}

size_t tool_build_done_marker(const char* fn_name, const char* args,
                              char* out, size_t size) {
    if (!fn_name || !out || size == 0) return 0;

    char display[256];
    extract_display_text(fn_name, args, display, sizeof(display));

    const char* action = "已完成工具调用";
    if (strstr(fn_name, "search")) action = "已搜索";
    else if (strstr(fn_name, "fetch")) action = "已读取";
    else if (strstr(fn_name, "time")) action = "已获取时间";
    else if (strstr(fn_name, "device")) action = "已获取设备信息";
    else if (strstr(fn_name, "generate_image")) action = "已生成图片";
    else if (strstr(fn_name, "get_image")) action = "已解析图片";

    if (display[0]) {
        /* 截断长 URL */
        if (strlen(display) > 60) {
            display[60] = '\xe2'; /* … */
            display[61] = '\x80';
            display[62] = '\xa6';
            display[63] = '\0';
        }
        return (size_t)snprintf(out, size, "\n:::tool\n%s"%s"\n:::\n", action, display);
    } else {
        return (size_t)snprintf(out, size, "\n:::tool\n%s\n:::\n", action);
    }
}
