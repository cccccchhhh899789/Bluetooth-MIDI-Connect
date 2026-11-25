// makeicon.m — 生成蓝牙 MIDI 连接助手的 App 图标（纯 AppKit 绘制，无外部素材）
// 用法：clang -fobjc-arc -framework Cocoa -o build/makeicon tools/makeicon.m
//        build/makeicon <输出目录>   # 生成 AppIcon.iconset/
//
// 图标：圆角深蓝底 + 蓝牙符号 + 三条 MIDI 音符竖线（示意无线传 MIDI）
#import <Cocoa/Cocoa.h>

static void DrawIcon(CGFloat s) {
    NSRect r = NSMakeRect(0, 0, s, s);

    // 圆角深蓝底（渐变）
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:
        NSMakeRect(s * 0.04, s * 0.04, s * 0.92, s * 0.92)
                                                    xRadius:s * 0.22 yRadius:s * 0.22];
    NSGradient *g = [[NSGradient alloc]
        initWithStartingColor:[NSColor colorWithSRGBRed:0.12 green:0.20 blue:0.42 alpha:1]
                  endingColor:[NSColor colorWithSRGBRed:0.03 green:0.06 blue:0.18 alpha:1]];
    [g drawInBezierPath:bg angle:-90];

    // 蓝牙符号（左右两个三角拼接的 B）
    NSColor *blue = [NSColor colorWithSRGBRed:0.30 green:0.65 blue:1.0 alpha:1];
    [blue setFill];
    CGFloat cx = s * 0.5, cy = s * 0.52, hw = s * 0.16, hh = s * 0.34;
    NSBezierPath *bl = [NSBezierPath bezierPath];
    [bl moveToPoint:NSMakePoint(cx, cy + hh)];
    [bl lineToPoint:NSMakePoint(cx - hw, cy)];
    [bl lineToPoint:NSMakePoint(cx, cy - hh)];
    [bl closePath];
    [bl fill];
    NSBezierPath *br = [NSBezierPath bezierPath];
    [br moveToPoint:NSMakePoint(cx, cy + hh)];
    [br lineToPoint:NSMakePoint(cx + hw, cy)];
    [br lineToPoint:NSMakePoint(cx, cy - hh)];
    [br closePath];
    [br fill];
    // 中间横条
    NSRect mid = NSMakeRect(cx - s * 0.045, cy - s * 0.045, s * 0.09, s * 0.09);
    [[NSBezierPath bezierPathWithOvalInRect:mid] fill];

    // 下方三条音符竖线（MIDI 数据流）—— 蓝色透明条
    CGFloat bx = s * 0.30, by = s * 0.075, bw = s * 0.09, bh = s * 0.30;
    for (int i = 0; i < 3; i++) {
        NSRect bar = NSMakeRect(bx + i * (bw + s * 0.055),
                                by + (i == 1 ? s * 0.08 : 0),
                                bw, bh - (i == 2 ? s * 0.06 : 0));
        NSBezierPath *bp = [NSBezierPath bezierPathWithRoundedRect:bar
                                                            xRadius:s * 0.02 yRadius:s * 0.02];
        [[NSColor colorWithSRGBRed:0.35 green:0.72 blue:1.0 alpha:0.85] setFill];
        [bp fill];
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "用法: %s <输出目录>  # 生成 AppIcon.iconset/\n", argv[0]);
            return 1;
        }
        NSString *outDir = @(argv[1]);
        NSFileManager *fm = [NSFileManager defaultManager];
        // 直接把传进来的路径当最终 iconset 目录（不再自己拼 /AppIcon.iconset）
        NSString *iconset = outDir;

        // 规格：16,16@2(32),32,32@2(64),128,128@2(256),256,256@2(512),512,512@2(1024)
        NSArray<NSDictionary *> *sizes = @[
            @{@"name": @"icon_16x16.png",        @"px": @16},
            @{@"name": @"icon_16x16@2x.png",     @"px": @32},
            @{@"name": @"icon_32x32.png",        @"px": @32},
            @{@"name": @"icon_32x32@2x.png",     @"px": @64},
            @{@"name": @"icon_128x128.png",      @"px": @128},
            @{@"name": @"icon_128x128@2x.png",   @"px": @256},
            @{@"name": @"icon_256x256.png",      @"px": @256},
            @{@"name": @"icon_256x256@2x.png",   @"px": @512},
            @{@"name": @"icon_512x512.png",      @"px": @512},
            @{@"name": @"icon_512x512@2x.png",   @"px": @1024},
        ];
        [fm createDirectoryAtPath:iconset withIntermediateDirectories:YES attributes:nil error:nil];
        for (NSDictionary *s in sizes) {
            NSUInteger px = [s[@"px"] unsignedIntegerValue];
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
                initWithBitmapDataPlanes:NULL pixelsWide:px pixelsHigh:px
                            bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                            colorSpaceName:NSCalibratedRGBColorSpace
                            bytesPerRow:0 bitsPerPixel:0];
            [rep setSize:NSMakeSize(px, px)];
            [NSGraphicsContext saveGraphicsState];
            [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
            DrawIcon(px);
            [NSGraphicsContext restoreGraphicsState];
            NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            [png writeToFile:[iconset stringByAppendingPathComponent:s[@"name"]] atomically:YES];
        }
        printf("✓ 图标集已写入 %s\n", iconset.UTF8String);
    }
    return 0;
}