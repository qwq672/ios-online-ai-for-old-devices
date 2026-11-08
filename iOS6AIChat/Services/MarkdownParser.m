//
//  MarkdownParser.m
//  iOS6AIChat
//
//  Comprehensive Markdown → NSAttributedString renderer for iOS 6+.
//  Supports:
//
//  Block-level:
//    # / ## / ### / #### / ##### / ######   headings (6 levels)
//    ```...```                              fenced code blocks
//    > ...                                  blockquotes
//    - / * / +                              unordered lists (nested)
//    1. / 2. / ...                           ordered lists
//    | a | b |                              tables
//    |---|---|
//    $$...$$                                 math display blocks
//    --- / *** / ___                         horizontal rules
//    (blank line)                           paragraph break
//
//  Inline:
//    **bold**  __bold__
//    *italic*  _italic_   (but _xxx_ conflicts with underline — we use <u> tag)
//    ***bold italic***
//    `inline code`
//    ~~strikethrough~~
//    <u>underline</u>
//    [label](url)
//    $inline math$
//    \X                                      escape next char
//
//  iOS 6 NSAttributedString attributes used:
//    NSFontAttributeName (bold / italic / mono / heading sizes)
//    NSForegroundColorAttributeName
//    NSBackgroundColorAttributeName (code blocks)
//    NSUnderlineStyleAttributeName
//    NSStrikethroughStyleAttributeName (iOS 6+ — verified in UIKit headers)
//    NSLinkAttributeName (iOS 7+ — falls back to underline + tint on iOS 6)
//

#import "MarkdownParser.h"
#import "iOS6Theme.h"

// Helper macro: append a string with given attributes.
static void AppendAttrString(NSMutableAttributedString *out,
                              NSString *text,
                              UIFont *font,
                              UIColor *fg,
                              UIColor *bg,
                              NSInteger underline,
                              NSInteger strikethrough)
{
    if (!text || text.length == 0) return;
    NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
    if (font) [attrs setObject:font forKey:NSFontAttributeName];
    if (fg) [attrs setObject:fg forKey:NSForegroundColorAttributeName];
    if (bg) [attrs setObject:bg forKey:NSBackgroundColorAttributeName];
    if (underline > 0) [attrs setObject:@(underline) forKey:NSUnderlineStyleAttributeName];
    if (strikethrough > 0) {
        // NSStrikethroughStyleAttributeName is iOS 7+ — NOT declared in the
        // iOS 6 SDK headers. Instead, we prepend U+0336 (combining long
        // stroke overlay) before each character. This produces a visible
        // strikethrough that works on iOS 6 as well as iOS 7+.
        NSMutableString *st = [NSMutableString string];
        for (NSUInteger k = 0; k < text.length; k++) {
            unichar ch = [text characterAtIndex:k];
            // Skip combining chars / whitespace (don't strike through them).
            if (ch == ' ' || ch == '\t' || ch == '\n') {
                [st appendFormat:@"%C", ch];
            } else {
                [st appendFormat:@"%@%C", [NSString stringWithCharacters:(const unichar[]){0x0336} length:1], ch];
            }
        }
        text = st;
    }
    [out appendAttributedString:[[[NSAttributedString alloc]
                                    initWithString:text attributes:attrs] autorelease]];
}

@implementation MarkdownParser

+ (NSAttributedString *)attributedStringFromMarkdown:(NSString *)markdown
                                          baseFont:(UIFont *)baseFont
                                             width:(CGFloat)width
{
    // Backwards-compat entry point — calls the fast-path variant with
    // fast=NO (full features). Existing callers (height calc, test code)
    // keep the slow path; only the streaming render path passes fast=YES.
    return [self attributedStringFromMarkdown:markdown
                                      baseFont:baseFont
                                         width:width
                                         fast:NO];
}

