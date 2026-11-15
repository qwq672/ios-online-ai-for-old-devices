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

        /* :::tool block — 关闭用 ::: (不是 :::tool) */
        if (strcmp(line, ":::tool") == 0) {
            if (!in_tool_block) {
                in_tool_block = 1;
                block_buf_len = 0;
            }
            line = strtok_r(NULL, "\n", &saveptr);
            continue;
        }
        if (in_tool_block && strcmp(line, ":::") == 0) {
            block_buf[block_buf_len] = '\0';
            md_node* n = make_node(MD_NODE_TOOL_BLOCK, block_buf);
            if (tail) { tail->next = n; } else { head = n; }
            tail = n;
            block_buf_len = 0;
            in_tool_block = 0;
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

        /* :::thinking block — 关闭用 ::: */
        if (strcmp(line, ":::thinking") == 0) {
            if (!in_thinking_block) {
                in_thinking_block = 1;
                block_buf_len = 0;
            }
            line = strtok_r(NULL, "\n", &saveptr);
            continue;
        }
        if (in_thinking_block && strcmp(line, ":::") == 0) {
            block_buf[block_buf_len] = '\0';
            md_node* n = make_node(MD_NODE_THINKING, block_buf);
            if (tail) { tail->next = n; } else { head = n; }
            tail = n;
            block_buf_len = 0;
            in_thinking_block = 0;
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

/* v261116-6: === 行内解析 === */

/* 创建行内节点 */
static md_inline_node* make_inline(md_inline_type type, const char* text, const char* url, const char* alt) {
    md_inline_node* n = (md_inline_node*)calloc(1, sizeof(md_inline_node));
    if (!n) return NULL;
    n->type = type;
    if (text) {
        size_t len = strlen(text) + 1;
        n->text = (char*)malloc(len);
        if (n->text) memcpy((char*)n->text, text, len);
    }
    if (url) {
        size_t len = strlen(url) + 1;
        n->url = (char*)malloc(len);
        if (n->url) memcpy((char*)n->url, url, len);
    }
    if (alt) {
        size_t len = strlen(alt) + 1;
        n->alt = (char*)malloc(len);
        if (n->alt) memcpy((char*)n->alt, alt, len);
    }
    return n;
}

/* 在 text 中查找 needle 的位置（从 from 开始） */
static const char* find_from(const char* text, const char* needle, int from) {
    if (!text || !needle) return NULL;
    int text_len = (int)strlen(text);
    int needle_len = (int)strlen(needle);
    if (needle_len == 0 || from + needle_len > text_len) return NULL;
    for (int i = from; i <= text_len - needle_len; i++) {
        if (memcmp(text + i, needle, needle_len) == 0) return text + i;
    }
    return NULL;
}

/* 截取字符串 [start, end) */
static char* substr(const char* text, int start, int end) {
    if (!text || end <= start) return NULL;
    int len = end - start;
    char* r = (char*)malloc(len + 1);
    if (!r) return NULL;
    memcpy(r, text + start, len);
    r[len] = '\0';
    return r;
}

/**
 * 解析行内 Markdown → 行内节点链表
 * 支持: **bold**, *italic*, `code`, [text](url), ![alt](url)
 * 算法: 用简单状态机扫描，遇到 ** 或 * 或 ` 或 ![ 或 [ 时切换状态
 */
md_inline_node* md_parse_inline(const char* text) {
    if (!text || !*text) return NULL;
    int len = (int)strlen(text);

    md_inline_node* head = NULL;
    md_inline_node* tail = NULL;
    int i = 0;
    int text_start = 0;  /* 当前普通文字段的起点 */

    while (i < len) {
        /* 图片 ![alt](url) — 必须在 link [ 之前检测 */
        if (i + 1 < len && text[i] == '!' && text[i+1] == '[') {
            const char* close_bracket = find_from(text, "](", i + 2);
            if (close_bracket) {
                const char* close_paren = find_from(text, ")", (int)(close_bracket - text) + 2);
                if (close_paren) {
                    /* flush pending text */
                    if (i > text_start) {
                        char* s = substr(text, text_start, i);
                        md_inline_node* n = make_inline(MD_INLINE_TEXT, s, NULL, NULL);
                        if (tail) { tail->next = n; } else { head = n; }
                        tail = n;
                        free(s);
                    }
                    int alt_start = i + 2;
                    int alt_end = (int)(close_bracket - text);
                    char* alt_str = substr(text, alt_start, alt_end);
                    int url_start = alt_end + 2;
                    int url_end = (int)(close_paren - text);
                    char* url_str = substr(text, url_start, url_end);
                    md_inline_node* n = make_inline(MD_INLINE_IMAGE, alt_str, url_str, alt_str);
                    if (tail) { tail->next = n; } else { head = n; }
                    tail = n;
                    free(alt_str);
                    free(url_str);
                    i = url_end + 1;
                    text_start = i;
                    continue;
                }
            }
        }
        /* 链接 [text](url) */
        if (text[i] == '[') {
            const char* close_bracket = find_from(text, "](", i + 1);
            if (close_bracket) {
                const char* close_paren = find_from(text, ")", (int)(close_bracket - text) + 2);
                if (close_paren) {
                    if (i > text_start) {
                        char* s = substr(text, text_start, i);
                        md_inline_node* n = make_inline(MD_INLINE_TEXT, s, NULL, NULL);
                        if (tail) { tail->next = n; } else { head = n; }
                        tail = n;
                        free(s);
                    }
                    int text_s = i + 1;
                    int text_e = (int)(close_bracket - text);
                    char* link_text = substr(text, text_s, text_e);
                    int url_s = text_e + 2;
                    int url_e = (int)(close_paren - text);
                    char* url_str = substr(text, url_s, url_e);
                    md_inline_node* n = make_inline(MD_INLINE_LINK, link_text, url_str, NULL);
                    if (tail) { tail->next = n; } else { head = n; }
                    tail = n;
                    free(link_text);
                    free(url_str);
                    i = url_e + 1;
                    text_start = i;
                    continue;
                }
            }
        }
        /* 行内代码 `code` */
        if (text[i] == '`') {
            const char* close = find_from(text, "`", i + 1);
            if (close) {
                if (i > text_start) {
                    char* s = substr(text, text_start, i);
                    md_inline_node* n = make_inline(MD_INLINE_TEXT, s, NULL, NULL);
                    if (tail) { tail->next = n; } else { head = n; }
                    tail = n;
                    free(s);
                }
                int code_s = i + 1;
                int code_e = (int)(close - text);
                char* code_str = substr(text, code_s, code_e);
                md_inline_node* n = make_inline(MD_INLINE_CODE, code_str, NULL, NULL);
                if (tail) { tail->next = n; } else { head = n; }
                tail = n;
                free(code_str);
                i = code_e + 1;
                text_start = i;
                continue;
            }
        }
        /* 粗体 **bold** */
        if (i + 1 < len && text[i] == '*' && text[i+1] == '*') {
            const char* close = find_from(text, "**", i + 2);
            if (close) {
                if (i > text_start) {
                    char* s = substr(text, text_start, i);
                    md_inline_node* n = make_inline(MD_INLINE_TEXT, s, NULL, NULL);
                    if (tail) { tail->next = n; } else { head = n; }
                    tail = n;
                    free(s);
                }
                int bold_s = i + 2;
                int bold_e = (int)(close - text);
                char* bold_str = substr(text, bold_s, bold_e);
                md_inline_node* n = make_inline(MD_INLINE_BOLD, bold_str, NULL, NULL);
                if (tail) { tail->next = n; } else { head = n; }
                tail = n;
                free(bold_str);
                i = bold_e + 2;
                text_start = i;
                continue;
            }
        }
        /* 斜体 *italic* — 不能是 ** 已被上面处理 */
        if (text[i] == '*' && (i + 1 >= len || text[i+1] != '*')) {
            const char* close = find_from(text, "*", i + 1);
            /* close 不能是 ** */
            if (close && (close[1] != '*')) {
                if (i > text_start) {
                    char* s = substr(text, text_start, i);
                    md_inline_node* n = make_inline(MD_INLINE_TEXT, s, NULL, NULL);
                    if (tail) { tail->next = n; } else { head = n; }
                    tail = n;
                    free(s);
                }
                int italic_s = i + 1;
                int italic_e = (int)(close - text);
                char* italic_str = substr(text, italic_s, italic_e);
                md_inline_node* n = make_inline(MD_INLINE_ITALIC, italic_str, NULL, NULL);
                if (tail) { tail->next = n; } else { head = n; }
                tail = n;
                free(italic_str);
                i = italic_e + 1;
                text_start = i;
                continue;
            }
        }
        i++;
    }

    /* flush 末尾剩余普通文字 */
    if (text_start < len) {
        char* s = substr(text, text_start, len);
        if (s) {
            md_inline_node* n = make_inline(MD_INLINE_TEXT, s, NULL, NULL);
            if (tail) { tail->next = n; } else { head = n; }
            tail = n;
            free(s);
        }
    }

    return head;
}

void md_inline_free(md_inline_node* head) {
    while (head) {
        md_inline_node* next = head->next;
        if (head->text) free((void*)head->text);
        if (head->url) free((void*)head->url);
        if (head->alt) free((void*)head->alt);
        free(head);
        head = next;
    }
}

int md_inline_count(const md_inline_node* head) {
    int count = 0;
    while (head) { count++; head = head->next; }
    return count;
}
