//
//  NSDataBase64.h
//  iOS6AIChat
//
//  Base64 encoding/decoding for iOS 6 (no public API before iOS 7).
//  Uses libcrypto (OpenSSL) which is always available on iOS.
//

#import <Foundation/Foundation.h>

@interface NSData (Base64)
+ (NSData *)dataFromBase64String:(NSString *)string;
- (NSString *)base64String;
@end