+ (NSAttributedString *)attributedStringFromMarkdown:(NSString *)markdown
                                          baseFont:(UIFont *)baseFont
                                             width:(CGFloat)width
                                             fast:(BOOL)fast
{
    if (!markdown || markdown.length == 0) {
        return [[[NSAttributedString alloc] initWithString:@""] autorelease];
    }
    // v261025-30: strip all invisible/format Unicode characters that iOS 6
    // renders as □ (tofu). These are modern Unicode modifiers that AI models
    // emit alongside emoji and special symbols. Using NSCharacterSet with
    // explicit unichar values (not \u escapes) for compiler reliability.
    const unichar tofuChars[] = {
        0x00AD,  // SOFT HYPHEN
        0x200B,  // ZERO WIDTH SPACE
        0x200C,  // ZERO WIDTH NON-JOINER
        0x200D,  // ZERO WIDTH JOINER (compound emoji)
        0x2060,  // WORD JOINER
        0xFE0E,  // VARIATION SELECTOR-15 (text presentation)
        0xFE0F,  // VARIATION SELECTOR-16 (emoji presentation) — MOST COMMON
        0xFEFF,  // BOM / ZERO WIDTH NO-BREAK SPACE
    };
    NSString *tofuStr = [NSString stringWithCharacters:tofuChars
                                                length:sizeof(tofuChars)/sizeof(tofuChars[0])];
    NSCharacterSet *tofuSet = [NSCharacterSet characterSetWithCharactersInString:tofuStr];
    markdown = [[markdown componentsSeparatedByCharactersInSet:tofuSet]
                 componentsJoinedByString:@""];
    // v261025-30: surrogate pair handling in the default case (below)
    // prevents the main crash cause. Defensive coding: nil-guards, range
    // bounds checks, and surrogate pair detection.
    NSMutableAttributedString *out = [NSMutableAttributedString new];
    NSMutableArray *lines = [[markdown componentsSeparatedByString:@"\n"] mutableCopy];

    // Pass 1: detect + render block-level structures.
    NSUInteger i = 0;
    BOOL inFence = NO;
    BOOL inMathBlock = NO;
    BOOL inToolBlock = NO;  // v261102-1: :::tool ... ::: gray status box
    NSMutableArray *fencedLines = [NSMutableArray array];
    NSMutableArray *mathLines = [NSMutableArray array];
    NSMutableArray *toolLines = [NSMutableArray array];
    BOOL prevWasBlank = NO;
    BOOL inParagraph = NO;
    NSMutableArray *tableBuffer = [NSMutableArray array];
    BOOL inTable = NO;

    while (i < [lines count]) {
        NSString *rawLine = [lines objectAtIndex:i];
        NSString *line = [rawLine stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];

        // === Tool status fence (:::tool ... :::) =========================
        // v261102-1: gray status box for tool-call process / done markers.
        // v261103-8: also handle :::thinking blocks (segmented reasoning).
        if ([line isEqualToString:@":::tool"] || [line isEqualToString:@":::thinking"]) {
            NSString *blockType = line;  // remember which type
            if (!inToolBlock) {
                inToolBlock = YES;
                [toolLines removeAllObjects];
                // Store the block type for rendering
                [toolLines addObject:blockType];
            } else {
                // Close current block, start new one (shouldn't happen)
                [self _appendToolStatus:toolLines to:out baseFont:baseFont];
                inToolBlock = NO;
                [toolLines removeAllObjects];
                [toolLines addObject:blockType];
                inToolBlock = YES;
            }
            i++;
            continue;
        }
        if (inToolBlock && [line isEqualToString:@":::"]) {
            [self _appendToolStatus:toolLines to:out baseFont:baseFont];
            inToolBlock = NO;
            [toolLines removeAllObjects];
            i++;
            continue;
        }
        if (inToolBlock) {
            [toolLines addObject:line];
            i++;
            continue;
        }

        // === Code fence toggle ============================================
        if ([line hasPrefix:@"```"]) {
            if (!inFence) {
                inFence = YES;
                [fencedLines removeAllObjects];
            } else {
                // v261103-7: before rendering as code block, check if the
                // fenced content is actually a TABLE (AI sometimes wraps
                // tables in ``` fences). If we detect a table separator row
                // (|---|---|), render as table instead of code block.
                BOOL isTable = NO;
                for (NSString *fl in fencedLines) {
                    // A table separator row looks like |---|---| or | --- | --- |
                    if ([fl hasPrefix:@"|"] && [fl hasSuffix:@"|"] &&
                        [fl rangeOfString:@"---"].location != NSNotFound) {
                        isTable = YES;
                        break;
                    }
                }
                if (isTable) {
                    [self _appendTable:fencedLines to:out baseFont:baseFont];
                } else {
                    [self _appendFencedCode:fencedLines to:out baseFont:baseFont];
                }
                inFence = NO;
                [fencedLines removeAllObjects];
                [out appendAttributedString:[[[NSAttributedString alloc]
                                                initWithString:@"\n"] autorelease]];
            }
            i++;
            continue;
        }
        if (inFence) {
            [fencedLines addObject:rawLine];
            i++;
            continue;
        }

        // === Math block toggle ($$...$$) =================================
        // v261103-1: skip math block parsing in fast mode (rare + complex).
        // Math blocks are flushed at end-of-input if `inMathBlock` is true,
        // so a streaming chunk that opens $$ but doesn't close it just
        // renders as plain text — the final full-path render handles it.
        if (!fast && [line hasPrefix:@"$$"]) {
            if (!inMathBlock) {
                inMathBlock = YES;
                [mathLines removeAllObjects];
                // If the line has content after $$, it's the start of math.
                NSString *rest = [line substringFromIndex:2];
                rest = [rest stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceCharacterSet]];
                if (rest.length > 0 && ![rest hasSuffix:@"$$"]) {
                    [mathLines addObject:rest];
                } else if ([rest hasSuffix:@"$$"]) {
                    // Single-line $$...$$.
                    NSString *inside = [rest substringToIndex:rest.length - 2];
                    [mathLines addObject:inside];
                    [self _appendMathBlock:mathLines to:out baseFont:baseFont];
                    inMathBlock = NO;
                    [mathLines removeAllObjects];
                }
            } else {
                [self _appendMathBlock:mathLines to:out baseFont:baseFont];
                inMathBlock = NO;
                [mathLines removeAllObjects];
            }
            i++;
            continue;
        }
        if (inMathBlock) {
            [mathLines addObject:line];
            i++;
            continue;
        }

        // === Table detection =============================================
        // A table row starts with | and ends with |.
        // v261103-11: enable table parsing in fast mode too (user reports
        // tables not rendering during streaming). Tables are common enough
        // that skipping them causes visible "raw markdown" during streaming.
        // The table parser is O(n) where n = number of columns, so it's fast.
        if ([line hasPrefix:@"|"] && [line hasSuffix:@"|"]) {
            if (!inTable) {
                inTable = YES;
                [tableBuffer removeAllObjects];
            }
            [tableBuffer addObject:line];
            i++;
            continue;
        } else if (inTable) {
            // End of table — flush.
            [self _appendTable:tableBuffer to:out baseFont:baseFont];
            inTable = NO;
            [tableBuffer removeAllObjects];
            // Don't advance i — let the current line be processed.
            continue;
        }

        // === Blank line ==================================================
        if (line.length == 0) {
            if (inParagraph) {
                [out appendAttributedString:[[[NSAttributedString alloc]
                                                initWithString:@"\n"] autorelease]];
                inParagraph = NO;
            }
            prevWasBlank = YES;
            i++;
            continue;
        }

        // === Headings (1-6 #) =============================================
        NSInteger headingLevel = 0;
        for (NSInteger lvl = 6; lvl >= 1; lvl--) {
            NSString *prefix = [@"" stringByPaddingToLength:lvl withString:@"#" startingAtIndex:0];
            prefix = [prefix stringByAppendingString:@" "];
            if ([line hasPrefix:prefix]) {
                headingLevel = lvl;
                break;
            }
            // Also accept `#` without trailing space.
            NSString *barePrefix = [@"" stringByPaddingToLength:lvl withString:@"#" startingAtIndex:0];
            if ([line hasPrefix:barePrefix] && ![line hasPrefix:[barePrefix stringByAppendingString:@"#"]]) {
                headingLevel = lvl;
                break;
            }
        }
        if (headingLevel > 0) {
            NSString *prefix = [@"" stringByPaddingToLength:headingLevel withString:@"#" startingAtIndex:0];
            NSString *title = line;
            if ([title hasPrefix:[prefix stringByAppendingString:@" "]]) {
                title = [title substringFromIndex:headingLevel + 1];
            } else {
                title = [title substringFromIndex:headingLevel];
            }
            [self _appendHeading:title level:headingLevel to:out baseFont:baseFont];
            i++;
            continue;
        }

        // === Horizontal rule =============================================
        if ([line isEqualToString:@"---"]
            || [line isEqualToString:@"***"]
            || [line isEqualToString:@"___"]
            || [line hasPrefix:@"---"]
            || [line hasPrefix:@"***"]
            || [line hasPrefix:@"___"]) {
            // Verify the line is composed only of the same char.
            unichar firstChar = [line characterAtIndex:0];
            BOOL allSame = YES;
            for (NSUInteger c = 0; c < line.length; c++) {
                if ([line characterAtIndex:c] != firstChar) { allSame = NO; break; }
            }
            if (allSame && line.length >= 3) {
                [self _appendHorizontalRuleTo:out baseFont:baseFont];
                i++;
                continue;
            }
        }

        // === Blockquote ==================================================
        // v261103-7: proper blockquote UI — colored left bar + gray text
        // + indentation. Replaces the old `| ` prefix approach which the
        // user said "不要干啥都用代码块代替" — this is now visually distinct
        // from code blocks.
        if ([line hasPrefix:@">"]) {
            NSString *body = [line substringFromIndex:1];
            if (body.length > 0 && [body characterAtIndex:0] == ' ') {
                body = [body substringFromIndex:1];
            }
            // Render: ▎ (colored bar) + body in secondary color.
            UIColor *barColor = [iOS6Theme tintColor];
            UIColor *quoteColor = [iOS6Theme secondaryTextColor];
            AppendAttrString(out, @"▎ ", baseFont, barColor, nil, 0, 0);
            AppendAttrString(out, body, baseFont, quoteColor, nil, 0, 0);
            AppendAttrString(out, @"\n", baseFont, quoteColor, nil, 0, 0);
            i++;
            continue;
        }

        // === Unordered list item =========================================
        // v261103-1: 列表渲染 bug 修复 — 之前用 `line` (已 trim) 检查 prefix,
        // 导致 `  - item` 这种带缩进的列表项被 trim 成 `- item` 后才匹配,
        // 看似没问题, 但实际连带导致后续 `inParagraph` 状态错乱 + 缩进嵌套
        // 列表无法识别。现在用 rawLine 检测, 同时支持多种 bullet 字符。
        // 支持的 bullet:
        //   - * +  → 标准 markdown
        //   • ◦ ○ ● ◇ ◆ → AI 常用的 unicode bullet (DeepSeek/GLM 经常用)
        BOOL isUnorderedListItem = NO;
        NSString *unorderedBody = nil;
        NSString *unorderedPrefix = nil;
        // 标准 markdown bullet (允许 0-3 个前导空格, 不能是 4+ 否则变成 code block)
        NSArray *unorderedBullets = @[@"- ", @"* ", @"+ "];
        for (NSString *b in unorderedBullets) {
            if ([rawLine hasPrefix:b]) {
                // 排除 4+ 空格缩进 (那是 indented code block, 不是 list)
                NSRange leadingWS = [rawLine rangeOfString:@"^ {0,3}"
                    options:NSRegularExpressionSearch];
                (void)leadingWS;
                if ([rawLine length] >= 4 && [[rawLine substringToIndex:4]
                    isEqualToString:@"    "]) {
                    // 4-space indent → not a list (let it fall through)
                } else {
                    isUnorderedListItem = YES;
                    NSUInteger prefixLen = 0;
                    while (prefixLen < [rawLine length] && [rawLine characterAtIndex:prefixLen] == ' ') prefixLen++;
                    unorderedBody = [rawLine substringFromIndex:prefixLen + 2];
                    NSString *indent = [rawLine substringToIndex:prefixLen];
                    unorderedPrefix = [NSString stringWithFormat:@"%@•  ", indent];
                }
                break;
            }
        }
        // Unicode bullet (• ◦ ○ ● ◇ ◆ 等) — 整行 trim 后以这些字符开头
        if (!isUnorderedListItem) {
            unichar firstChar = (line.length > 0) ? [line characterAtIndex:0] : 0;
            if (firstChar == 0x2022 /* • */ || firstChar == 0x25CB /* ○ */ ||
                firstChar == 0x25CF /* ● */ || firstChar == 0x25C6 /* ◆ */ ||
                firstChar == 0x25C7 /* ◇ */ || firstChar == 0x25E6 /* ◦ */ ||
                firstChar == 0x2023 /* ‣ */) {
                // 后面跟空格或直接是文字
                if (line.length > 1) {
                    unichar nextC = [line characterAtIndex:1];
                    if (nextC == ' ' || nextC == '\t') {
                        isUnorderedListItem = YES;
                        unorderedBody = [line substringFromIndex:2];
                        // strip trailing whitespace
                        unorderedBody = [unorderedBody stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceCharacterSet]];
                        unorderedPrefix = @"•  ";
                    } else {
                        // 紧贴文字也接受 (•item)
                        isUnorderedListItem = YES;
                        unorderedBody = [line substringFromIndex:1];
                        unorderedPrefix = @"•  ";
                    }
                }
            }
        }
        if (isUnorderedListItem) {
            // 段落 → 列表转换时插入空行, 让前面段落的换行符生效。
            if (inParagraph) {
                [out appendAttributedString:[[[NSAttributedString alloc]
                                                initWithString:@"\n"] autorelease]];
                inParagraph = NO;
            }
            [self _appendInlineMarkup:unorderedBody
                                   to:out
                             baseFont:baseFont
                              prefix:unorderedPrefix];
            // v261025-13: list items need explicit trailing newline.
            [out appendAttributedString:[[[NSAttributedString alloc]
                                            initWithString:@"\n"] autorelease]];
            i++;
            continue;
        }

        // === Ordered list item (1. / 2. / 1、 / 1) / 1） etc) ============
        // v261103-1: 扩展 ordered list 支持, 兼容 AI 输出的多种枚举格式:
        //   1. xxx   → 标准 markdown (digit + period + space)
        //   1、 xxx  → 中文风格 (digit + ideographic comma)
        //   1) xxx   → 西文括号
        //   1） xxx  → 中文全角括号
        //   ① ② ③ → 圆圈数字 (单字符前缀, 后跟空格或紧贴)
        BOOL isOrderedListItem = NO;
        NSString *orderedBody = nil;
        NSString *orderedPrefix = nil;
        NSRegularExpression *orderedRegex = [NSRegularExpression
            regularExpressionWithPattern:@"^(\\d+)\\.(\\s|、)"
                                  options:0 error:NULL];
        NSTextCheckingResult *ordMatch = [orderedRegex firstMatchInString:line
                                                                    options:0
                                                                      range:NSMakeRange(0, line.length)];
        if (ordMatch) {
            NSString *numStr = [line substringWithRange:[ordMatch rangeAtIndex:1]];
            NSUInteger bodyStart = ordMatch.range.location + ordMatch.range.length;
            orderedBody = [line substringFromIndex:bodyStart];
            orderedPrefix = [NSString stringWithFormat:@"%@.  ", numStr];
            isOrderedListItem = YES;
        }
        if (!isOrderedListItem) {
            // 1) / 1） style
            NSRegularExpression *parenRegex = [NSRegularExpression
                regularExpressionWithPattern:@"^(\\d+)[)）](\\s*)"
                                      options:0 error:NULL];
            NSTextCheckingResult *parenMatch = [parenRegex firstMatchInString:line
                                                                        options:0
                                                                          range:NSMakeRange(0, line.length)];
            if (parenMatch) {
                NSString *numStr = [line substringWithRange:[parenMatch rangeAtIndex:1]];
                NSUInteger bodyStart = parenMatch.range.location + parenMatch.range.length;
                orderedBody = [line substringFromIndex:bodyStart];
                orderedPrefix = [NSString stringWithFormat:@"%@)  ", numStr];
                isOrderedListItem = YES;
            }
        }
        if (!isOrderedListItem) {
            // ① ② ③ circled digits (U+2460..U+2473 = 1-20)
            unichar firstC = (line.length > 0) ? [line characterAtIndex:0] : 0;
            if (firstC >= 0x2460 && firstC <= 0x2473) {
                int num = (int)(firstC - 0x2460) + 1;
                if (line.length > 1) {
                    unichar nextC = [line characterAtIndex:1];
                    NSUInteger bodyStart = (nextC == ' ' || nextC == '\t') ? 2 : 1;
                    orderedBody = [line substringFromIndex:bodyStart];
                    orderedPrefix = [NSString stringWithFormat:@"%d.  ", num];
                    isOrderedListItem = YES;
                }
            }
        }
        if (isOrderedListItem) {
            if (inParagraph) {
                [out appendAttributedString:[[[NSAttributedString alloc]
                                                initWithString:@"\n"] autorelease]];
                inParagraph = NO;
            }
            [self _appendInlineMarkup:orderedBody
                                   to:out
                             baseFont:baseFont
                              prefix:orderedPrefix];
            [out appendAttributedString:[[[NSAttributedString alloc]
                                            initWithString:@"\n"] autorelease]];
            i++;
            continue;
        }

        // === Default: paragraph line ====================================
        [self _appendInlineMarkup:line
                               to:out
                         baseFont:baseFont
                          prefix:nil];
        [out appendAttributedString:[[[NSAttributedString alloc]
                                        initWithString:@"\n"] autorelease]];
        inParagraph = YES;
        prevWasBlank = NO;
        i++;
    }

    // Flush any open blocks.
    if (inFence) {
        [self _appendFencedCode:fencedLines to:out baseFont:baseFont];
    }
    if (inMathBlock) {
        [self _appendMathBlock:mathLines to:out baseFont:baseFont];
    }
    if (inTable) {
        [self _appendTable:tableBuffer to:out baseFont:baseFont];
    }

    [lines release];
    // v261025-30: apply AppleColorEmoji font to emoji character ranges.
    // iOS 6 doesn't auto-fallback to the emoji font for emoji in
    // NSAttributedString — the base font (Helvetica) has no emoji glyphs
    // → renders as □ (tofu). Explicit font override fixes this.
    // v261103-1: skip the emoji-font pass in fast mode (O(n) per render,
    // unnecessary during streaming). The final full-path render applies it.
    if (!fast) {
        [self _applyEmojiFont:out baseFont:baseFont];
    }
    return [out autorelease];
}

