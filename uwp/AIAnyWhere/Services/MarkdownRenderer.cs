using System;
using System.Collections.Generic;
using System.Text;
using System.Text.RegularExpressions;
using Windows.UI;
using Windows.UI.Text;
using Windows.UI.Xaml;
using Windows.UI.Xaml.Controls;
using Windows.UI.Xaml.Documents;
using Windows.UI.Xaml.Media;

namespace AIAnyWhere.Services
{
    /// <summary>
    /// Markdown → XAML RichTextBlock 渲染器。
    /// 支持: 标题、粗体、斜体、行内代码、代码块、引用、列表、链接、表格、分割线、:::tool/:::thinking 块。
    /// 兼容 Windows 10 14393+。
    /// </summary>
    public static class MarkdownRenderer
    {
        // 主题颜色（亮/暗）
        public static Color LightAccent = Color.FromArgb(255, 59, 130, 246);
        public static Color DarkAccent = Color.FromArgb(255, 91, 155, 255);
        public static Color LightCodeBg = Color.FromArgb(255, 244, 244, 248);
        public static Color DarkCodeBg = Color.FromArgb(255, 42, 42, 53);
        public static Color LightQuote = Color.FromArgb(255, 102, 102, 102);
        public static Color DarkQuote = Color.FromArgb(255, 144, 144, 160);
        public static Color LightTool = Color.FromArgb(255, 153, 153, 153);
        public static Color DarkTool = Color.FromArgb(255, 140, 140, 140);

        /// <summary>
        /// 把 Markdown 字符串渲染成 RichTextBlock。
        /// </summary>
        public static RichTextBlock Render(string text, bool dark)
        {
            var rtl = new RichTextBlock();
            rtl.TextWrapping = TextWrapping.Wrap;
            rtl.FontSize = 15;
            rtl.FontFamily = new FontFamily("Segoe UI");
            rtl.LineHeight = 22;
            rtl.Padding = new Thickness(0);

            if (string.IsNullOrEmpty(text)) return rtl;

            var paragraphs = ParseBlocks(text, dark);
            foreach (var p in paragraphs) rtl.Blocks.Add(p);

            return rtl;
        }

