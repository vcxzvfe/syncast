#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int read_cfstring(AudioObjectID id,
                         AudioObjectPropertySelector selector,
                         char *buffer,
                         size_t buffer_len) {
    AudioObjectPropertyAddress address = {
        selector,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    CFStringRef value = NULL;
    UInt32 size = sizeof(value);
    OSStatus status = AudioObjectGetPropertyData(
        id,
        &address,
        0,
        NULL,
        &size,
        &value
    );
    if (status != noErr || value == NULL) {
        if (buffer_len > 0) {
            buffer[0] = '\0';
        }
        return 0;
    }
    Boolean ok = CFStringGetCString(
        value,
        buffer,
        buffer_len,
        kCFStringEncodingUTF8
    );
    if (!ok && buffer_len > 0) {
        buffer[0] = '\0';
    }
    CFRelease(value);
    return ok ? 1 : 0;
}

static int read_default_device(AudioObjectPropertySelector selector,
                               AudioObjectID *out_id,
                               OSStatus *out_status) {
    AudioObjectPropertyAddress address = {
        selector,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    AudioObjectID id = kAudioObjectUnknown;
    UInt32 size = sizeof(id);
    OSStatus status = AudioObjectGetPropertyData(
        kAudioObjectSystemObject,
        &address,
        0,
        NULL,
        &size,
        &id
    );
    if (out_status != NULL) {
        *out_status = status;
    }
    if (status != noErr || id == kAudioObjectUnknown) {
        return 1;
    }
    *out_id = id;
    return 0;
}

static int default_output_device(AudioObjectID *out_id) {
    OSStatus output_status = noErr;
    OSStatus system_status = noErr;
    if (read_default_device(
            kAudioHardwarePropertyDefaultOutputDevice,
            out_id,
            &output_status
        ) == 0) {
        return 0;
    }
    if (read_default_device(
            kAudioHardwarePropertyDefaultSystemOutputDevice,
            out_id,
            &system_status
        ) == 0) {
        return 0;
    }
    fprintf(
        stderr,
        "ERROR: default output read failed outputOSStatus=%d systemOSStatus=%d\n",
        output_status,
        system_status
    );
    return 1;
}

static int read_class_id(AudioObjectID id, AudioClassID *out_class_id) {
    AudioObjectPropertyAddress address = {
        kAudioObjectPropertyClass,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    AudioClassID class_id = 0;
    UInt32 size = sizeof(class_id);
    OSStatus status = AudioObjectGetPropertyData(
        id,
        &address,
        0,
        NULL,
        &size,
        &class_id
    );
    if (status != noErr) {
        return 0;
    }
    *out_class_id = class_id;
    return 1;
}

static void fourcc_string(AudioClassID class_id, char out[5]) {
    out[0] = (char)((class_id >> 24) & 0xff);
    out[1] = (char)((class_id >> 16) & 0xff);
    out[2] = (char)((class_id >> 8) & 0xff);
    out[3] = (char)(class_id & 0xff);
    out[4] = '\0';
    for (int i = 0; i < 4; i++) {
        if (out[i] < 32 || out[i] > 126) {
            out[i] = '?';
        }
    }
}

static int aggregate_active_subdevice_count(AudioObjectID id) {
    AudioObjectPropertyAddress address = {
        kAudioAggregateDevicePropertyActiveSubDeviceList,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    if (!AudioObjectHasProperty(id, &address)) {
        return 0;
    }
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(id, &address, 0, NULL, &size);
    if (status != noErr || size == 0) {
        return 0;
    }
    return (int)(size / sizeof(AudioObjectID));
}

static void print_device(AudioObjectID id) {
    char uid[1024] = "";
    char name[1024] = "";
    char class_name[5] = "????";
    AudioClassID class_id = 0;
    read_cfstring(id, kAudioDevicePropertyDeviceUID, uid, sizeof(uid));
    read_cfstring(id, kAudioObjectPropertyName, name, sizeof(name));
    if (read_class_id(id, &class_id)) {
        fourcc_string(class_id, class_name);
    }
    printf(
        "%u\t%s\t%s\tclass=%s\tsubdevices=%d\n",
        id,
        uid,
        name,
        class_name,
        aggregate_active_subdevice_count(id)
    );
}

static AudioObjectID *copy_all_devices(UInt32 *out_count) {
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(
        kAudioObjectSystemObject,
        &address,
        0,
        NULL,
        &size
    );
    if (status != noErr || size == 0) {
        return NULL;
    }
    AudioObjectID *ids = (AudioObjectID *)calloc(1, size);
    if (ids == NULL) {
        return NULL;
    }
    status = AudioObjectGetPropertyData(
        kAudioObjectSystemObject,
        &address,
        0,
        NULL,
        &size,
        ids
    );
    if (status != noErr) {
        free(ids);
        return NULL;
    }
    *out_count = size / (UInt32)sizeof(AudioObjectID);
    return ids;
}

static int output_channel_count(AudioObjectID id) {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyStreamConfiguration,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain,
    };
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(id, &address, 0, NULL, &size);
    if (status != noErr || size == 0) {
        return 0;
    }
    AudioBufferList *buffers = (AudioBufferList *)calloc(1, size);
    if (buffers == NULL) {
        return 0;
    }
    status = AudioObjectGetPropertyData(id, &address, 0, NULL, &size, buffers);
    if (status != noErr) {
        free(buffers);
        return 0;
    }
    int channels = 0;
    for (UInt32 i = 0; i < buffers->mNumberBuffers; i++) {
        channels += (int)buffers->mBuffers[i].mNumberChannels;
    }
    free(buffers);
    return channels;
}

static int find_device_by_uid(const char *wanted_uid, AudioObjectID *out_id) {
    UInt32 count = 0;
    AudioObjectID *ids = copy_all_devices(&count);
    if (ids == NULL) {
        return 1;
    }
    for (UInt32 i = 0; i < count; i++) {
        char uid[1024] = "";
        read_cfstring(ids[i], kAudioDevicePropertyDeviceUID, uid, sizeof(uid));
        if (strcmp(uid, wanted_uid) == 0) {
            *out_id = ids[i];
            free(ids);
            return 0;
        }
    }
    free(ids);
    return 1;
}

static int set_default_output(AudioObjectID id) {
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 size = sizeof(id);
    OSStatus status = AudioObjectSetPropertyData(
        kAudioObjectSystemObject,
        &address,
        0,
        NULL,
        size,
        &id
    );
    if (status != noErr) {
        fprintf(stderr, "ERROR: default output set failed OSStatus=%d\n", status);
        return 1;
    }
    return 0;
}

static int list_output_devices(void) {
    UInt32 count = 0;
    AudioObjectID *ids = copy_all_devices(&count);
    if (ids == NULL) {
        fprintf(stderr, "ERROR: could not enumerate CoreAudio devices\n");
        return 1;
    }
    for (UInt32 i = 0; i < count; i++) {
        if (output_channel_count(ids[i]) > 0) {
            print_device(ids[i]);
        }
    }
    free(ids);
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 1) {
        AudioObjectID id = kAudioObjectUnknown;
        if (default_output_device(&id) != 0) {
            return 1;
        }
        print_device(id);
        return 0;
    }
    if (argc == 2 && strcmp(argv[1], "--list-output-devices") == 0) {
        return list_output_devices();
    }
    if (argc == 3 && strcmp(argv[1], "--set-default-uid") == 0) {
        AudioObjectID id = kAudioObjectUnknown;
        if (find_device_by_uid(argv[2], &id) != 0) {
            fprintf(stderr, "ERROR: output UID not found: %s\n", argv[2]);
            return 1;
        }
        if (set_default_output(id) != 0) {
            return 1;
        }
        print_device(id);
        return 0;
    }
    fprintf(stderr, "Usage: %s [--list-output-devices | --set-default-uid UID]\n", argv[0]);
    return 0;
}