#pragma mark - Inline markup

+ (void)_appendInlineMarkup:(NSString *)line
                         to:(NSMutableAttributedString *)out
                   baseFont:(UIFont *)baseFont
                    prefix:(NSString *)prefix
{
    if (prefix) {
        AppendAttrString(out, prefix, baseFont, [iOS6Theme textColor], nil, 0, 0);
    }
    if (!line || line.length == 0) {
        AppendAttrString(out, @"\n", baseFont, [iOS6Theme textColor], nil, 0, 0);
        return;
    }

    UIFont *bold      = [UIFont boldSystemFontOfSize:baseFont.pointSize];
    UIFont *italic    = [UIFont italicSystemFontOfSize:baseFont.pointSize];
    // For bold-italic, look up the named font directly. HelveticaNeue-BoldItalic
    // is available on iOS 6+. Fall back to bold if unavailable.
    UIFont *boldItalic = [UIFont fontWithName:@"HelveticaNeue-BoldItalic"
                                         size:baseFont.pointSize]
                        ?: bold;
    UIFont *mono      = [UIFont fontWithName:@"Courier" size:baseFont.pointSize - 1] ?: baseFont;
    UIFont *underlineFont = [UIFont systemFontOfSize:baseFont.pointSize];

    NSUInteger i = 0;
    NSUInteger len = line.length;
    NSMutableString *buf = [NSMutableString string];

    while (i < len) {
        unichar c = [line characterAtIndex:i];

        // === Escape sequence =============================================
        if (c == '\\' && i + 1 < len) {
            unichar next = [line characterAtIndex:i + 1];
            [buf appendString:[NSString stringWithCharacters:&next length:1]];
            i += 2;
            continue;
        }

        // === Bold italic ***text*** ======================================
        if (i + 2 < len && c == '*' && [line characterAtIndex:i + 1] == '*'
            && [line characterAtIndex:i + 2] == '*') {
            NSRange search = NSMakeRange(i + 3, len - (i + 3));
            NSRange close = [line rangeOfString:@"***" options:0 range:search];
            if (close.location != NSNotFound) {
                NSString *content = [line substringWithRange:
                                     NSMakeRange(i + 3, close.location - (i + 3))];
                if (buf.length > 0) {
                    AppendAttrString(out, buf, baseFont, [iOS6Theme textColor], nil, 0, 0);
                    [buf setString:@""];
                }
                AppendAttrString(out, content, boldItalic, [iOS6Theme textColor], nil, 0, 0);
                i = close.location + 3;
                continue;
            }
        }

        // === Bold **text** ===============================================
        if (i + 1 < len && c == '*' && [line characterAtIndex:i + 1] == '*') {
            NSRange search = NSMakeRange(i + 2, len - (i + 2));
            NSRange close = [line rangeOfString:@"**" options:0 range:search];
            if (close.location != NSNotFound) {
                NSString *content = [line substringWithRange:
                                     NSMakeRange(i + 2, close.location - (i + 2))];
                if (buf.length > 0) {
                    AppendAttrString(out, buf, baseFont, [iOS6Theme textColor], nil, 0, 0);
                    [buf setString:@""];
                }
                AppendAttrString(out, content, bold, [iOS6Theme textColor], nil, 0, 0);
                i = close.location + 2;
                continue;
            }
        }

        // === Highlight ==text== =========================================
        if (i + 1 < len && c == '=' && [line characterAtIndex:i + 1] == '=') {
            NSRange search = NSMakeRange(i + 2, len - (i + 2));
            NSRange close = [line rangeOfString:@"==" options:0 range:search];
            if (close.location != NSNotFound && close.location > i + 2) {
                NSString *content = [line substringWithRange:
                                     NSMakeRange(i + 2, close.location - (i + 2))];
                if (buf.length > 0) {
                    AppendAttrString(out, buf, baseFont, [iOS6Theme textColor], nil, 0, 0);
                    [buf setString:@""];
                }
                AppendAttrString(out, content, baseFont, [iOS6Theme textColor],
                                 [UIColor colorWithRed:1.0f green:0.92f blue:0.55f alpha:0.45f],
                                 0, 0);
                i = close.location + 2;
                continue;
            }
        }

        // === Bold __text__ (underscore bold) =============================
        // v261103-5: was missing — only ** was parsed, not __.
        if (i + 1 < len && c == '_' && [line characterAtIndex:i + 1] == '_') {
            NSRange search = NSMakeRange(i + 2, len - (i + 2));
            NSRange close = [line rangeOfString:@"__" options:0 range:search];
            if (close.location != NSNotFound && close.location > i + 2) {
                NSString *content = [line substringWithRange:
                                     NSMakeRange(i + 2, close.location - (i + 2))];
                if (buf.length > 0) {
                    AppendAttrString(out, buf, baseFont, [iOS6Theme textColor], nil, 0, 0);
                    [buf setString:@""];
                }
                AppendAttrString(out, content, bold, [iOS6Theme textColor], nil, 0, 0);
                i = close.location + 2;
                continue;
            }
        }

        // === Italic _text_ (single underscore) ===========================
        // v261103-5: was missing. Must check AFTER __ to avoid false match.
        // Only match if the underscore is preceded by whitespace or start
        // of line (avoids matching snake_case_words).
        if (c == '_' && i + 1 < len) {
            BOOL prevIsSpace = (i == 0) ||
                ([line characterAtIndex:i - 1] == ' ' ||
                 [line characterAtIndex:i - 1] == '\t' ||
                 [line characterAtIndex:i - 1] == '(' ||
                 [line characterAtIndex:i - 1] == '[');
            if (prevIsSpace) {
                NSRange search = NSMakeRange(i + 1, len - (i + 1));
                NSRange close = [line rangeOfString:@"_" options:0 range:search];
                if (close.location != NSNotFound && close.location > i + 1) {
                    NSString *content = [line substringWithRange:
                                         NSMakeRange(i + 1, close.location - (i + 1))];
                    // Don't match if content contains underscore (snake_case)
                    if ([content rangeOfString:@"_"].location == NSNotFound) {
                        if (buf.length > 0) {
                            AppendAttrString(out, buf, baseFont, [iOS6Theme textColor], nil, 0, 0);
                            [buf setString:@""];
                        }
                        AppendAttrString(out, content, italic, [iOS6Theme textColor], nil, 0, 0);
                        i = close.location + 1;
                        continue;
                    }
                }
            }
        }

        // === Strikethrough ~~text~~ ======================================
        if (i + 1 < len && c == '~' && [line characterAtIndex:i + 1] == '~') {
            NSRange search = NSMakeRange(i + 2, len - (i + 2));
            NSRange close = [line rangeOfString:@"~~" options:0 range:search];
            if (close.location != NSNotFound) {
                NSString *content = [line substringWithRange:
                                     NSMakeRange(i + 2, close.location - (i + 2))];
                if (buf.length > 0) {
                    AppendAttrString(out, buf, baseFont, [iOS6Theme textColor], nil, 0, 0);
                    [buf setString:@""];
                }
                AppendAttrString(out, content, baseFont, [iOS6Theme textColor], nil, 0, 2);
                i = close.location + 2;
                continue;
            }
        }

        // === Inline math $...$  (render as mono with subtle bg) ===========
        if (c == '$') {
            NSRange search = NSMakeRange(i + 1, len - (i + 1));
            NSRange close = [line rangeOfString:@"$" options:0 range:search];
            if (close.location != NSNotFound) {
                NSString *content = [line substringWithRange:
                                     NSMakeRange(i + 1, close.location - (i + 1))];
                if (buf.length > 0) {
                    AppendAttrString(out, buf, baseFont, [iOS6Theme textColor], nil, 0, 0);
                    [buf setString:@""];
                }
                AppendAttrString(out, content, mono,
                                 [iOS6Theme secondaryTextColor],
                                 [iOS6Theme codeBackgroundColor], 0, 0);
                i = close.location + 1;
                continue;
            }
        }

        // === Inline code `text` ==========================================
        if (c == '`') {
            NSRange search = NSMakeRange(i + 1, len - (i + 1));
            NSRange close = [line rangeOfString:@"`" options:0 range:search];
            if (close.location != NSNotFound) {
                NSString *content = [line substringWithRange:
                                     NSMakeRange(i + 1, close.location - (i + 1))];
                if (buf.length > 0) {
                    AppendAttrString(out, buf, baseFont, [iOS6Theme textColor], nil, 0, 0);
                    [buf setString:@""];
                }
                AppendAttrString(out, content, mono,
                                 [iOS6Theme textColor],
                                 [iOS6Theme codeBackgroundColor], 0, 0);
                i = close.location + 1;
                continue;
            }
        }

        // === Italic *text* ===============================================
        if (c == '*') {
            NSRange search = NSMakeRange(i + 1, len - (i + 1));
            NSRange close = [line rangeOfString:@"*" options:0 range:search];
            if (close.location != NSNotFound) {
                NSString *content = [line substringWithRange:
                                     NSMakeRange(i + 1, close.location - (i + 1))];
                if (buf.length > 0) {
                    AppendAttrString(out, buf, baseFont, [iOS6Theme textColor], nil, 0, 0);
                    [buf setString:@""];
                }
                AppendAttrString(out, content, italic, [iOS6Theme textColor], nil, 0, 0);
                i = close.location + 1;
                continue;
            }
        }

        // === Underline <u>text</u> =======================================
        if (i + 3 <= len && [[line substringWithRange:NSMakeRange(i, 3)] isEqualToString:@"<u>"]) {
            NSRange search = NSMakeRange(i + 3, len - (i + 3));
            NSRange close = [line rangeOfString:@"</u>" options:0 range:search];
            if (close.location != NSNotFound) {
                NSString *content = [line substringWithRange:
                                     NSMakeRange(i + 3, close.location - (i + 3))];
                if (buf.length > 0) {
                    AppendAttrString(out, buf, baseFont, [iOS6Theme textColor], nil, 0, 0);
                    [buf setString:@""];
                }
                AppendAttrString(out, content, underlineFont, [iOS6Theme textColor], nil, 1, 0);
                i = close.location + 4;
                continue;
            }
        }

        // === Link [label](url) ===========================================
        if (c == '[') {
            NSRange search = NSMakeRange(i + 1, len - (i + 1));
            NSRange close = [line rangeOfString:@"](" options:0 range:search];
            if (close.location != NSNotFound) {
                NSRange endParen = [line rangeOfString:@")"
                                                options:0
                                                  range:NSMakeRange(close.location + 2,
                                                                       len - (close.location + 2))];
                if (endParen.location != NSNotFound) {
                    NSString *label = [line substringWithRange:
                                       NSMakeRange(i + 1, close.location - (i + 1))];
                    NSString *url = [line substringWithRange:
                                      NSMakeRange(close.location + 2,
                                                    endParen.location - (close.location + 2))];
                    if (buf.length > 0) {
                        AppendAttrString(out, buf, baseFont, [iOS6Theme textColor], nil, 0, 0);
                        [buf setString:@""];
                    }
                    NSMutableAttributedString *linkAttr = [[NSMutableAttributedString alloc]
                                                            initWithString:label];
                    [linkAttr addAttribute:NSUnderlineStyleAttributeName value:@(1)
                                      range:NSMakeRange(0, label.length)];
                    [linkAttr addAttribute:NSForegroundColorAttributeName
                                       value:[iOS6Theme tintColor]
                                       range:NSMakeRange(0, label.length)];
                    // v261103-1: attach the URL so UITextView can open it
                    // when the user taps the link. NSLinkAttributeName is
                    // iOS 7+ on UITextView, but on iOS 6 the value is still
                    // stored and ChatMessageCell's textView delegate can
                    // intercept via textView:shouldInteractWithURL:.
                    // (iOS 6 UITextView calls the delegate even without
                    //  the attribute being officially "supported".)
                    [linkAttr addAttribute:NSLinkAttributeName
                                       value:url
                                       range:NSMakeRange(0, label.length)];
                    [out appendAttributedString:linkAttr];
                    [linkAttr release];
                    i = endParen.location + 1;
                    continue;
                }
            }
        }

        // === Default: append char =======================================
        // v261025-30: handle UTF-16 surrogate pairs (emoji, rare CJK).
        // [stringWithCharacters:length:1] on a high surrogate creates an
        // invalid string → NSAttributedString rendering crash.
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < len) {
            unichar pair[2] = { c, [line characterAtIndex:i + 1] };
            [buf appendString:[NSString stringWithCharacters:pair length:2]];
            i += 2;
        } else {
            [buf appendString:[NSString stringWithCharacters:&c length:1]];
            i++;
        }
    }

    if (buf.length > 0) {
        AppendAttrString(out, buf, baseFont, [iOS6Theme textColor], nil, 0, 0);
    }
    [buf setString:@""];
}

