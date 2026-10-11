//
//  MarkdownParser.m
//  iOS6AIChat
//
//  Implementation is deliberately minimal — we parse line-by-line, applying
//  inline formatting via NSString attribute scanning per text segment.
//  Code blocks (```) are stored as plain monospaced text with a tinted
//  background applied via NSBackgroundColorAttributeName, which UILabel
//  respects on iOS 6+ (not so much — we fall back to a leading chevron
//  indent for clarity if background not honoured).
//

#import "MarkdownParser.h"
#import "iOS6Theme.h"

@implementation MarkdownParser

+ (NSAttributedString *)attributedStringFromMarkdown:(NSString *)markdown
                                          baseFont:(UIFont *)baseFont
                                             width:(CGFloat)width
{
    if (!markdown || markdown.length == 0) {
        return [[[NSAttributedString alloc] initWithString:@""] autorelease];
    }

    NSMutableAttributedString *out = [NSMutableAttributedString new];

    BOOL inFence = NO;
    NSMutableArray *fencedLines = [NSMutableArray array];
    BOOL inBlockquote = NO;
    BOOL prevWasBlank = NO;
    BOOL inParagraph = NO;

    NSArray *lines = [markdown componentsSeparatedByCharactersInSet:
                       [NSCharacterSet characterSetWithCharactersInString:@"\r\n"]];
    for (NSString *rawLine in lines) {
        if ([rawLine length] == 0) {
            if (inParagraph) {
                [out appendAttributedString:
                    [[[NSAttributedString alloc] initWithString:@"\n"] autorelease]];
                inParagraph = NO;
            }
            prevWasBlank = YES;
            continue;
        }

        // Code fence toggle.
        if ([rawLine hasPrefix:@"```"]) {
            if (!inFence) {
                inFence = YES;
                [fencedLines removeAllObjects];
            } else {
                // Close fence — flush.
                [self _appendFencedCode:fencedLines to:out baseFont:baseFont];
                inFence = NO;
                [fencedLines removeAllObjects];
                [out appendAttributedString:
                    [[[NSAttributedString alloc] initWithString:@"\n"] autorelease]];
            }
            prevWasBlank = NO;
            continue;
        }
        if (inFence) {
            [fencedLines addObject:rawLine];
            continue;
        }

        // Headings.
        if ([rawLine hasPrefix:@"### "]) {
            NSString *title = [rawLine substringFromIndex:4];
            [self _appendHeading:title level:3 to:out baseFont:baseFont];
            continue;
        }
        if ([rawLine hasPrefix:@"## "]) {
            NSString *title = [rawLine substringFromIndex:3];
            [self _appendHeading:title level:2 to:out baseFont:baseFont];
            continue;
        }
        if ([rawLine hasPrefix:@"# "]) {
            NSString *title = [rawLine substringFromIndex:2];
            [self _appendHeading:title level:1 to:out baseFont:baseFont];
            continue;
        }

        // Blockquote toggle.
        if ([rawLine hasPrefix:@"> "]) {
            inBlockquote = YES;
            NSString *body = [rawLine substringFromIndex:2];
            [self _appendInlineMarkup:body
                                   to:out
                             baseFont:baseFont
                              prefix:@">  "];
            continue;
        } else {
            inBlockquote = NO;
        }

        // Bullet list item.
        if ([rawLine hasPrefix:@"- "] || [rawLine hasPrefix:@"* "]) {
            NSString *body = [rawLine substringFromIndex:2];
            [self _appendInlineMarkup:body
                                   to:out
                             baseFont:baseFont
                              prefix:@"•  "];
            continue;
        }
        if ([rawLine hasPrefix:@"    - "] || [rawLine hasPrefix:@"  - "]) {
            // Indented bullet — show with an extra space.
            NSString *body = [rawLine stringByTrimmingCharactersInSet:
                              [NSCharacterSet characterSetWithCharactersInString:@" "]];
            body = [body substringFromIndex:2];
            [self _appendInlineMarkup:body
                                   to:out
                             baseFont:baseFont
                              prefix:@"   ◦  "];
            continue;
        }

        // Plain paragraph line.
        [self _appendInlineMarkup:rawLine
                               to:out
                         baseFont:baseFont
                          prefix:nil];
        [out appendAttributedString:
            [[[NSAttributedString alloc] initWithString:@"\n"] autorelease]];
        inParagraph = YES;
        prevWasBlank = NO;
    }

    // Flush an unterminated fence (malformed MD).
    if (inFence && [fencedLines count] > 0) {
        [self _appendFencedCode:fencedLines to:out baseFont:baseFont];
    }

    return [out autorelease];
}

