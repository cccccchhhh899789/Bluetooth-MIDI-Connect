// dump-all-props.m — 用 MIDIObjectGetProperties 转储设备/端点「全部」属性键（含未文档化键），
// 找出有没有能表达「广播中/可达/可连接」的 BLE 专属属性。
// 用法: ./dump-all-props "<设备名关键字>"
#import <CoreMIDI/CoreMIDI.h>
#import <Foundation/Foundation.h>

static void dumpAll(MIDIObjectRef obj, NSString *label) {
    CFDictionaryRef props = NULL;
    if (MIDIObjectGetProperties(obj, &props, false) != noErr || !props) {
        printf("  [%s] 无属性字典\n", label.UTF8String);
        return;
    }
    NSDictionary *d = (__bridge NSDictionary *)props;
    NSMutableArray *keys = [d.allKeys mutableCopy];
    // 按 key 排序输出，便于对比两台设备
    [keys sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [a compare:b];
    }];
    for (NSString *k in keys) {
        id v = [d objectForKey:k];
        if ([v isKindOfClass:[NSDictionary class]]) {
            printf("  [%s] %s = (dict) %s\n", label.UTF8String, k.UTF8String, [(NSString *)v description].UTF8String);
        } else if ([v isKindOfClass:[NSArray class]]) {
            printf("  [%s] %s = (array) %s\n", label.UTF8String, k.UTF8String, [(NSString *)v description].UTF8String);
        } else {
            printf("  [%s] %s = %s\n", label.UTF8String, k.UTF8String, [(NSString *)v description].UTF8String);
        }
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *kw = argc > 1 ? @(argv[1]) : @"";
        int nDev = MIDIGetNumberOfDevices();
        for (int i = 0; i < nDev; i++) {
            MIDIDeviceRef d = MIDIGetDevice(i);
            NSString *name = @"";
            CFStringRef nm = NULL;
            if (MIDIObjectGetStringProperty(d, kMIDIPropertyName, &nm) == noErr && nm) {
                name = (__bridge_transfer NSString *)nm;
            }
            if (kw.length && [name rangeOfString:kw].location == NSNotFound) continue;
            int offline = -1;
            MIDIObjectGetIntegerProperty(d, kMIDIPropertyOffline, &offline);
            printf("## 设备[%d] name=%s offline=%d\n", i, name.UTF8String, offline);
            dumpAll(d, @"device");
            int nEnt = MIDIDeviceGetNumberOfEntities(d);
            for (int e = 0; e < nEnt; e++) {
                MIDIEntityRef ent = MIDIDeviceGetEntity(d, e);
                dumpAll(ent, @"entity");
                int nSrc = MIDIEntityGetNumberOfSources(ent);
                for (int s = 0; s < nSrc; s++) dumpAll(MIDIEntityGetSource(ent, s), @"src");
                int nDst = MIDIEntityGetNumberOfDestinations(ent);
                for (int t = 0; t < nDst; t++) dumpAll(MIDIEntityGetDestination(ent, t), @"dst");
            }
        }
    }
    return 0;
}
