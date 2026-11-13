package com.awa.aichat.markdown;

import android.graphics.Color;
import android.graphics.Typeface;
import android.text.SpannableStringBuilder;
import android.text.Spanned;
import android.text.style.BackgroundColorSpan;
import android.text.style.ForegroundColorSpan;
import android.text.style.RelativeSizeSpan;
import android.text.style.StyleSpan;
import android.text.style.TypefaceSpan;
import android.text.style.URLSpan;
import android.text.style.UnderlineSpan;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Basic Markdown → Spannable renderer for Android 2.3+.
 * Supports: bold (**), italic (*), code (`), code blocks (```),
 * links [text](url), headers (#), lists (-, *), blockquote (>).
 *
 * v0.2 changes:
 *  - Added parseCached(text, dark) — caches the rendered Spannable by
 *    a (length, dark) key so streaming re-parses only when the text
 *    actually changed. This avoids the v0.1 issue of re-parsing the
 *    whole message on every SSE chunk.
 *  - Code block background is now theme-aware (dark vs light).
 *  - Blockquote gets a colored left bar effect (we prepend ▎ and tint
 *    it with the secondary text color).
 *  - Link color comes from the accent color so links are visible
 *    in both themes.
 *  - Headers get an accent color tint so they stand out.
 */
public class MarkdownParser {

    // v0.3: LRU cache of recently rendered spans. Key = length|dark, value = parsed.
    // We don't key on the full text because that would hold strong refs
    // to potentially huge strings; length-based invalidation is good
    // enough for streaming (content only changes by appending).
    //
    // v0.3 fix: android.util.LruCache 是 API 12（Honeycomb MR1）加入的，
    // 不是 API 9！Android 2.3 (API 9-11) 上 LruCache 类不存在 → MarkdownParser
    // 类静态初始化抛 NoClassDefFoundError → ChatAdapter.getView 调 parseCached
    // 时崩 → 一点发送就闪退。这是"老设备闪退，新设备没问题"的根因。
    // 改用 LinkedHashMap + removeEldestEntry 自己实现 LRU（API 1 兼容）。
    private static final int MAX_CACHE = 64;
    private static final LinkedHashMap<String, SpannableStringBuilder> CACHE =
        new LinkedHashMap<String, SpannableStringBuilder>(16, 0.75f, true) {
            @Override
            protected boolean removeEldestEntry(Map.Entry<String, SpannableStringBuilder> eldest) {
                return size() > MAX_CACHE;
            }
        };
    private static final Object CACHE_LOCK = new Object();

    // Theme color cache (resolved lazily).
    private static int lightCodeBg = 0xFFF4F4F8;
    private static int darkCodeBg  = 0xFF2A2A35;
    private static int lightBlockBg = 0xFF000000;  // code block (terminal-like)
    private static int darkBlockBg  = 0xFF000000;
    private static int lightBlockFg = 0xFFE8E8E8;
    private static int darkBlockFg  = 0xFFE8E8E8;
    private static int lightAccent  = 0xFF3B82F6;
    private static int darkAccent   = 0xFF5B9BFF;
    private static int lightQuote   = 0xFF666666;
    private static int darkQuote    = 0xFF9090A0;

    /** Stream-friendly cached parse — re-renders only when content changed. */
    public static SpannableStringBuilder parseCached(String text, boolean dark) {
        if (text == null || text.length() == 0) {
            return new SpannableStringBuilder();
        }
        String key = (dark ? "d" : "l") + ":" + text.length() + ":" + (text.hashCode() & 0x7FFFFFFF);
        synchronized (CACHE_LOCK) {
            SpannableStringBuilder cached = CACHE.get(key);
            if (cached != null) return cached;
        }
        SpannableStringBuilder rendered = parse(text, dark);
        synchronized (CACHE_LOCK) {
            CACHE.put(key, rendered);
        }
        return rendered;
    }

    /** Original entry point — kept for backward compat (uses light theme). */
    public static SpannableStringBuilder parse(String text) {
        return parse(text, false);
    }

    public static SpannableStringBuilder parse(String text, boolean dark) {
        if (text == null || text.length() == 0) {
            return new SpannableStringBuilder();
        }

        int codeBg     = dark ? darkCodeBg   : lightCodeBg;
        int blockBg    = dark ? darkBlockBg  : lightBlockBg;
        int blockFg    = dark ? darkBlockFg  : lightBlockFg;
        int accent     = dark ? darkAccent   : lightAccent;
        int quoteColor = dark ? darkQuote    : lightQuote;

        SpannableStringBuilder sb = new SpannableStringBuilder();
        String[] lines = text.split("\n");
        boolean inCodeBlock = false;
        boolean inToolBlock = false;
        StringBuilder codeBlockBuf = new StringBuilder();
        StringBuilder toolBlockBuf = new StringBuilder();

        // v0.4: tool call text 颜色（灰色，比正文暗）
        int toolColor = dark ? 0xFF8C8C8C : 0xFF999999;

        for (int i = 0; i < lines.length; i++) {
            String line = lines[i];

            // v0.4: :::tool fence — 工具调用状态（灰色斜体 + "·" 前缀）
            if (line.trim().equals(":::tool")) {
                if (inToolBlock) {
                    // Close — flush tool block
                    if (toolBlockBuf.length() > 0) {
                        String toolText = toolBlockBuf.toString().trim();
                        if (toolText.endsWith("\n")) toolText = toolText.substring(0, toolText.length() - 1);
                        String display = "· " + toolText.replace("\n", " · ");
                        int start = sb.length();
                        sb.append("\n").append(display).append("\n\n");
                        int end = sb.length();
                        sb.setSpan(new StyleSpan(android.graphics.Typeface.ITALIC), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                        sb.setSpan(new ForegroundColorSpan(toolColor), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                        sb.setSpan(new RelativeSizeSpan(0.9f), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                    }
                    toolBlockBuf.setLength(0);
                    inToolBlock = false;
                } else {
                    inToolBlock = true;
                    toolBlockBuf.setLength(0);
                }
                continue;
            }

            if (inToolBlock) {
                toolBlockBuf.append(line).append("\n");
                continue;
            }

            // Code fence toggle
            if (line.trim().startsWith("```")) {
                if (inCodeBlock) {
                    // Close — flush code block
                    if (codeBlockBuf.length() > 0) {
                        // Trim trailing newline added during accumulation.
                        String blockText = codeBlockBuf.toString();
                        if (blockText.endsWith("\n")) {
                            blockText = blockText.substring(0, blockText.length() - 1);
                        }
                        int start = sb.length();
                        sb.append(blockText);
                        int end = sb.length();
                        sb.setSpan(new TypefaceSpan("monospace"), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                        sb.setSpan(new BackgroundColorSpan(blockBg), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                        sb.setSpan(new ForegroundColorSpan(blockFg), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                        sb.setSpan(new RelativeSizeSpan(0.9f), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                        sb.append("\n");
                    }
                    codeBlockBuf.setLength(0);
                    inCodeBlock = false;
                } else {
                    inCodeBlock = true;
                    codeBlockBuf.setLength(0);
                }
                continue;
            }

            if (inCodeBlock) {
                codeBlockBuf.append(line).append("\n");
                continue;
            }

            // Headers
            if (line.startsWith("### ")) {
                int start = sb.length();
                sb.append(line.substring(4));
                sb.setSpan(new StyleSpan(Typeface.BOLD), start, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                sb.setSpan(new RelativeSizeSpan(1.2f), start, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                sb.setSpan(new ForegroundColorSpan(accent), start, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                sb.append("\n");
                continue;
            }
            if (line.startsWith("## ")) {
                int start = sb.length();
                sb.append(line.substring(3));
                sb.setSpan(new StyleSpan(Typeface.BOLD), start, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                sb.setSpan(new RelativeSizeSpan(1.35f), start, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                sb.setSpan(new ForegroundColorSpan(accent), start, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                sb.append("\n");
                continue;
            }
            if (line.startsWith("# ")) {
                int start = sb.length();
                sb.append(line.substring(2));
                sb.setSpan(new StyleSpan(Typeface.BOLD), start, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                sb.setSpan(new RelativeSizeSpan(1.5f), start, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                sb.setSpan(new ForegroundColorSpan(accent), start, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                sb.append("\n");
                continue;
            }

            // List items
            if (line.startsWith("- ") || line.startsWith("* ") || line.startsWith("+ ")) {
                int start = sb.length();
                sb.append("•  ");
                sb.setSpan(new ForegroundColorSpan(accent), start, start + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                appendInline(sb, line.substring(2), codeBg, accent);
                sb.append("\n");
                continue;
            }

            // Numbered list items (e.g. "1. xxx")
            Matcher numList = Pattern.compile("^(\\d+)\\.\\s").matcher(line);
            if (numList.find()) {
                appendInline(sb, numList.group(0) + " ", codeBg, accent);
                appendInline(sb, line.substring(numList.end()), codeBg, accent);
                sb.append("\n");
                continue;
            }

            // Blockquote
            if (line.startsWith(">")) {
                String body = line.substring(1).trim();
                int start = sb.length();
                sb.append("▎ ").append(body);
                // Tint the bar character.
                sb.setSpan(new ForegroundColorSpan(accent), start, start + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                // Tint the rest with quote color + italic.
                sb.setSpan(new ForegroundColorSpan(quoteColor), start + 1, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                sb.setSpan(new StyleSpan(Typeface.ITALIC), start + 1, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                sb.append("\n");
                continue;
            }

            // Horizontal rule
            if (line.equals("---") || line.equals("***") || line.equals("___")) {
                sb.append("────────────────\n");
                continue;
            }

            // Normal line — parse inline markup
            appendInline(sb, line, codeBg, accent);
            sb.append("\n");
        }

        // Flush unclosed code block
        if (inCodeBlock && codeBlockBuf.length() > 0) {
            String blockText = codeBlockBuf.toString();
            if (blockText.endsWith("\n")) {
                blockText = blockText.substring(0, blockText.length() - 1);
            }
            int start = sb.length();
            sb.append(blockText);
            sb.setSpan(new TypefaceSpan("monospace"), start, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            sb.setSpan(new BackgroundColorSpan(blockBg), start, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            sb.setSpan(new ForegroundColorSpan(blockFg), start, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        }

        return sb;
    }

    /**
     * Parse inline markdown: **bold**, *italic*, `code`, [text](url).
     */
    private static void appendInline(SpannableStringBuilder sb, String text,
                                     int codeBg, int accent) {
        Pattern p = Pattern.compile("(\\*\\*(.+?)\\*\\*)|(\\*(.+?)\\*)|(`(.+?)`)|(\\[(.+?)\\]\\((.+?)\\))");
        Matcher m = p.matcher(text);
        int lastEnd = 0;

        while (m.find()) {
            // Append text before match
            if (m.start() > lastEnd) {
                sb.append(text.substring(lastEnd, m.start()));
            }

            String bold = m.group(2);
            String italic = m.group(4);
            String code = m.group(6);
            String linkText = m.group(8);
            String linkUrl = m.group(9);

            if (bold != null) {
                int start = sb.length();
                sb.append(bold);
                sb.setSpan(new StyleSpan(Typeface.BOLD), start, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            } else if (italic != null) {
                int start = sb.length();
                sb.append(italic);
                sb.setSpan(new StyleSpan(Typeface.ITALIC), start, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            } else if (code != null) {
                int start = sb.length();
                sb.append(code);
                sb.setSpan(new TypefaceSpan("monospace"), start, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                sb.setSpan(new BackgroundColorSpan(codeBg), start, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                sb.setSpan(new ForegroundColorSpan(accent), start, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            } else if (linkText != null) {
                int start = sb.length();
                sb.append(linkText);
                sb.setSpan(new URLSpan(linkUrl), start, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                sb.setSpan(new ForegroundColorSpan(accent), start, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                sb.setSpan(new UnderlineSpan(), start, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            }

            lastEnd = m.end();
        }

        // Append remaining text
        if (lastEnd < text.length()) {
            sb.append(text.substring(lastEnd));
        }
    }
}
