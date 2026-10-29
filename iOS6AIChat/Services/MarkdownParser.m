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
    if (!markdown || markdown.length == 0) {
        return [[[NSAttributedString alloc] initWithString:@""] autorelease];
    }
    NSMutableAttributedString *out = [NSMutableAttributedString new];
    NSMutableArray *lines = [[markdown componentsSeparatedByString:@"\n"] mutableCopy];

    // Pass 1: detect + render block-level structures.
    NSUInteger i = 0;
    BOOL inFence = NO;
    BOOL inMathBlock = NO;
    NSMutableArray *fencedLines = [NSMutableArray array];
    NSMutableArray *mathLines = [NSMutableArray array];
    BOOL prevWasBlank = NO;
    BOOL inParagraph = NO;
    NSMutableArray *tableBuffer = [NSMutableArray array];
    BOOL inTable = NO;

    while (i < [lines count]) {
        NSString *rawLine = [lines objectAtIndex:i];
        NSString *line = [rawLine stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];

        // === Code fence toggle ============================================
        if ([line hasPrefix:@"```"]) {
            if (!inFence) {
                inFence = YES;
                [fencedLines removeAllObjects];
            } else {
                // Flush fenced code block.
                [self _appendFencedCode:fencedLines to:out baseFont:baseFont];
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
        if ([line hasPrefix:@"$$"]) {
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
        if ([line hasPrefix:@"> "]) {
            NSString *body = [line substringFromIndex:2];
            [self _appendInlineMarkup:body
                                   to:out
                             baseFont:baseFont
                              prefix:@"│ "];
            i++;
            continue;
        }
        // Nested blockquote (>> or >>>).
        if ([line hasPrefix:@">"]) {
            NSString *body = [line substringFromIndex:1];
            body = [body stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            [self _appendInlineMarkup:body
                                   to:out
                             baseFont:baseFont
                              prefix:@"│ "];
            [out appendAttributedString:[[[NSAttributedString alloc]
                                            initWithString:@"\n"] autorelease]];
            i++;
            continue;
        }

        // === Unordered list item =========================================
        if ([line hasPrefix:@"- "]
            || [line hasPrefix:@"* "]
            || [line hasPrefix:@"+ "]) {
            NSString *body = [line substringFromIndex:2];
            [self _appendInlineMarkup:body
                                   to:out
                             baseFont:baseFont
                              prefix:@"•  "];
            // v261025-13: list items need explicit trailing newline —
            // _appendInlineMarkup doesn't append one (only the paragraph
            // case does). Without this, list items run together.
            [out appendAttributedString:[[[NSAttributedString alloc]
                                            initWithString:@"\n"] autorelease]];
            i++;
            continue;
        }
        // Indented unordered bullet.
        if ([line hasPrefix:@"    - "] || [line hasPrefix:@"  - "]) {
            NSString *body = [line stringByTrimmingCharactersInSet:
                              [NSCharacterSet characterSetWithCharactersInString:@" "]];
            body = [body substringFromIndex:2];
            [self _appendInlineMarkup:body
                                   to:out
                             baseFont:baseFont
                              prefix:@"   ◦  "];
            [out appendAttributedString:[[[NSAttributedString alloc]
                                            initWithString:@"\n"] autorelease]];
            i++;
            continue;
        }

        // === Ordered list item (1. / 2. / ...) ==========================
        NSRegularExpression *orderedRegex = [NSRegularExpression
            regularExpressionWithPattern:@"^(\\d+)\\.\\s"
                                  options:0 error:NULL];
        NSTextCheckingResult *ordMatch = [orderedRegex firstMatchInString:line
                                                                    options:0
                                                                      range:NSMakeRange(0, line.length)];
        if (ordMatch) {
            NSString *numStr = [line substringWithRange:[ordMatch rangeAtIndex:1]];
            NSString *body = [line substringFromIndex:ordMatch.range.location + ordMatch.range.length];
            NSString *prefix = [NSString stringWithFormat:@"%@.  ", numStr];
            [self _appendInlineMarkup:body
                                   to:out
                             baseFont:baseFont
                              prefix:prefix];
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
                    [out appendAttributedString:linkAttr];
                    [linkAttr release];
                    i = endParen.location + 1;
                    continue;
                }
            }
        }

        // === Default: append char =======================================
        [buf appendString:[NSString stringWithCharacters:&c length:1]];
        i++;
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

+ (void)_appendFencedCode:(NSArray *)lines
                       to:(NSMutableAttributedString *)out
                 baseFont:(UIFont *)baseFont
{
    UIFont *mono = [UIFont fontWithName:@"Courier" size:baseFont.pointSize - 1] ?: baseFont;
    UIColor *codeBG = [iOS6Theme codeBackgroundColor];
    UIColor *border = [iOS6Theme codeBorderColor];
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
    UIFont *mono = [UIFont fontWithName:@"Courier" size:baseFont.pointSize - 1] ?: baseFont;
    AppendAttrString(out, @"────────────────────────────────\n",
                     mono, [iOS6Theme codeBorderColor], nil, 0, 0);
}

+ (void)_appendTable:(NSArray *)rows
                  to:(NSMutableAttributedString *)out
            baseFont:(UIFont *)baseFont
{
    // Parse rows into cells.
    NSMutableArray *table = [NSMutableArray arrayWithCapacity:[rows count]];
    NSUInteger maxCols = 0;
    for (NSString *row in rows) {
        // Strip leading | and trailing |.
        NSString *body = row;
        if ([body hasPrefix:@"|"]) body = [body substringFromIndex:1];
        if ([body hasSuffix:@"|"]) body = [body substringToIndex:body.length - 1];
        NSArray *cells = [body componentsSeparatedByString:@"|"];
        // Trim each cell.
        NSMutableArray *trimmed = [NSMutableArray arrayWithCapacity:[cells count]];
        for (NSString *c in cells) {
            [trimmed addObject:[c stringByTrimmingCharactersInSet:
                                [NSCharacterSet whitespaceCharacterSet]]];
        }
        [table addObject:trimmed];
        if ([trimmed count] > maxCols) maxCols = [trimmed count];
    }

    // Find column widths.
    NSMutableArray *colWidths = [NSMutableArray arrayWithCapacity:maxCols];
    for (NSUInteger c = 0; c < maxCols; c++) {
        [colWidths addObject:@(0)];
    }
    for (NSUInteger r = 0; r < [table count]; r++) {
        NSArray *row = [table objectAtIndex:r];
        // Skip separator row (---).
        BOOL isSeparator = YES;
        for (NSString *c in row) {
            if (![c hasPrefix:@"-"] && c.length > 0) { isSeparator = NO; break; }
        }
        if (isSeparator) continue;
        for (NSUInteger c = 0; c < [row count]; c++) {
            NSString *cell = [row objectAtIndex:c];
            NSUInteger w = [cell lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            // Use char count instead of byte count for display width approx.
            w = cell.length;
            if (w > [[colWidths objectAtIndex:c] unsignedIntegerValue]) {
                [colWidths replaceObjectAtIndex:c withObject:@(w)];
            }
        }
    }

    UIFont *mono = [UIFont fontWithName:@"Courier" size:baseFont.pointSize - 1] ?: baseFont;
    UIColor *border = [iOS6Theme codeBorderColor];

    for (NSUInteger r = 0; r < [table count]; r++) {
        NSArray *row = [table objectAtIndex:r];
        NSMutableString *lineStr = [NSMutableString stringWithString:@"│ "];
        for (NSUInteger c = 0; c < maxCols; c++) {
            NSString *cell = c < [row count] ? [row objectAtIndex:c] : @"";
            NSUInteger targetW = [[colWidths objectAtIndex:c] unsignedIntegerValue];
            NSString *padded = cell;
            // Right-pad with spaces to targetW.
            while (padded.length < targetW) {
                padded = [padded stringByAppendingString:@" "];
            }
            [lineStr appendString:padded];
            if (c < maxCols - 1) [lineStr appendString:@" │ "];
        }
        [lineStr appendString:@" │"];
        AppendAttrString(out, lineStr, mono, [iOS6Theme textColor], [iOS6Theme codeBackgroundColor], 0, 0);
        AppendAttrString(out, @"\n", mono, [iOS6Theme textColor], [iOS6Theme codeBackgroundColor], 0, 0);

        // If this is the first row, draw a separator after it.
        if (r == 0) {
            NSMutableString *sep = [NSMutableString stringWithString:@"├─"];
            for (NSUInteger c = 0; c < maxCols; c++) {
                NSUInteger w = [[colWidths objectAtIndex:c] unsignedIntegerValue];
                for (NSUInteger k = 0; k < w; k++) [sep appendString:@"─"];
                if (c < maxCols - 1) [sep appendString:@"─┼─"];
            }
            [sep appendString:@"─┤"];
            AppendAttrString(out, sep, mono, border, nil, 0, 0);
            AppendAttrString(out, @"\n", mono, border, nil, 0, 0);
        }
    }
}

@end