#pragma mark - Block-level renderers

+ (void)_appendHeading:(NSString *)title level:(NSInteger)level
                    to:(NSMutableAttributedString *)out baseFont:(UIFont *)baseFont
{
    // Font sizes per heading level (relative to baseFont).
    CGFloat pt = baseFont.pointSize;
    switch (level) {
        case 1: pt += 8; break;
        case 2: pt += 6; break;
        case 3: pt += 4; break;
        case 4: pt += 2; break;
        case 5: pt += 0; break;
        case 6: pt -= 1; break;
        default: break;
    }
    UIFont *hFont = [UIFont boldSystemFontOfSize:pt];
    AppendAttrString(out, title, hFont, [iOS6Theme textColor], nil, 0, 0);
    AppendAttrString(out, @"\n", baseFont, [iOS6Theme textColor], nil, 0, 0);
}

+ (void)_appendToolStatus:(NSArray *)lines
                       to:(NSMutableAttributedString *)out
                 baseFont:(UIFont *)baseFont
{
    if ([lines count] == 0) return;
    // v261103-8: first element is the block type (:::tool or :::thinking)
    NSString *blockType = [lines objectAtIndex:0];
    BOOL isThinking = [blockType isEqualToString:@":::thinking"];
    NSArray *contentLines = [lines subarrayWithRange:NSMakeRange(1, [lines count] - 1)];
    if ([contentLines count] == 0) return;

    if (isThinking) {
        // v261103-30: 思考卡片穿插渲染 — 标题行 + 内容行，卡片样式
        NSString *fullText = [contentLines componentsJoinedByString:@"\n"];
        NSInteger charCount = [fullText length];
        // 标题行: 💭 思考 (XXX 字)
        NSString *title = [NSString stringWithFormat:@"💭 思考 (%ld 字)", (long)charCount];
        UIFont *titleFont = [UIFont boldSystemFontOfSize:baseFont.pointSize - 1] ?: baseFont;
        UIColor *titleColor = [iOS6Theme tintColor];
        UIColor *cardBG = [iOS6Theme thinkingBackgroundColor];
        UIColor *cardBorder = [iOS6Theme thinkingBorderColor];
        UIColor *contentColor = [iOS6Theme secondaryTextColor];
        UIFont *contentFont = [UIFont systemFontOfSize:baseFont.pointSize - 2] ?: baseFont;

        AppendAttrString(out, @"\n", baseFont, [iOS6Theme textColor], nil, 0, 0);
        // 标题行
        AppendAttrString(out, title, titleFont, titleColor, cardBG, 0, 0);
        AppendAttrString(out, @"\n", titleFont, titleColor, cardBG, 0, 0);
        // 内容行（每行带背景色）
        for (NSString *line in contentLines) {
            AppendAttrString(out, line.length > 0 ? line : @" ", contentFont, contentColor, cardBG, 0, 0);
            AppendAttrString(out, @"\n", contentFont, contentColor, cardBG, 0, 0);
        }
        AppendAttrString(out, @"\n", baseFont, [iOS6Theme textColor], nil, 0, 0);
    } else {
        // tool 块 — 保持现有渲染
        NSString *body = [contentLines componentsJoinedByString:@" · "];
        if (body.length == 0) return;
        UIFont *toolFont = [UIFont italicSystemFontOfSize:baseFont.pointSize - 1] ?: baseFont;
        UIColor *fg = [iOS6Theme secondaryTextColor];
        UIColor *bg = [iOS6Theme codeBackgroundColor];
        AppendAttrString(out, @"\n", toolFont, fg, nil, 0, 0);
        AppendAttrString(out, body, toolFont, fg, bg, 0, 0);
        AppendAttrString(out, @"\n", toolFont, fg, bg, 0, 0);
        AppendAttrString(out, @"\n", toolFont, fg, nil, 0, 0);
    }
}

