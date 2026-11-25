// probe-client.m — 验证「先建 MIDIClient 能否唤醒 MIDIServer」
// 用法: probe-client [0|1]   0=直接枚举  1=先 MIDIClientCreate 再枚举
#import <CoreMIDI/CoreMIDI.h>
#import <CoreFoundation/CoreFoundation.h>
#import <stdio.h>
#import <stdlib.h>
#import <time.h>

static double now_ms(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec*1000.0 + t.tv_nsec/1e6; }

int main(int argc, const char *argv[]){
    int mode = (argc > 1) ? atoi(argv[1]) : 0;
    double t0 = now_ms();
    if(mode == 1){
        MIDIClientRef cl = 0;
        OSStatus st = MIDIClientCreate(CFSTR("probe"), NULL, NULL, &cl);
        printf("[probe] MIDIClientCreate: OSStatus=%d (%lldms)\n", (int)st, (long long)(now_ms()-t0));
        if(cl) MIDIClientDispose(cl);
    }
    double t1 = now_ms();
    int n = MIDIGetNumberOfDevices();
    printf("[probe] MIDIGetNumberOfDevices: n=%d (%lldms)\n", n, (long long)(now_ms()-t1));
    for(int i=0;i<n;i++){
        MIDIDeviceRef d = MIDIGetDevice(i);
        int off = -1;
        MIDIObjectGetIntegerProperty(d, kMIDIPropertyOffline, &off);
        printf("[probe]   dev[%d] offline=%d\n", i, off);
    }
    printf("[probe] TOTAL mode=%d : %lldms\n", mode, (long long)(now_ms()-t0));
    return 0;
}
