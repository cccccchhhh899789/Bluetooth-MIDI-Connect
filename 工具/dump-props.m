// dump-props.m — 只读转储指定 CoreMIDI 设备/端点的全部属性（string/int/字典），找 BLE MIDI UUID。
// 用法: ./dump-props "<设备名关键字>"   （name 里含该关键字的设备与端点全转储）
#import <CoreMIDI/CoreMIDI.h>
#import <Foundation/Foundation.h>

static NSString *sprop(MIDIObjectRef obj, CFStringRef prop) {
    CFStringRef v = NULL;
    if (MIDIObjectGetStringProperty(obj, prop, &v) == noErr && v) return (__bridge NSString *)v;
    return @"";
}
static int iprop(MIDIObjectRef obj, CFStringRef prop) {
    int v = -1;
    if (MIDIObjectGetIntegerProperty(obj, prop, &v) == noErr) return v;
    return -1;
}
static void dumpDict(MIDIObjectRef obj, CFStringRef prop, NSString *label) {
    CFDictionaryRef pl = NULL;
    if (MIDIObjectGetDictionaryProperty(obj, prop, &pl) == noErr && pl) {
        NSDictionary *d = (__bridge NSDictionary *)pl;
        printf("  [字典属性] %s = %s\n", label.UTF8String, d.description.UTF8String);
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *kw = argc > 1 ? @(argv[1]) : @"";
        // 内部设备
        int nDev = MIDIGetNumberOfDevices();
        for (int i = 0; i < nDev; i++) {
            MIDIDeviceRef d = MIDIGetDevice(i);
            NSString *name = sprop(d, kMIDIPropertyName);
            if (kw.length && [name rangeOfString:kw].location == NSNotFound) continue;
            printf("## 设备[%d] name=%s uid=%d offline=%d\n",
                   i, name.UTF8String, iprop(d, kMIDIPropertyUniqueID), iprop(d, kMIDIPropertyOffline));
            // 全量字符串属性
            NSArray *strProps = @[(__bridge NSString*)kMIDIPropertyName,
                                  (__bridge NSString*)kMIDIPropertyManufacturer,
                                  (__bridge NSString*)kMIDIPropertyModel,
                                  (__bridge NSString*)kMIDIPropertyDriverOwner,
                                  (__bridge NSString*)kMIDIPropertyUniqueID,
                                  (__bridge NSString*)kMIDIPropertyDisplayName,
                                  (__bridge NSString*)kMIDIPropertyNameConfiguration];
            for (NSString *p in strProps) {
                NSString *v = sprop(d, (__bridge CFStringRef)p);
                if (v.length) printf("    str[%s] = %s\n", p.UTF8String, v.UTF8String);
            }
            // 已知/可能的 BLE 专属键（含未文档化的）
            NSArray *bleKeys = @[@"BLE MIDI Device UUID", @"BLE MIDI Remote Peripheral",
                                 @"BLE MIDI Local Peripheral", @"disconnect device",
                                 @"is BLE MIDI null device", @"apple midi ble device uuid"];
            for (NSString *k in bleKeys) {
                NSString *v = sprop(d, (__bridge CFStringRef)k);
                if (v.length) printf("    [BLE] %s = %s\n", k.UTF8String, v.UTF8String);
                dumpDict(d, (__bridge CFStringRef)k, k);
            }
            // 端点
            int nEnt = MIDIDeviceGetNumberOfEntities(d);
            for (int e = 0; e < nEnt; e++) {
                MIDIEntityRef ent = MIDIDeviceGetEntity(d, e);
                int nSrc = MIDIEntityGetNumberOfSources(ent);
                int nDst = MIDIEntityGetNumberOfDestinations(ent);
                for (int s = 0; s < nSrc; s++) {
                    MIDIEndpointRef src = MIDIEntityGetSource(ent, s);
                    NSString *sn = sprop(src, kMIDIPropertyName);
                    printf("    源: %s uid=%d offline=%d\n", sn.UTF8String,
                           iprop(src, kMIDIPropertyUniqueID), iprop(src, kMIDIPropertyOffline));
                    for (NSString *k in bleKeys) {
                        NSString *v = sprop(src, (__bridge CFStringRef)k);
                        if (v.length) printf("      [BLE] %s = %s\n", k.UTF8String, v.UTF8String);
                        dumpDict(src, (__bridge CFStringRef)k, k);
                    }
                }
                for (int t = 0; t < nDst; t++) {
                    MIDIEndpointRef dst = MIDIEntityGetDestination(ent, t);
                    NSString *dn = sprop(dst, kMIDIPropertyName);
                    printf("    目的: %s uid=%d offline=%d\n", dn.UTF8String,
                           iprop(dst, kMIDIPropertyUniqueID), iprop(dst, kMIDIPropertyOffline));
                    for (NSString *k in bleKeys) {
                        NSString *v = sprop(dst, (__bridge CFStringRef)k);
                        if (v.length) printf("      [BLE] %s = %s\n", k.UTF8String, v.UTF8String);
                        dumpDict(dst, (__bridge CFStringRef)k, k);
                    }
                }
            }
        }
        // 外部设备
        int nExt = MIDIGetNumberOfExternalDevices();
        for (int i = 0; i < nExt; i++) {
            MIDIDeviceRef d = MIDIGetExternalDevice(i);
            NSString *name = sprop(d, kMIDIPropertyName);
            if (kw.length && [name rangeOfString:kw].location == NSNotFound) continue;
            printf("## 外部设备[%d] name=%s uid=%d offline=%d\n", i,
                   name.UTF8String, iprop(d, kMIDIPropertyUniqueID), iprop(d, kMIDIPropertyOffline));
            for (NSString *k in @[@"BLE MIDI Device UUID", @"BLE MIDI Remote Peripheral"]) {
                dumpDict(d, (__bridge CFStringRef)k, k);
            }
        }
    }
    return 0;
}