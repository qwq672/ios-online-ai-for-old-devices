//
//  MarkdownParser.h
//  iOS6AIChat
//
//  Lightweight Markdown → NSAttributedString renderer.
//  Supports:
//     **bold**, *italic*, `inline code`
//     ``` fenced code blocks (with monospace + tinted background) ```
//     # / ## / ### headings
//     - bullet lists (single level)
//     > blockquotes
//     [label](url) — labelled links
//     paragraphs separated by blank lines
//
//  Returns an attributed string suitable for direct display in a UILabel
//  or UITextView. The caller is responsible for sizing.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface MarkdownParser : NSObject

+ (NSAttributedString *)attributedStringFromMarkdown:(NSString *)markdown
                                       baseFont:(UIFont *)baseFont
                                          width:(CGFloat)width;

@end