        private static List<Paragraph> ParseBlocks(string text, bool dark)
        {
            var result = new List<Paragraph>();
            var lines = text.Replace("\r\n", "\n").Split('\n');

            Color accent = dark ? DarkAccent : LightAccent;
            Color codeBg = dark ? DarkCodeBg : LightCodeBg;
            Color quoteColor = dark ? DarkQuote : LightQuote;
            Color toolColor = dark ? DarkTool : LightTool;
            Color codeFg = Color.FromArgb(255, 232, 232, 232);

            int i = 0;
            bool inToolBlock = false;
            StringBuilder toolBuf = new StringBuilder();

            while (i < lines.Length)
            {
                string line = lines[i];
                string trimmed = line.Trim();

                // :::tool fence
                if (trimmed == ":::tool")
                {
                    if (inToolBlock)
                    {
                        // close — flush
                        if (toolBuf.Length > 0)
                        {
                            string toolText = toolBuf.ToString().Trim();
                            var p = MakeParagraph();
                            var run = new Run { Text = "· " + toolText.Replace("\n", " · ") };
                            run.Foreground = new SolidColorBrush(toolColor);
                            run.FontStyle = FontStyle.Italic;
                            run.FontSize = 13;
                            p.Inlines.Add(run);
                            result.Add(p);
                        }
                        toolBuf.Clear();
                        inToolBlock = false;
                    }
                    else
                    {
                        inToolBlock = true;
                        toolBuf.Clear();
                    }
                    i++;
                    continue;
                }

                if (inToolBlock)
                {
                    toolBuf.Append(line).Append("\n");
                    i++;
                    continue;
                }

                // :::thinking fence — 折叠（UWP 无 Expander，简化为灰色斜体段）
                if (trimmed == ":::thinking")
                {
                    // 收集到 :::: 结束
                    var thinkBuf = new StringBuilder();
                    i++;
                    while (i < lines.Length && lines[i].Trim() != ":::")
                    {
                        thinkBuf.Append(lines[i]).Append("\n");
                        i++;
                    }
                    if (i < lines.Length) i++; // skip :::

                    if (thinkBuf.Length > 0)
                    {
                        var p = MakeParagraph();
                        var run = new Run { Text = "思考: " + thinkBuf.ToString().Trim() };
                        run.Foreground = new SolidColorBrush(quoteColor);
                        run.FontStyle = FontStyle.Italic;
                        run.FontSize = 13;
                        p.Inlines.Add(run);
                        result.Add(p);
                    }
                    continue;
                }

                // Code fence
                if (trimmed.StartsWith("```"))
                {
                    var codeBuf = new StringBuilder();
                    string lang = trimmed.Substring(3).Trim();
                    i++;
                    while (i < lines.Length && !lines[i].Trim().StartsWith("```"))
                    {
                        codeBuf.Append(lines[i]).Append("\n");
                        i++;
                    }
                    if (i < lines.Length) i++; // skip closing ```

                    string codeText = codeBuf.ToString();
                    if (codeText.EndsWith("\n")) codeText = codeText.Substring(0, codeText.Length - 1);

                    var p = MakeParagraph();
                    p.Background = new SolidColorBrush(Color.FromArgb(255, 0, 0, 0));
                    p.BorderBrush = new SolidColorBrush(codeBg);
                    p.BorderThickness = new Thickness(0, 0, 0, 0);
                    p.Padding = new Thickness(8, 6, 8, 6);
                    p.Margin = new Thickness(0, 4, 0, 4);
                    var codeRun = new Run { Text = codeText, FontFamily = new FontFamily("Consolas") };
                    codeRun.Foreground = new SolidColorBrush(codeFg);
                    codeRun.FontSize = 13;
                    p.Inlines.Add(codeRun);
                    result.Add(p);
                    continue;
                }

                // Headers
                if (line.StartsWith("### "))
                {
                    var p = MakeParagraph();
                    AddInline(p, line.Substring(4), accent);
                    p.FontSize = 18;
                    p.FontWeight = FontWeights.Bold;
                    p.Foreground = new SolidColorBrush(accent);
                    p.Margin = new Thickness(0, 8, 0, 4);
                    result.Add(p);
                    i++;
                    continue;
                }
                if (line.StartsWith("## "))
                {
                    var p = MakeParagraph();
                    AddInline(p, line.Substring(3), accent);
                    p.FontSize = 20;
                    p.FontWeight = FontWeights.Bold;
                    p.Foreground = new SolidColorBrush(accent);
                    p.Margin = new Thickness(0, 10, 0, 4);
                    result.Add(p);
                    i++;
                    continue;
                }
                if (line.StartsWith("# "))
                {
                    var p = MakeParagraph();
                    AddInline(p, line.Substring(2), accent);
                    p.FontSize = 24;
                    p.FontWeight = FontWeights.Bold;
                    p.Foreground = new SolidColorBrush(accent);
                    p.Margin = new Thickness(0, 12, 0, 4);
                    result.Add(p);
                    i++;
                    continue;
                }

                // Horizontal rule
                if (trimmed == "---" || trimmed == "***" || trimmed == "___")
                {
                    var p = MakeParagraph();
                    var run = new Run { Text = "────────────────────────────" };
                    run.Foreground = new SolidColorBrush(quoteColor);
                    p.Inlines.Add(run);
                    p.Margin = new Thickness(0, 4, 0, 4);
                    result.Add(p);
                    i++;
                    continue;
                }

                // Blockquote
                if (line.StartsWith(">"))
                {
                    string body = line.Substring(1).Trim();
                    var p = MakeParagraph();
                    var bar = new Run { Text = "▎ " };
                    bar.Foreground = new SolidColorBrush(accent);
                    p.Inlines.Add(bar);
                    AddInline(p, body, accent);
                    p.Foreground = new SolidColorBrush(quoteColor);
                    p.FontStyle = FontStyle.Italic;
                    p.Margin = new Thickness(0, 4, 0, 4);
                    result.Add(p);
                    i++;
                    continue;
                }

                // List items
                if (line.StartsWith("- ") || line.StartsWith("* ") || line.StartsWith("+ "))
                {
                    var p = MakeParagraph();
                    var bullet = new Run { Text = "•  " };
                    bullet.Foreground = new SolidColorBrush(accent);
                    p.Inlines.Add(bullet);
                    AddInline(p, line.Substring(2), accent);
                    p.Margin = new Thickness(12, 0, 0, 0);
                    result.Add(p);
                    i++;
                    continue;
                }

                var numMatch = Regex.Match(line, @"^(\d+)\.\s");
                if (numMatch.Success)
                {
                    var p = MakeParagraph();
                    var num = new Run { Text = numMatch.Value };
                    num.Foreground = new SolidColorBrush(accent);
                    num.FontWeight = FontWeights.Bold;
                    p.Inlines.Add(num);
                    AddInline(p, line.Substring(numMatch.Length), accent);
                    p.Margin = new Thickness(12, 0, 0, 0);
                    result.Add(p);
                    i++;
                    continue;
                }

                // Table row
                if (trimmed.StartsWith("|") && trimmed.EndsWith("|"))
                {
                    // 收集连续表格行
                    var tableLines = new List<string>();
                    while (i < lines.Length && lines[i].Trim().StartsWith("|") && lines[i].Trim().EndsWith("|"))
                    {
                        tableLines.Add(lines[i].Trim());
                        i++;
                    }
                    // 渲染表格
                    foreach (var tl in tableLines)
                    {
                        if (Regex.IsMatch(tl, @"^[|:\-\s]+$")) continue; // 分隔行
                        string body = tl;
                        if (body.StartsWith("|")) body = body.Substring(1);
                        if (body.EndsWith("|")) body = body.Substring(0, body.Length - 1);
                        string[] cells = body.Split('|');
                        var p = MakeParagraph();
                        for (int c = 0; c < cells.Length; c++)
                        {
                            if (c > 0)
                            {
                                var sep = new Run { Text = "  │  " };
                                sep.Foreground = new SolidColorBrush(quoteColor);
                                p.Inlines.Add(sep);
                            }
                            AddInline(p, cells[c].Trim(), accent);
                        }
                        p.Margin = new Thickness(0, 1, 0, 1);
                        result.Add(p);
                    }
                    continue;
                }

                // 空行
                if (trimmed.Length == 0)
                {
                    i++;
                    continue;
                }

                // 普通行
                var para = MakeParagraph();
                AddInline(para, line, accent);
                para.Margin = new Thickness(0, 2, 0, 2);
                result.Add(para);
                i++;
            }

            // 末尾 flush tool block
            if (inToolBlock && toolBuf.Length > 0)
            {
                string toolText = toolBuf.ToString().Trim();
                var p = MakeParagraph();
                var run = new Run { Text = "· " + toolText.Replace("\n", " · ") };
                run.Foreground = new SolidColorBrush(toolColor);
                run.FontStyle = FontStyle.Italic;
                run.FontSize = 13;
                p.Inlines.Add(run);
                result.Add(p);
            }

            return result;
        }

