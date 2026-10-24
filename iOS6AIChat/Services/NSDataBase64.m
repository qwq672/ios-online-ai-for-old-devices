//
//  NSDataBase64.m
//  iOS6AIChat
//
//  Simple base64 encoder/decoder — no dependency on iOS 7+ APIs.
//  Uses a lookup table for decoding and manual encoding.
//

#import "NSDataBase64.h"

static const char base64Chars[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

@implementation NSData (Base64)

+ (NSData *)dataFromBase64String:(NSString *)string {
    if (!string || string.length == 0) return nil;
    
    // Build decode lookup table.
    static int decodeTable[256];
    static BOOL initialized = NO;
    if (!initialized) {
        memset(decodeTable, -1, sizeof(decodeTable));
        for (int i = 0; i < 64; i++) {
            decodeTable[(unsigned char)base64Chars[i]] = i;
        }
        initialized = YES;
    }
    
    const char *src = [string UTF8String];
    NSUInteger srcLen = strlen(src);
    
    // Strip non-base64 characters (whitespace, newlines, etc).
    char *clean = (char *)malloc(srcLen + 1);
    NSUInteger cleanLen = 0;
    for (NSUInteger i = 0; i < srcLen; i++) {
        unsigned char c = src[i];
        if (decodeTable[c] >= 0 || c == '=') {
            clean[cleanLen++] = c;
        }
    }
    clean[cleanLen] = 0;
    
    // Calculate output length.
    NSUInteger outLen = (cleanLen / 4) * 3;
    if (cleanLen >= 1 && clean[cleanLen-1] == '=') outLen--;
    if (cleanLen >= 2 && clean[cleanLen-2] == '=') outLen--;
    
    if (outLen == 0) {
        free(clean);
        return nil;
    }
    
    unsigned char *out = (unsigned char *)malloc(outLen);
    NSUInteger outIdx = 0;
    
    NSUInteger i = 0;
    while (i + 3 < cleanLen) {
        int v0 = decodeTable[(unsigned char)clean[i]];
        int v1 = decodeTable[(unsigned char)clean[i+1]];
        int v2 = (clean[i+2] == '=') ? 0 : decodeTable[(unsigned char)clean[i+2]];
        int v3 = (clean[i+3] == '=') ? 0 : decodeTable[(unsigned char)clean[i+3]];
        
        if (v0 < 0 || v1 < 0) { free(clean); free(out); return nil; }
        
        unsigned int triple = (v0 << 18) | (v1 << 12) | (v2 << 6) | v3;
        
        if (outIdx < outLen) out[outIdx++] = (triple >> 16) & 0xFF;
        if (outIdx < outLen) out[outIdx++] = (triple >> 8) & 0xFF;
        if (outIdx < outLen) out[outIdx++] = triple & 0xFF;
        
        i += 4;
    }
    
    free(clean);
    
    NSData *result = [NSData dataWithBytes:out length:outLen];
    free(out);
    // v261025-1: return +0 (autoreleased), matching the convenience-
    // constructor naming convention. The old `[result retain]` returned +1
    // with a "caller owns" comment, but the ONLY caller (ChatMessageCell's
    // bg decode block) never released it → multi-MB leak per decoded image.
    return result;
}

- (NSString *)base64String {
    const unsigned char *bytes = [self bytes];
    NSUInteger srcLen = [self length];
    
    if (srcLen == 0) return @"";
    
    NSUInteger outLen = ((srcLen + 2) / 3) * 4;
    char *out = (char *)malloc(outLen + 1);
    NSUInteger outIdx = 0;
    
    for (NSUInteger i = 0; i < srcLen; i += 3) {
        unsigned int triple = bytes[i] << 16;
        if (i + 1 < srcLen) triple |= bytes[i+1] << 8;
        if (i + 2 < srcLen) triple |= bytes[i+2];
        
        out[outIdx++] = base64Chars[(triple >> 18) & 0x3F];
        out[outIdx++] = base64Chars[(triple >> 12) & 0x3F];
        out[outIdx++] = (i + 1 < srcLen) ? base64Chars[(triple >> 6) & 0x3F] : '=';
        out[outIdx++] = (i + 2 < srcLen) ? base64Chars[triple & 0x3F] : '=';
    }
    out[outIdx] = 0;
    
    NSString *result = [NSString stringWithCString:out encoding:NSASCIIStringEncoding];
    free(out);
    return result;
}

@end
