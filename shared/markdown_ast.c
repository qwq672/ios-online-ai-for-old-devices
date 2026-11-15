/**
 * markdown_ast.c — Shared Markdown AST (C)
 * v261113: 跨平台共享 C 层
 *
 * 极简 Markdown → AST 解析器（纯 C，无外部依赖）
 * 只做结构解析，不渲染 UI
 */

#include "markdown_ast.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* 创建节点 */
static md_node* make_node(md_node_type type, const char* text) {
    md_node* n = (md_node*)calloc(1, sizeof(md_node));
    if (!n) return NULL;
    n->type = type;
    if (text) {
        size_t len = strlen(text) + 1;
        n->text = (char*)malloc(len);
        if (n->text) memcpy((char*)n->text, text, len);
    }
    return n;
}

/* 提取行首到行尾的内容（跳过前缀） */
static char* extract_after(const char* line, int prefix_len) {
    if (!line) return NULL;
    int len = strlen(line);
    if (len <= prefix_len) return NULL;
    const char* start = line + prefix_len;
    /* trim leading spaces */
    while (*start == ' ' || *start == '\t') start++;
    /* trim trailing whitespace */
    const char* end = line + len - 1;
    while (end > start && (*end == ' ' || *end == '\t' || *end == '\r' || *end == '\n')) end--;
    int result_len = end - start + 1;
    if (result_len <= 0) return NULL;
    char* result = (char*)malloc(result_len + 1);
    if (!result) return NULL;
    memcpy(result, start, result_len);
    result[result_len] = '\0';
    return result;
}

/* 检查是否是分隔行 |---|---| */
static int is_table_sep(const char* line) {
    if (!line) return 0;
    for (const char* p = line; *p; p++) {
        if (*p != '|' && *p != '-' && *p != ':' && *p != ' ' && *p != '\t' && *p != '\r' && *p != '\n')
            return 0;
    }
    return strchr(line, '|') != NULL && strchr(line, '-') != NULL;
}