        private static Paragraph MakeParagraph()
        {
            return new Paragraph { LineStackingStrategy = LineStackingStrategy.BaselineToBaseline };
        }

        /// <summary>
        /// 解析行内 Markdown: **bold**, *italic*, `code`, [text](url), ![alt](url)
        /// </summary>
        private static void AddInline(Paragraph p, string text, Color accent)
        {
            var regex = new Regex(@"(\*\*(.+?)\*\*)|(\*(.+?)\*)|(`(.+?)`)|(!\[(.+?)\]\((.+?)\))|(\[(.+?)\]\((.+?)\))");
            int lastEnd = 0;
            foreach (Match m in regex.Matches(text))
            {
                if (m.Index > lastEnd)
                {
                    p.Inlines.Add(new Run { Text = text.Substring(lastEnd, m.Index - lastEnd) });
                }
                string bold = m.Groups[2].Value;
                string italic = m.Groups[4].Value;
                string code = m.Groups[6].Value;
                string imgAlt = m.Groups[8].Value;
                string imgUrl = m.Groups[9].Value;
                string linkText = m.Groups[11].Value;
                string linkUrl = m.Groups[12].Value;

                if (!string.IsNullOrEmpty(bold))
                {
                    var r = new Run { Text = bold, FontWeight = FontWeights.Bold };
                    p.Inlines.Add(r);
                }
                else if (!string.IsNullOrEmpty(italic))
                {
                    var r = new Run { Text = italic, FontStyle = FontStyle.Italic };
                    p.Inlines.Add(r);
                }
                else if (!string.IsNullOrEmpty(code))
                {
                    var r = new Run { Text = code, FontFamily = new FontFamily("Consolas") };
                    r.Foreground = new SolidColorBrush(accent);
                    r.Background = new SolidColorBrush(Color.FromArgb(255, 244, 244, 248));
                    p.Inlines.Add(r);
                }
                else if (!string.IsNullOrEmpty(imgUrl))
                {
                    if (imgUrl.StartsWith("data:image"))
                    {
                        var r = new Run { Text = "[图片]" };
                        r.Foreground = new SolidColorBrush(accent);
                        r.FontStyle = FontStyle.Italic;
                        p.Inlines.Add(r);
                    }
                    else
                    {
                        // UWP Hyperlink 简化为带下划线文字
                        string display = !string.IsNullOrEmpty(imgAlt) ? imgAlt : "图片";
                        var link = new Hyperlink();
                        link.NavigateUri = new Uri(imgUrl);
                        link.Inlines.Add(new Run { Text = display });
                        link.Foreground = new SolidColorBrush(accent);
                        p.Inlines.Add(link);
                    }
                }
                else if (!string.IsNullOrEmpty(linkText))
                {
                    var link = new Hyperlink();
                    try { link.NavigateUri = new Uri(linkUrl); } catch { }
                    link.Inlines.Add(new Run { Text = linkText });
                    link.Foreground = new SolidColorBrush(accent);
                    p.Inlines.Add(link);
                }
                lastEnd = m.Index + m.Length;
            }
            if (lastEnd < text.Length)
            {
                p.Inlines.Add(new Run { Text = text.Substring(lastEnd) });
            }
        }
    }
}