#pragma mark - Inline markup

+ (void)_appendInlineMarkup:(NSString *)line
                         to:(NSMutableAttributedString *)out
                   baseFont:(UIFont *)baseFont
                    prefix:(NSString *)prefix
{
    NSString *text = [NSString stringWithFormat:@"%@%@", prefix ?: @"", line];

    UIFont *bold = [UIFont boldSystemFontOfSize:baseFont.pointSize];
    UIFont *italic = [UIFont italicSystemFontOfSize:baseFont.pointSize];
    UIFont *mono = [UIFont fontWithName:@"Courier" size:baseFont.pointSize] ?: baseFont;

    NSMutableString *buf = [NSMutableString string];
    NSRange lastRange = NSMakeRange(0, 0);

    NSUInteger i = 0;
    NSUInteger len = [text length];
    while (i < len) {
        unichar c = [text characterAtIndex:i];

        // **bold**
        if (i + 1 < len && c == '*' && [text characterAtIndex:i + 1] == '*') {
            // find closing ** — skip current
            NSRange searchRange = NSMakeRange(i + 2, len - (i + 2));
            NSRange close = [text rangeOfString:@"**" options:0 range:searchRange];
            if (close.location != NSNotFound) {
                NSString *content = [text substringWithRange:
                                     NSMakeRange(i + 2, close.location - (i + 2))];
                [out appendAttributedString:
                    [self _attrString:content font:bold baseFont:baseFont]];
                i = close.location + 2;
                continue;
            }
        }

        // *italic*  (only if not preceded by *)
        if (c == '*' && !(i > 0 && [text characterAtIndex:i - 1] == '*')) {
            NSRange searchRange = NSMakeRange(i + 1, len - (i + 1));
            NSRange close = [text rangeOfString:@"*" options:0 range:searchRange];
            if (close.location != NSNotFound) {
                NSString *content = [text substringWithRange:
                                     NSMakeRange(i + 1, close.location - (i + 1))];
                [out appendAttributedString:
                    [self _attrString:content font:italic baseFont:baseFont]];
                i = close.location + 1;
                continue;
            }
        }

        // `inline code`
        if (c == '`') {
            NSRange searchRange = NSMakeRange(i + 1, len - (i + 1));
            NSRange close = [text rangeOfString:@"`" options:0 range:searchRange];
            if (close.location != NSNotFound) {
                NSString *content = [text substringWithRange:
                                     NSMakeRange(i + 1, close.location - (i + 1))];
                NSMutableAttributedString *attr = [self _attrString:content font:mono baseFont:baseFont];
                [attr addAttribute:NSBackgroundColorAttributeName
                              value:[iOS6Theme codeBackgroundColor]
                              range:NSMakeRange(0, [attr length])];
                [out appendAttributedString:attr];
                i = close.location + 1;
                continue;
            }
        }

        // [label](url) — render as italic label with link attr
        if (c == '[') {
            NSRange close = [text rangeOfString:@"](" options:0 range:NSMakeRange(i + 1, len - (i + 1))];
            if (close.location != NSNotFound) {
                NSRange endParen = [text rangeOfString:@")" options:0 range:NSMakeRange(close.location + 2, len - (close.location + 2))];
                if (endParen.location != NSNotFound) {
                    NSString *label = [text substringWithRange:
                                       NSMakeRange(i + 1, close.location - (i + 1))];
                    NSString *url = [text substringWithRange:
                                     NSMakeRange(close.location + 2, endParen.location - (close.location + 2))];
                    NSMutableAttributedString *attr = [self _attrString:label
                                                                    font:[UIFont systemFontOfSize:baseFont.pointSize]
                                                                baseFont:baseFont];
                    // NSLinkAttributeName is iOS 7+; on iOS 6 the link
                    // is rendered as underlined + tinted, and UIDataDetectorTypeLink
                    // on the containing UITextView picks up the URL automatically.
                    [attr addAttribute:NSUnderlineStyleAttributeName
                                 value:@(NSUnderlineStyleSingle)
                                 range:NSMakeRange(0, [attr length])];
                    [attr addAttribute:NSForegroundColorAttributeName
                                 value:[iOS6Theme tintColor]
                                 range:NSMakeRange(0, [attr length])];
                    [out appendAttributedString:attr];
                    i = endParen.location + 1;
                    continue;
                }
            }
        }

        // Default — append char.
        [buf appendString:[NSString stringWithCharacters:&c length:1]];
        lastRange.location = i;  // keep last char position; not actually used here.
        i++;
    }

    if ([buf length] > 0) {
        [out appendAttributedString:
            [self _attrString:buf font:baseFont baseFont:baseFont]];
    }
    [buf setString:@""];
}