+ (void)_appendFencedCode:(NSArray *)lines
                       to:(NSMutableAttributedString *)out
                 baseFont:(UIFont *)baseFont
{
    UIFont *mono = [UIFont fontWithName:@"Courier" size:baseFont.pointSize - 1] ?: baseFont;
    UIColor *codeBG = [iOS6Theme codeBackgroundColor];
    UIColor *codeFG = [iOS6Theme textColor];

    // v261025-13: clean code block — no ASCII art borders, no │ prefix.
    // The old │ per-line prefix polluted the code (copy-paste included
    // the │ character). Now just background-colored mono lines with
    // blank-line separators. Code text is copy-clean.
    AppendAttrString(out, @"\n", mono, codeFG, nil, 0, 0);
    for (NSString *line in lines) {
        AppendAttrString(out, line.length > 0 ? line : @" ", mono, codeFG, codeBG, 0, 0);
        AppendAttrString(out, @"\n", mono, codeFG, codeBG, 0, 0);
    }
    AppendAttrString(out, @"\n", mono, codeFG, nil, 0, 0);
}

+ (void)_appendMathBlock:(NSArray *)lines
                      to:(NSMutableAttributedString *)out
                baseFont:(UIFont *)baseFont
{
    UIFont *mono = [UIFont fontWithName:@"Courier" size:baseFont.pointSize - 1] ?: baseFont;
    UIColor *fg = [iOS6Theme secondaryTextColor];
    UIColor *bg = [iOS6Theme codeBackgroundColor];

    // v261025-13: same clean style as code blocks — no │ prefix, no borders.
    AppendAttrString(out, @"\n", mono, fg, nil, 0, 0);
    for (NSString *line in lines) {
        AppendAttrString(out, line.length > 0 ? line : @" ", mono, fg, bg, 0, 0);
        AppendAttrString(out, @"\n", mono, fg, bg, 0, 0);
    }
    AppendAttrString(out, @"\n", mono, fg, nil, 0, 0);
}

