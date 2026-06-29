/*
 * Metamorphia
 * Copyright (C) 2024-2026 Metamorphia Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

#import "ExceptionTrap.h"

@implementation ExceptionTrap

+ (nullable id)trying:(id _Nullable (^)(void))block error:(NSError * _Nullable * _Nullable)error {
    @try {
        return block();
    } @catch (NSException *exception) {
        if (error) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            if (exception.reason) {
                info[NSLocalizedDescriptionKey] = exception.reason;
            }
            if (exception.name) {
                info[@"ExceptionName"] = exception.name;
            }
            *error = [NSError errorWithDomain:@"MetamorphiaExceptionTrap" code:1 userInfo:info];
        }
        return nil;
    }
}

@end
