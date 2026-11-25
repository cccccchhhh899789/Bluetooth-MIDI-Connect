// scan-midi.m — 只读探测：列出 CoreMIDI 里所有设备/外部设备/端点/源/目的地（含 BLE 相关属性）
// 用法: clang -fmodules -framework CoreMIDI scan-midi.m -o scan-midi && ./scan-midi
// 不写任何系统状态，纯枚举打印。用 ObjC 而非 Swift 以绕开 CLT 模块缓存权限问题。
#import <CoreMIDI/CoreMIDI.h>
#import <Foundation/Foundation.h>

static NSString *sprop(MIDIObjectRef obj, CFStringRef prop) {
    CFStringRef v = NULL;
    if (MIDIObjectGetStringProperty(obj, prop, &v) == noErr && v) {
        return (__bridge NSString *)v;
    }
    return @"";
}
static int iprop(MIDIObjectRef obj, CFStringRef prop) {
    int v = -1;
    if (MIDIObjectGetIntegerProperty(obj, prop, &v) == noErr) return v;
    return -1;
}

int main(void) {
    @autoreleasepool {
        // 1) 外部设备（蓝牙 MIDI 通常出现在这：MIDIGetNumberOfExternalDevices）
        int nExt = MIDIGetNumberOfExternalDevices();
        printf("== 外部设备数: %d ==\n", nExt);
        for (int i = 0; i < nExt; i++) {
            MIDIDeviceRef d = MIDIGetExternalDevice(i);
            NSString *name = sprop(d, kMIDIPropertyName);
            NSString *manuf = sprop(d, kMIDIPropertyManufacturer);
            NSString *model = sprop(d, kMIDIPropertyModel);
            int uid = iprop(d, kMIDIPropertyUniqueID);
            int offline = iprop(d, kMIDIPropertyOffline);
            int isBLENull = iprop(d, CFSTR("is BLE MIDI null device"));
            printf("外部设备 name=%s manuf=%s model=%s uid=%d offline=%d isBLENull=%d\n",
                   name.UTF8String, manuf.UTF8String, model.UTF8String, uid, offline, isBLENull);
            // 该外部设备的实体与端点
            int nEnt = MIDIDeviceGetNumberOfEntities(d);
            for (int e = 0; e < nEnt; e++) {
                MIDIEntityRef ent = MIDIDeviceGetEntity(d, e);
                NSString *ename = sprop(ent, kMIDIPropertyName);
                int nSrc = MIDIEntityGetNumberOfSources(ent);
                int nDst = MIDIEntityGetNumberOfDestinations(ent);
                printf("  实体[%d] %s src=%d dst=%d\n", e, ename.UTF8String, nSrc, nDst);
                for (int s = 0; s < nSrc; s++) {
                    MIDIEndpointRef src = MIDIEntityGetSource(ent, s);
                    printf("    源: %s uid=%d offline=%d\n",
                           sprop(src, kMIDIPropertyName).UTF8String,
                           iprop(src, kMIDIPropertyUniqueID), iprop(src, kMIDIPropertyOffline));
                }
                for (int t = 0; t < nDst; t++) {
                    MIDIEndpointRef dst = MIDIEntityGetDestination(ent, t);
                    printf("    目的: %s uid=%d offline=%d\n",
                           sprop(dst, kMIDIPropertyName).UTF8String,
                           iprop(dst, kMIDIPropertyUniqueID), iprop(dst, kMIDIPropertyOffline));
                }
            }
        }

        // 2) 全部内部设备（含虚拟端口）
        int nDev = MIDIGetNumberOfDevices();
        printf("\n== 内部设备数: %d ==\n", nDev);
        for (int i = 0; i < nDev; i++) {
            MIDIDeviceRef d = MIDIGetDevice(i);
            NSString *name = sprop(d, kMIDIPropertyName);
            NSString *manuf = sprop(d, kMIDIPropertyManufacturer);
            NSString *model = sprop(d, kMIDIPropertyModel);
            int uid = iprop(d, kMIDIPropertyUniqueID);
            int offline = iprop(d, kMIDIPropertyOffline);
            NSString *driver = sprop(d, kMIDIPropertyDriverOwner);
            int isBLENull = iprop(d, CFSTR("is BLE MIDI null device"));
            printf("内部设备 name=%s manuf=%s model=%s uid=%d offline=%d driver=%s isBLENull=%d\n",
                   name.UTF8String, manuf.UTF8String, model.UTF8String, uid, offline, driver.UTF8String, isBLENull);
            int nEnt = MIDIDeviceGetNumberOfEntities(d);
            for (int e = 0; e < nEnt; e++) {
                MIDIEntityRef ent = MIDIDeviceGetEntity(d, e);
                NSString *ename = sprop(ent, kMIDIPropertyName);
                int nSrc = MIDIEntityGetNumberOfSources(ent);
                int nDst = MIDIEntityGetNumberOfDestinations(ent);
                printf("  实体[%d] %s src=%d dst=%d\n", e, ename.UTF8String, nSrc, nDst);
                for (int s = 0; s < nSrc; s++) {
                    MIDIEndpointRef src = MIDIEntityGetSource(ent, s);
                    printf("    源: %s uid=%d offline=%d\n",
                           sprop(src, kMIDIPropertyName).UTF8String,
                           iprop(src, kMIDIPropertyUniqueID), iprop(src, kMIDIPropertyOffline));
                }
                for (int t = 0; t < nDst; t++) {
                    MIDIEndpointRef dst = MIDIEntityGetDestination(ent, t);
                    printf("    目的: %s uid=%d offline=%d\n",
                           sprop(dst, kMIDIPropertyName).UTF8String,
                           iprop(dst, kMIDIPropertyUniqueID), iprop(dst, kMIDIPropertyOffline));
                }
            }
        }

        // 3) 快速找到 CoreMIDI 内建的蓝牙 null 设备（AppleMIDIBluetoothDriver 持有）
        printf("\n== 扫 BLE null 设备 ==\n");
        NSMutableArray<NSNumber *> *nulls = [NSMutableArray array];
        for (int i = 0; i < nDev; i++) {
            MIDIDeviceRef d = MIDIGetDevice(i);
            int isBLENull = iprop(d, CFSTR("is BLE MIDI null device"));
            if (isBLENull == 1) { [nulls addObject:@(i)]; }
        }
        if (nulls.count == 0) {
            printf("(未找到 is BLE MIDI null device=1 的内部设备)\n");
        }
        for (NSNumber *idx in nulls) {
            MIDIDeviceRef d = MIDIGetDevice(idx.intValue);
            printf("BLE null 设备 idx=%d name=%s uid=%d\n",
                   idx.intValue,
                   sprop(d, kMIDIPropertyName).UTF8String,
                   iprop(d, kMIDIPropertyUniqueID));
        }
    }
    return 0;
}