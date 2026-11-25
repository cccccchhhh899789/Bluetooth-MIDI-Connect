// scan-midi.swift — 只读探测：列出 CoreMIDI 里所有设备/端点/源/目的地，以及 BLE 相关属性
// 用法: swift scan-midi.swift
// 不写任何系统状态，纯枚举打印。
import CoreMIDI
import Foundation

func propString(_ obj: MIDIObjectRef, _ prop: CFString) -> String {
    var v: Unmanaged<CFString>?
    if MIDIObjectGetStringProperty(obj, prop, &v) == noErr, let s = v?.takeRetainedValue() {
        return s as String
    }
    return ""
}
func propInt(_ obj: MIDIObjectRef, _ prop: CFString) -> Int {
    var v: Int32 = 0
    if MIDIObjectGetIntegerProperty(obj, prop, &v) == noErr { return Int(v) }
    return -1
}

let nDev = MIDIGetNumberOfDevices()
print("== 设备数: \(nDev) ==")
for i in 0..<nDev {
    let d = MIDIGetDevice(i)
    let name = propString(d, kMIDIPropertyName)
    let manuf = propString(d, kMIDIPropertyManufacturer)
    let model = propString(d, kMIDIPropertyModel)
    let uid = propInt(d, kMIDIPropertyUniqueID)
    // BLE MIDI 相关：是否蓝牙驱动、离线/在线
    let offline = propInt(d, kMIDIPropertyOffline)
    let driver = propString(d, kMIDIPropertyDriverOwner)
    let isBLE = propInt(d, "is BLE MIDI null device" as CFString)
    print("设备[\(i)] name=\(name) manuf=\(manuf) model=\(model) uid=\(uid) offline=\(offline) driver=\(driver)")
    // 该设备的实体与端点
    let nEnt = MIDIDeviceGetNumberOfEntities(d)
    for e in 0..<nEnt {
        let ent = MIDIDeviceGetEntity(d, e)
        let ename = propString(ent, kMIDIPropertyName)
        let nSrc = MIDIEntityGetNumberOfSources(ent)
        let nDst = MIDIEntityGetNumberOfDestinations(ent)
        print("  实体[\(e)] \(ename) src=\(nSrc) dst=\(nDst)")
        for s in 0..<nSrc {
            let src = MIDIEntityGetSource(ent, s)
            print("    源: \(propString(src, kMIDIPropertyName)) uid=\(propInt(src, kMIDIPropertyUniqueID)) offline=\(propInt(src, kMIDIPropertyOffline))")
        }
        for d2 in 0..<nDst {
            let dst = MIDIEntityGetDestination(ent, d2)
            print("    目的地: \(propString(dst, kMIDIPropertyName)) uid=\(propInt(dst, kMIDIPropertyUniqueID)) offline=\(propInt(dst, kMIDIPropertyOffline))")
        }
    }
    // BLE 特有：BLE MIDI Remote Peripheral 属性（连接过才会在 null device 上）
    if isBLE == 1 || driver.contains("Bluetooth") || driver.contains("bluetooth") {
        print("  [BLE 相关设备] isBLE=\(isBLE) driver=\(driver)")
        var dict: Unmanaged<CFDictionary>?
        if MIDIObjectGetDictionaryProperty(d, kMIDIPropertyName as CFString, &dict) == noErr {}
    }
}

// 也列出所有外部设备（MIDIGetNumberOfExternalDevices）
let nExt = MIDIGetNumberOfExternalDevices()
print("\n== 外部设备数: \(nExt) ==")
for i in 0..<nExt {
    let d = MIDIGetExternalDevice(i)
    let name = propString(d, kMIDIPropertyName)
    let manuf = propString(d, kMIDIPropertyManufacturer)
    let model = propString(d, kMIDIPropertyModel)
    let offline = propInt(d, kMIDIPropertyOffline)
    let uid = propInt(d, kMIDIPropertyUniqueID)
    let isBLE = propInt(d, "is BLE MIDI null device" as CFString)
    print("外部设备 name=\(name) manuf=\(manuf) model=\(model) uid=\(uid) offline=\(offline) isBLE=\(isBLE)")
}