/**
 * markdown_ast.h — Shared Markdown AST (C)
 * v261113: 跨平台共享 C 层 — Markdown 结构化解析
 *
 * 把 Markdown 文本解析成 AST 节点（不渲染成平台 UI）。
 * 各平台 wrapper 把 AST 转成原生 UI（iOS NSAttributedString / Android Spannable / UWP RichText）。
 *
 * 设计原则：
 *   - 核心层不含 UI、不含平台主题、不含颜色
 *   - 只输出结构化数据（节点类型 + 内容）
 *   - 调用方负责渲染
 */

#ifndef MARKDOWN_AST_H
#define MARKDOWN_AST_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* AST 节点类型 */
typedef enum {
    MD_NODE_TEXT,          // 普通文字
    MD_NODE_BOLD,          // **bold**
    MD_NODE_ITALIC,        // *italic*
    MD_NODE_CODE_INLINE,   // `code`
    MD_NODE_LINK,          // [text](url)
    MD_NODE_IMAGE,         // ![alt](url)
    MD_NODE_HEADING_1,     // # title
    MD_NODE_HEADING_2,     // ## title
    MD_NODE_HEADING_3,     // ### title
    MD_NODE_CODE_BLOCK,    // ```code```
    MD_NODE_BLOCKQUOTE,    // > quote
    MD_NODE_LIST_ITEM,     // - item / 1. item
    MD_NODE_TABLE_ROW,     // | cell | cell |
    MD_NODE_TABLE_SEP,     // |---|---|
    MD_NODE_TOOL_BLOCK,    // :::tool ... :::
    MD_NODE_THINKING,      // :::thinking ... :::
    MD_NODE_HR,            // --- / ***
    MD_NODE_BLANK,         // 空行
} md_node_type;

/* AST 节点 */
typedef struct md_node {
    md_node_type type;
    const char* text;       // 主文本内容（已分配，需 free）
    const char* url;        // 链接/图片 URL（NULL = 无）
    const char* alt;        // 图片 alt 文本（NULL = 无）
    const char* lang;       // 代码块语言（NULL = 无）
    struct md_node* next;   // 链表下一节点
} md_node;

/**
 * 解析 Markdown 文本 → AST 节点链表
 * @param text  Markdown 文本（UTF-8）
 * @return 链表头节点（NULL = 失败/空文本）
 */
md_node* md_parse(const char* text);

/**
 * 释放 AST 节点链表
 */
void md_free(md_node* head);

/**
 * 统计节点数量
 */
int md_count(const md_node* head);

#ifdef __cplusplus
}
#endif

#endif /* MARKDOWN_AST_H */
