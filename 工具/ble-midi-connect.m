// ble-midi-connect.m — 连接已配对的 BLE MIDI 设备（替代手动去音频MIDI设置点Connect）
// 原理（lumi-connect 验证过）：给 CoreMIDI 内建 BLE null 设备设置
//   BLE MIDI Remote Peripheral = {"BLE MIDI Device UUID": <uuid>, "name": <name>}
// 驱动 AppleMIDIBluetoothDriver 随即连接该外设；连上后属性被移除，本进程可退出。
//
// 用法: ./ble-midi-connect <uuid> [设备名]
// 例:   ./ble-midi-connect 5E5811A2-2544-DAEF-E83A-B822A9D05747 MidiPortB
//
// 安全：只设置一个"请求连接"属性，不改配对、不删设备、不碰其他设备。
//       连接请求由系统驱动执行，进程退出不影响已建立的连接。
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
// 找 CoreMIDI 内建的 BLE null 设备（AppleMIDIBluetoothDriver 持有，is BLE MIDI null device=1）
static MIDIDeviceRef findBLENullDevice(void) {
    int nDev = MIDIGetNumberOfDevices();
    for (int i = 0; i < nDev; i++) {
        MIDIDeviceRef d = MIDIGetDevice(i);
        if (iprop(d, CFSTR("is BLE MIDI null device")) == 1) return d;
    }
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "用法: %s <BLE UUID> [设备名]\n", argv[0]);
            fprintf(stderr, "  UUID 来自 CoreMIDI 设备属性的 'BLE MIDI Device UUID'\n");
            return 2;
        }
        NSString *uuid = @(argv[1]);
        NSString *name = argc > 2 ? @(argv[2]) : @"BLE MIDI";
        BOOL dryRun = (argc > 3 && strcmp(argv[3], "--dry-run") == 0);

        MIDIDeviceRef nullDev = findBLENullDevice();
        if (!nullDev) {
            fprintf(stderr, "✗ 找不到 CoreMIDI BLE null 设备（is BLE MIDI null device=1）\n");
            return 1;
        }
        printf("✓ BLE null 设备: name=%s uid=%d\n",
               sprop(nullDev, kMIDIPropertyName).UTF8String,
               iprop(nullDev, kMIDIPropertyUniqueID));

        // 构造远程外设字典：{"BLE MIDI Device UUID": <uuid>, "name": <name>}
        NSDictionary *periph = @{
            @"BLE MIDI Device UUID": uuid,
            @"name": name,
        };
        if (dryRun) {
            printf("--dry-run：本会设置 BLE MIDI Remote Peripheral = %s\n",
                   periph.description.UTF8String);
            printf("  但未实际调用 MIDIObjectSetDictionaryProperty。\n");
            return 0;
        }
        OSStatus st = MIDIObjectSetDictionaryProperty(nullDev,
                                                      CFSTR("BLE MIDI Remote Peripheral"),
                                                      (__bridge CFDictionaryRef)periph);
        if (st != noErr) {
            fprintf(stderr, "✗ 设置 BLE MIDI Remote Peripheral 失败: %d\n", (int)st);
            return 1;
        }
        printf("✓ 已向驱动发送连接请求:\n");
        printf("    UUID = %s\n    name = %s\n", uuid.UTF8String, name.UTF8String);
        printf("  驱动将异步连接；等待并观察 MIDI 工作室/MIDI Monitor 是否上线。\n");
        return 0;
    }
}