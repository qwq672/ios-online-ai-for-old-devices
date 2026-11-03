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

// v261103-1: fast-path variant for streaming. When fast=YES, skips the
// expensive passes that aren't visually critical during streaming:
//   - table parsing (rare, complex)
//   - math block parsing (rare)
//   - emoji-font attribute application (O(n) per render)
// The full path runs once on completion to restore all formatting.
+ (NSAttributedString *)attributedStringFromMarkdown:(NSString *)markdown
                                       baseFont:(UIFont *)baseFont
                                          width:(CGFloat)width
                                          fast:(BOOL)fast;

@end
