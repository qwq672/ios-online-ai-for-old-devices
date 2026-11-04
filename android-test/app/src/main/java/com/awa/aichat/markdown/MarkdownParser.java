package com.awa.aichat.markdown;

import android.graphics.Color;
import android.text.SpannableStringBuilder;
import android.text.Spanned;
import android.text.style.BackgroundColorSpan;
import android.text.style.RelativeSizeSpan;
import android.text.style.StyleSpan;
import android.text.style.TypefaceSpan;
import android.text.style.URLSpan;
import android.text.style.UnderlineSpan;

import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Basic Markdown → Spannable renderer for Android 2.3+.
 * Supports: bold (**), italic (*), code (`), code blocks (```), 
 * links [text](url), headers (#), lists (-, *).
 * 
 * This is intentionally simple — not a full markdown engine.
 */
public class MarkdownParser {

    public static SpannableStringBuilder parse(String text) {
        if (text == null || text.length() == 0) {
            return new SpannableStringBuilder();
        }

        SpannableStringBuilder sb = new SpannableStringBuilder();
        String[] lines = text.split("\n");
        boolean inCodeBlock = false;
        StringBuilder codeBlockBuf = new StringBuilder();

        for (int i = 0; i < lines.length; i++) {
            String line = lines[i];

            // Code fence toggle
            if (line.trim().startsWith("```")) {
                if (inCodeBlock) {
                    // Close — flush code block
                    if (codeBlockBuf.length() > 0) {
                        int start = sb.length();
                        sb.append(codeBlockBuf.toString());
                        int end = sb.length();
                        sb.setSpan(new TypefaceSpan("monospace"), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                        sb.setSpan(new BackgroundColorSpan(0xFF1A1A1A), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
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
                sb.setSpan(new StyleSpan(android.graphics.Typeface.BOLD), start, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                sb.setSpan(new RelativeSizeSpan(1.2f), start, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                sb.append("\n");
                continue;
            }
            if (line.startsWith("## ")) {
                int start = sb.length();
                sb.append(line.substring(3));
                sb.setSpan(new StyleSpan(android.graphics.Typeface.BOLD), start, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                sb.setSpan(new RelativeSizeSpan(1.35f), start, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                sb.append("\n");
                continue;
            }
            if (line.startsWith("# ")) {
                int start = sb.length();
                sb.append(line.substring(2));
                sb.setSpan(new StyleSpan(android.graphics.Typeface.BOLD), start, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                sb.setSpan(new RelativeSizeSpan(1.5f), start, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                sb.append("\n");
                continue;
            }

            // List items
            if (line.startsWith("- ") || line.startsWith("* ") || line.startsWith("+ ")) {
                int start = sb.length();
                sb.append("•  ");
                appendInline(sb, line.substring(2));
                sb.append("\n");
                continue;
            }

            // Blockquote
            if (line.startsWith(">")) {
                String body = line.substring(1).trim();
                int start = sb.length();
                sb.append("▎ ").append(body);
                sb.setSpan(new StyleSpan(android.graphics.Typeface.ITALIC), start, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                sb.append("\n");
                continue;
            }

            // Horizontal rule
            if (line.equals("---") || line.equals("***") || line.equals("___")) {
                sb.append("────────────────\n");
                continue;
            }

            // Normal line — parse inline markup
            appendInline(sb, line);
            sb.append("\n");
        }

        // Flush unclosed code block
        if (inCodeBlock && codeBlockBuf.length() > 0) {
            int start = sb.length();
            sb.append(codeBlockBuf.toString());
            sb.setSpan(new TypefaceSpan("monospace"), start, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            sb.setSpan(new BackgroundColorSpan(0xFF1A1A1A), start, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        }

        return sb;
    }

    /**
     * Parse inline markdown: **bold**, *italic*, `code`, [text](url).
     */
    private static void appendInline(SpannableStringBuilder sb, String text) {
        // Simple regex-based approach
        // Order: code > bold > italic > link
        
        Pattern p = Pattern.compile("(\\*\\*(.+?)\\*\\*)|(\\*(.+?)\\*)|(`(.+?)`)|(\\[(.+?)\\]\\((.+?)\\))");
        Matcher m = p.matcher(text);
        int lastEnd = 0;

        while (m.find()) {
            // Append text before match
            if (m.start() > lastEnd) {
                sb.append(text.substring(lastEnd, m.start()));
            }

            String full = m.group(0);
            String bold = m.group(2);
            String italic = m.group(4);
            String code = m.group(6);
            String linkText = m.group(8);
            String linkUrl = m.group(9);

            if (bold != null) {
                int start = sb.length();
                sb.append(bold);
                sb.setSpan(new StyleSpan(android.graphics.Typeface.BOLD), start, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            } else if (italic != null) {
                int start = sb.length();
                sb.append(italic);
                sb.setSpan(new StyleSpan(android.graphics.Typeface.ITALIC), start, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            } else if (code != null) {
                int start = sb.length();
                sb.append(code);
                sb.setSpan(new TypefaceSpan("monospace"), start, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                sb.setSpan(new BackgroundColorSpan(0xFF2A2A2A), start, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            } else if (linkText != null) {
                int start = sb.length();
                sb.append(linkText);
                sb.setSpan(new URLSpan(linkUrl), start, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
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