+ (void)_appendHorizontalRuleTo:(NSMutableAttributedString *)out
                         baseFont:(UIFont *)baseFont
{
    // v261103-11: no more ──── characters. Use a thin line via
    // background color on a single space (creates a 1pt tall colored bar).
    UIColor *lineColor = [iOS6Theme isDarkMode]
        ? [UIColor colorWithWhite:1.0f alpha:0.15f]
        : [UIColor colorWithWhite:0.0f alpha:0.10f];
    AppendAttrString(out, @"\n", baseFont, lineColor, nil, 0, 0);
    AppendAttrString(out, @" \n", baseFont, lineColor, lineColor, 0, 0);
    AppendAttrString(out, @"\n", baseFont, lineColor, nil, 0, 0);
}

+ (void)_appendTable:(NSArray *)rows
                  to:(NSMutableAttributedString *)out
            baseFont:(UIFont *)baseFont
{
    // v261103-11: COMPLETE REWRITE — no more box-drawing characters
    // (│ ├ ─ ┼ ┤). User said "别用字符代替了UI好吧，会污染的".
    // New approach: clean column layout using padding + background colors.
    // Header row: bold + tinted background. Body rows: alternating bg.
    // No border characters at all — visually distinct without pollution.

    // Parse rows into cells.
    NSMutableArray *table = [NSMutableArray arrayWithCapacity:[rows count]];
    NSUInteger maxCols = 0;
    for (NSString *row in rows) {
        NSString *body = row;
        if ([body hasPrefix:@"|"]) body = [body substringFromIndex:1];
        if ([body hasSuffix:@"|"]) body = [body substringToIndex:body.length - 1];
        NSArray *cells = [body componentsSeparatedByString:@"|"];
        NSMutableArray *trimmed = [NSMutableArray arrayWithCapacity:[cells count]];
        for (NSString *c in cells) {
            [trimmed addObject:[c stringByTrimmingCharactersInSet:
                                [NSCharacterSet whitespaceCharacterSet]]];
        }
        [table addObject:trimmed];
        if ([trimmed count] > maxCols) maxCols = [trimmed count];
    }
    if (maxCols == 0 || [table count] == 0) return;

    // Find column widths (skip separator rows).
    NSMutableArray *colWidths = [NSMutableArray arrayWithCapacity:maxCols];
    for (NSUInteger c = 0; c < maxCols; c++) [colWidths addObject:@(0)];
    for (NSUInteger r = 0; r < [table count]; r++) {
        NSArray *row = [table objectAtIndex:r];
        BOOL isSeparator = YES;
        for (NSString *c in row) {
            if (![c hasPrefix:@"-"] && c.length > 0) { isSeparator = NO; break; }
        }
        if (isSeparator) continue;
        for (NSUInteger c = 0; c < [row count]; c++) {
            NSString *cell = [row objectAtIndex:c];
            NSUInteger w = cell.length;
            if (w > [[colWidths objectAtIndex:c] unsignedIntegerValue]) {
                [colWidths replaceObjectAtIndex:c withObject:@(w)];
            }
        }
    }

    // Colors.
    UIColor *headerBg = [iOS6Theme isDarkMode]
        ? [UIColor colorWithRed:0.15f green:0.18f blue:0.25f alpha:1.0f]
        : [UIColor colorWithRed:0.90f green:0.93f blue:0.97f alpha:1.0f];
    UIColor *bodyBg1 = [iOS6Theme isDarkMode]
        ? [UIColor colorWithRed:0.10f green:0.10f blue:0.12f alpha:1.0f]
        : [UIColor colorWithRed:0.97f green:0.97f blue:0.97f alpha:1.0f];
    UIColor *bodyBg2 = [iOS6Theme codeBackgroundColor];
    UIColor *textColor = [iOS6Theme textColor];
    UIColor *headerColor = [iOS6Theme isDarkMode]
        ? [UIColor colorWithRed:0.85f green:0.88f blue:0.95f alpha:1.0f]
        : [UIColor colorWithRed:0.15f green:0.20f blue:0.35f alpha:1.0f];
    UIFont *headerFont = [UIFont boldSystemFontOfSize:baseFont.pointSize];
    UIFont *bodyFont = baseFont;

    NSUInteger dataRowIdx = 0;
    for (NSUInteger r = 0; r < [table count]; r++) {
        NSArray *row = [table objectAtIndex:r];
        // Skip separator row (---).
        BOOL isSeparator = YES;
        for (NSString *c in row) {
            if (![c hasPrefix:@"-"] && c.length > 0) { isSeparator = NO; break; }
        }
        if (isSeparator) continue;

        BOOL isHeader = (dataRowIdx == 0);
        UIColor *rowBg = isHeader ? headerBg : (dataRowIdx % 2 == 1 ? bodyBg1 : bodyBg2);
        UIFont *rowFont = isHeader ? headerFont : bodyFont;
        UIColor *rowColor = isHeader ? headerColor : textColor;

        // Build the row string with proper column padding.
        NSMutableString *rowStr = [NSMutableString string];
        for (NSUInteger c = 0; c < maxCols; c++) {
            NSString *cell = c < [row count] ? [row objectAtIndex:c] : @"";
            NSUInteger targetW = [[colWidths objectAtIndex:c] unsignedIntegerValue];
            // Pad with spaces to align columns.
            NSString *padded = cell;
            while (padded.length < targetW) {
                padded = [padded stringByAppendingString:@" "];
            }
            // Add cell + separator space.
            [rowStr appendFormat:@"%@  ", padded];
        }
        // Trim trailing spaces.
        NSString *trimmedRow = [rowStr stringByTrimmingCharactersInSet:
                               [NSCharacterSet whitespaceCharacterSet]];

        // Render with background color.
        AppendAttrString(out, trimmedRow, rowFont, rowColor, rowBg, 0, 0);
        AppendAttrString(out, @"\n", rowFont, rowColor, rowBg, 0, 0);
        dataRowIdx++;
    }
    AppendAttrString(out, @"\n", baseFont, textColor, nil, 0, 0);
}

