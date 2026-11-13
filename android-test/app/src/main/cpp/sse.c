/**
 * sse.c — Shared SSE (Server-Sent Events) parser
 * v261113: 跨平台共享 C 层
 *
 * 解析 SSE 格式（RFC 8895 简化版）：
 *   - "data: xxx" → 提取 xxx
 *   - 多行 data 用 \n 拼接
 *   - 空行 → 事件结束 → 触发 callback
 *   - "data: [DONE]" → done=1
 *   - 其他字段（event:/id:/retry:）忽略
 *   - 跨 feed 调用的不完整行自动缓冲
 *
 * 无平台依赖，纯 C，可被 iOS（Obj-C++）/ Android（JNI）/ UWP（P/Invoke）调用。
 */

#include "sse.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#define SSE_BUF_INIT  4096    /* 初始缓冲区 */
#define SSE_BUF_MAX   65536   /* 最大缓冲区（单行不超过 64KB） */

struct sse_parser {
    /* 回调 */
    sse_data_callback cb;
    void* user;

    /* 行缓冲（跨 feed 调用保持不完整行） */
    char* line_buf;        /* 当前行缓冲 */
    size_t line_len;       /* 当前行长度 */
    size_t line_cap;       /* 行缓冲容量 */

    /* data 事件缓冲（多行 data: 拼接） */
    char* data_buf;        /* 当前事件的数据 */
    size_t data_len;       /* 数据长度 */
    size_t data_cap;       /* 数据容量 */

    int has_data;          /* 当前事件是否有 data 行 */
};

/* 确保缓冲区容量足够 */
static int ensure_cap(char** buf, size_t* cap, size_t need) {
    if (*cap >= need) return 1;
    size_t new_cap = *cap;
    while (new_cap < need) {
        new_cap *= 2;
        if (new_cap > SSE_BUF_MAX) return 0;
    }
    char* new_buf = (char*)realloc(*buf, new_cap);
    if (!new_buf) return 0;
    *buf = new_buf;
    *cap = new_cap;
    return 1;
}

/* 追加数据到 data_buf */
static void append_data(sse_parser* p, const char* s, size_t len) {
    if (!ensure_cap(&p->data_buf, &p->data_cap, p->data_len + len + 1)) return;
    memcpy(p->data_buf + p->data_len, s, len);
    p->data_len += len;
}

/* 处理完整的一行 */
static void process_line(sse_parser* p) {
    /* 空行 → 事件结束 */
    if (p->line_len == 0) {
        if (p->has_data && p->data_len > 0) {
            /* 检查 [DONE] */
            int done = (p->data_len >= 6 && memcmp(p->data_buf, "[DONE]", 6) == 0);
            /* null-terminate for callback safety */
            if (ensure_cap(&p->data_buf, &p->data_cap, p->data_len + 1)) {
                p->data_buf[p->data_len] = '\0';
            }
            if (p->cb) {
                p->cb(p->data_buf, p->data_len, done, p->user);
            }
        }
        /* 重置事件 */
        p->data_len = 0;
        p->has_data = 0;
        return;
    }

    /* data: 行 */
    if (p->line_len >= 5 && memcmp(p->line_buf, "data:", 5) == 0) {
        const char* val = p->line_buf + 5;
        size_t val_len = p->line_len - 5;
        /* 跳过前导空格 */
        while (val_len > 0 && (*val == ' ' || *val == '\t')) {
            val++;
            val_len--;
        }
        /* 多行 data: 用 \n 拼接 */
        if (p->has_data) {
            append_data(p, "\n", 1);
        }
        append_data(p, val, val_len);
        p->has_data = 1;
        return;
    }

    /* 其他字段（event:/id:/retry:/comment）忽略 */
}

sse_parser* sse_parser_create(sse_data_callback cb, void* user_data) {
    sse_parser* p = (sse_parser*)calloc(1, sizeof(sse_parser));
    if (!p) return NULL;
    p->cb = cb;
    p->user = user_data;
    p->line_cap = SSE_BUF_INIT;
    p->line_buf = (char*)malloc(p->line_cap);
    p->data_cap = SSE_BUF_INIT;
    p->data_buf = (char*)malloc(p->data_cap);
    if (!p->line_buf || !p->data_buf) {
        sse_parser_destroy(p);
        return NULL;
    }
    return p;
}

void sse_parser_destroy(sse_parser* p) {
    if (!p) return;
    free(p->line_buf);
    free(p->data_buf);
    free(p);
}

void sse_parser_reset(sse_parser* p) {
    if (!p) return;
    p->line_len = 0;
    p->data_len = 0;
    p->has_data = 0;
}

void sse_parser_feed(sse_parser* p, const char* data, size_t len) {
    if (!p || !data || len == 0) return;

    for (size_t i = 0; i < len; i++) {
        char c = data[i];

        /* 换行符处理：\n 或 \r\n 或 \r */
        if (c == '\n' || c == '\r') {
            /* 处理完整行 */
            process_line(p);
            p->line_len = 0;

            /* \r\n 跳过 \n */
            if (c == '\r' && i + 1 < len && data[i + 1] == '\n') {
                i++;
            }
            continue;
        }

        /* 追加到行缓冲 */
        if (!ensure_cap(&p->line_buf, &p->line_cap, p->line_len + 1)) {
            /* 缓冲区满 → 强制处理当前行（截断） */
            process_line(p);
            p->line_len = 0;
        }
        p->line_buf[p->line_len++] = c;
    }
}
