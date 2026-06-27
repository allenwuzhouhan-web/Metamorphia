/*
 * Metamorphia
 * Copyright (C) 2024-2026 Metamorphia Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs an Objective-C block and converts any raised `NSException` into a
/// Swift-catchable `NSError`. Needed for Foundation APIs such as
/// `NSExpression(format:)` that raise Objective-C exceptions which a Swift
/// `do`/`catch` cannot intercept (the catch block is dead code).
@interface ExceptionTrap : NSObject

/// Invokes `block`. Returns its value, or `nil` if the block raised an
/// `NSException` (in which case `error` is populated with the exception name
/// and reason).
+ (nullable id)trying:(id _Nullable (^)(void))block error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