+ (NSMutableAttributedString *)_attrString:(NSString *)text
                                       font:(UIFont *)font
                                  baseFont:(UIFont *)baseFont
{
    NSMutableAttributedString *a =
        [[[NSMutableAttributedString alloc] initWithString:text
                                                attributes:@{
            NSFontAttributeName:      font ?: baseFont,
            NSForegroundColorAttributeName: [iOS6Theme textColor]
        }] autorelease];
    return a;
}

+ (void)_appendHeading:(NSString *)title level:(NSInteger)level to:(NSMutableAttributedString *)out baseFont:(UIFont *)baseFont
{
    CGFloat pt = baseFont.pointSize + (level == 1 ? 6 : (level == 2 ? 4 : 2));
    UIFont *headingFont = [UIFont boldSystemFontOfSize:pt];
    NSMutableAttributedString *a = [self _attrString:title font:headingFont baseFont:baseFont];
    [out appendAttributedString:a];
    [out appendAttributedString:
        [[[NSAttributedString alloc] initWithString:@"\n"] autorelease]];
}

+ (void)_appendFencedCode:(NSArray *)lines
                        to:(NSMutableAttributedString *)out
                  baseFont:(UIFont *)baseFont
{
    UIFont *mono = [UIFont fontWithName:@"Courier" size:baseFont.pointSize - 1] ?: baseFont;
    UIColor *codeBG = [iOS6Theme codeBackgroundColor];
    UIColor *border = [iOS6Theme codeBorderColor];
    UIColor *codeFG = [UIColor colorWithRed:0.20f green:0.20f blue:0.20f alpha:1.0f];

    // Decorate the top border.
    [out appendAttributedString:
        [[[NSMutableAttributedString alloc] initWithString:@"───────────\n"
                                               attributes:@{
            NSFontAttributeName: mono,
            NSForegroundColorAttributeName: border
        }] autorelease]];
    for (NSString *line in lines) {
        NSMutableAttributedString *attr =
            [[[NSMutableAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@\n", line]
                                                   attributes:@{
                NSFontAttributeName:      mono,
                NSForegroundColorAttributeName: codeFG,
                NSBackgroundColorAttributeName: codeBG
            }] autorelease];
        [out appendAttributedString:attr];
    }
    [out appendAttributedString:
        [[[NSMutableAttributedString alloc] initWithString:@"───────────\n"
                                               attributes:@{
            NSFontAttributeName: mono,
            NSForegroundColorAttributeName: border
        }] autorelease]];
}

@end
