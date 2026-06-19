/*
 * Metamorphia
 * Original work Copyright (C) 2026 ZephyrCodesStuff (https://github.com/ZephyrCodesStuff/rtaudio)
 * Modified work Copyright (C) 2026 Metamorphia Contributors
 *
 * Objective-C++ implementation bridging AudioProcessor to Swift.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This file is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

#import "AudioBridge.h"
#import "AudioProcessor.hpp"
#include <new>

@implementation AudioBridge {
    AudioProcessor *processor;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        processor = new (std::nothrow) AudioProcessor();
    }
    return self;
}

- (void)processBuffer:(const float *)buffer count:(int)count {
    if (processor == nullptr || buffer == nullptr || count <= 0) { return; }
    processor->process(buffer, count);
}

- (simd_float4)getSmoothedMagnitudes {
    if (processor == nullptr) {
        return simd_make_float4(0, 0, 0, 0);
    }
    return simd_make_float4(
        processor->getBand(0),
        processor->getBand(1),
        processor->getBand(2),
        processor->getBand(3)
    );
}

- (void)dealloc {
    delete processor;
}

@end