// v261025-30: apply AppleColorEmoji font to emoji character ranges.
// iOS 6's NSAttributedString doesn't auto-fallback to the emoji font
// when the base font (Helvetica/Courier) lacks a glyph — the character
// renders as □ (tofu). This post-processing pass scans the final
// attributed string for emoji codepoints and overrides their font to
// AppleColorEmoji, which has color bitmap glyphs for Unicode 6.0 emoji.
// (Unicode 10+ emoji like 🧐🥳 still show □ — the iOS 6 emoji font
// simply doesn't have those glyphs; nothing we can do.)
+ (void)_applyEmojiFont:(NSMutableAttributedString *)out
              baseFont:(UIFont *)baseFont
{
    if (!out || out.length == 0) return;
    UIFont *emojiFont = [UIFont fontWithName:@"AppleColorEmoji"
                                        size:baseFont.pointSize];
    if (!emojiFont) return;  // font not available on this device

    NSString *str = out.string;
    NSUInteger len = str.length;
    NSUInteger i = 0;
    while (i < len) {
        unichar c = [str characterAtIndex:i];
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < len) {
            // Surrogate pair → compute full codepoint.
            unichar low = [str characterAtIndex:i + 1];
            uint32_t cp = ((uint32_t)(c - 0xD800) << 10) + (low - 0xDC00) + 0x10000;
            // Emoji ranges in the supplementary plane:
            //   U+1F300–1F5FF  Misc Symbols & Pictographs (🎨🔧📋)
            //   U+1F600–1F64F  Emoticons (😀😂)
            //   U+1F680–1F6FF  Transport & Map (🚀✈)
            //   U+1F900–1F9FF  Supplemental (🧐🥳 — may not be in iOS 6 font)
            if ((cp >= 0x1F300 && cp <= 0x1F9FF)) {
                [out addAttribute:NSFontAttributeName value:emojiFont
                           range:NSMakeRange(i, 2)];
            }
            i += 2;
        } else {
            // BMP emoji ranges:
            //   U+2600–27BF  Misc Symbols & Dingbats (☀☕✂✈)
            if (c >= 0x2600 && c <= 0x27BF) {
                [out addAttribute:NSFontAttributeName value:emojiFont
                           range:NSMakeRange(i, 1)];
            }
            i++;
        }
    }
}

@end
