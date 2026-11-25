// set-name.m — 给指定 CoreMIDI 设备设置显示名（仅显示属性，不影响连接/配对）
// 用法: ./set-name <uid> <新名字>
#import <CoreMIDI/CoreMIDI.h>
#import <Foundation/Foundation.h>

static int iprop(MIDIObjectRef obj, CFStringRef prop) {
    int v = -1;
    if (MIDIObjectGetIntegerProperty(obj, prop, &v) == noErr) return v;
    return -1;
}
static NSString *sprop(MIDIObjectRef obj, CFStringRef prop) {
    CFStringRef v = NULL;
    if (MIDIObjectGetStringProperty(obj, prop, &v) == noErr && v) return (__bridge NSString *)v;
    return @"";
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) { fprintf(stderr, "用法: %s <uid整数> <新名字>\n", argv[0]); return 2; }
        int targetUID = atoi(argv[1]);
        NSString *newName = @(argv[2]);
        int nDev = MIDIGetNumberOfDevices();
        for (int i = 0; i < nDev; i++) {
            MIDIDeviceRef d = MIDIGetDevice(i);
            if (iprop(d, kMIDIPropertyUniqueID) == targetUID) {
                printf("改名: %s (uid=%d) → %s (offline=%d)\n",
                       sprop(d, kMIDIPropertyName).UTF8String, targetUID, newName.UTF8String,
                       iprop(d, kMIDIPropertyOffline));
                OSStatus st = MIDIObjectSetStringProperty(d, kMIDIPropertyName, (__bridge CFStringRef)newName);
                if (st != noErr) { fprintf(stderr, "✗ 改名失败: %d\n", (int)st); return 1; }
                printf("✓ 已改名\n");
                return 0;
            }
        }
        fprintf(stderr, "✗ 未找到 uid=%d 的设备\n", targetUID);
        return 1;
    }
}