md_node* md_parse(const char* text) {
    if (!text || !*text) return NULL;

    md_node* head = NULL;
    md_node* tail = NULL;

    /* 复制一份，用 strtok 安全分割 */
    size_t text_len = strlen(text);
    char* copy = (char*)malloc(text_len + 1);
    if (!copy) return NULL;
    memcpy(copy, text, text_len + 1);

    char* saveptr = NULL;
    char* line = strtok_r(copy, "\n", &saveptr);

    /* 状态 */
    int in_code_block = 0;
    int in_tool_block = 0;
    int in_thinking_block = 0;
    char code_buf[65536]; code_buf[0] = '\0';
    int code_buf_len = 0;
    char block_buf[65536]; block_buf[0] = '\0';
    int block_buf_len = 0;

    while (line) {
        /* 移除 \r */
        int llen = strlen(line);
        while (llen > 0 && (line[llen-1] == '\r')) line[--llen] = '\0';

        /* 代码块 */
        if (strncmp(line, "```", 3) == 0) {
            if (in_code_block) {
                /* 关闭 */
                code_buf[code_buf_len] = '\0';
                md_node* n = make_node(MD_NODE_CODE_BLOCK, code_buf);
                if (tail) { tail->next = n; } else { head = n; }
                tail = n;
                code_buf_len = 0;
                in_code_block = 0;
            } else {
                in_code_block = 1;
                code_buf_len = 0;
            }
            line = strtok_r(NULL, "\n", &saveptr);
            continue;
        }
        if (in_code_block) {
            if (code_buf_len + llen + 2 < (int)sizeof(code_buf)) {
                memcpy(code_buf + code_buf_len, line, llen);
                code_buf_len += llen;
                code_buf[code_buf_len++] = '\n';
            }
            line = strtok_r(NULL, "\n", &saveptr);
            continue;
        }

        /* :::tool block */
        if (strcmp(line, ":::tool") == 0) {
            if (in_tool_block) {
                block_buf[block_buf_len] = '\0';
                md_node* n = make_node(MD_NODE_TOOL_BLOCK, block_buf);
                if (tail) { tail->next = n; } else { head = n; }
                tail = n;
                block_buf_len = 0;
                in_tool_block = 0;
            } else {
                in_tool_block = 1;
                block_buf_len = 0;
            }
            line = strtok_r(NULL, "\n", &saveptr);
            continue;
        }
        if (in_tool_block) {
            if (block_buf_len + llen + 2 < (int)sizeof(block_buf)) {
                memcpy(block_buf + block_buf_len, line, llen);
                block_buf_len += llen;
                block_buf[block_buf_len++] = '\n';
            }
            line = strtok_r(NULL, "\n", &saveptr);
            continue;
        }

        /* :::thinking block */
        if (strcmp(line, ":::thinking") == 0) {
            if (in_thinking_block) {
                block_buf[block_buf_len] = '\0';
                md_node* n = make_node(MD_NODE_THINKING, block_buf);
                if (tail) { tail->next = n; } else { head = n; }
                tail = n;
                block_buf_len = 0;
                in_thinking_block = 0;
            } else {
                in_thinking_block = 1;
                block_buf_len = 0;
            }
            line = strtok_r(NULL, "\n", &saveptr);
            continue;
        }
        if (in_thinking_block) {
            if (block_buf_len + llen + 2 < (int)sizeof(block_buf)) {
                memcpy(block_buf + block_buf_len, line, llen);
                block_buf_len += llen;
                block_buf[block_buf_len++] = '\n';
            }
            line = strtok_r(NULL, "\n", &saveptr);
            continue;
        }

        /* 空行 */
        if (llen == 0 || (llen == 1 && line[0] == ' ')) {
            md_node* n = make_node(MD_NODE_BLANK, NULL);
            if (tail) { tail->next = n; } else { head = n; }
            tail = n;
            line = strtok_r(NULL, "\n", &saveptr);
            continue;
        }

        /* 标题 */
        if (strncmp(line, "### ", 4) == 0) {
            md_node* n = make_node(MD_NODE_HEADING_3, extract_after(line, 4));
            if (tail) { tail->next = n; } else { head = n; }
            tail = n;
            line = strtok_r(NULL, "\n", &saveptr);
            continue;
        }
        if (strncmp(line, "## ", 3) == 0) {
            md_node* n = make_node(MD_NODE_HEADING_2, extract_after(line, 3));
            if (tail) { tail->next = n; } else { head = n; }
            tail = n;
            line = strtok_r(NULL, "\n", &saveptr);
            continue;
        }
        if (strncmp(line, "# ", 2) == 0) {
            md_node* n = make_node(MD_NODE_HEADING_1, extract_after(line, 2));
            if (tail) { tail->next = n; } else { head = n; }
            tail = n;
            line = strtok_r(NULL, "\n", &saveptr);
            continue;
        }

        /* 水平线 */
        if (strcmp(line, "---") == 0 || strcmp(line, "***") == 0 || strcmp(line, "___") == 0) {
            md_node* n = make_node(MD_NODE_HR, NULL);
            if (tail) { tail->next = n; } else { head = n; }
            tail = n;
            line = strtok_r(NULL, "\n", &saveptr);
            continue;
        }

        /* 引用 */
        if (line[0] == '>') {
            md_node* n = make_node(MD_NODE_BLOCKQUOTE, extract_after(line, 1));
            if (tail) { tail->next = n; } else { head = n; }
            tail = n;
            line = strtok_r(NULL, "\n", &saveptr);
            continue;
        }

        /* 列表项 */
        if ((strncmp(line, "- ", 2) == 0) || (strncmp(line, "* ", 2) == 0) || (strncmp(line, "+ ", 2) == 0)) {
            md_node* n = make_node(MD_NODE_LIST_ITEM, extract_after(line, 2));
            if (tail) { tail->next = n; } else { head = n; }
            tail = n;
            line = strtok_r(NULL, "\n", &saveptr);
            continue;
        }
        /* 数字列表 1. 2. 等 */
        if (line[0] >= '0' && line[0] <= '9') {
            const char* p = line;
            while (*p >= '0' && *p <= '9') p++;
            if (*p == '.' && *(p+1) == ' ') {
                md_node* n = make_node(MD_NODE_LIST_ITEM, extract_after(line, (int)(p - line + 2)));
                if (tail) { tail->next = n; } else { head = n; }
                tail = n;
                line = strtok_r(NULL, "\n", &saveptr);
                continue;
            }
        }

        /* 表格 */
        if (line[0] == '|') {
            if (is_table_sep(line)) {
                md_node* n = make_node(MD_NODE_TABLE_SEP, NULL);
                if (tail) { tail->next = n; } else { head = n; }
                tail = n;
            } else {
                md_node* n = make_node(MD_NODE_TABLE_ROW, strdup(line));
                if (tail) { tail->next = n; } else { head = n; }
                tail = n;
            }
            line = strtok_r(NULL, "\n", &saveptr);
            continue;
        }

        /* 普通文字 */
        md_node* n = make_node(MD_NODE_TEXT, line);
        if (tail) { tail->next = n; } else { head = n; }
        tail = n;

        line = strtok_r(NULL, "\n", &saveptr);
    }

    /* 未闭合的块 */
    if (in_code_block && code_buf_len > 0) {
        code_buf[code_buf_len] = '\0';
        md_node* n = make_node(MD_NODE_CODE_BLOCK, code_buf);
        if (tail) { tail->next = n; } else { head = n; }
        tail = n;
    }

    free(copy);
    return head;
}

void md_free(md_node* head) {
    while (head) {
        md_node* next = head->next;
        if (head->text) free((void*)head->text);
        if (head->url) free((void*)head->url);
        if (head->alt) free((void*)head->alt);
        if (head->lang) free((void*)head->lang);
        free(head);
        head = next;
    }
}

int md_count(const md_node* head) {
    int count = 0;
    while (head) { count++; head = head->next; }
    return count;
}
