//
//  property_sweep.c
//  SyncCastAudio.driver — out-of-coreaudiod test harness
//
//  Loads a built SyncCastAudio bundle with dlopen(), asks its factory for the
//  AudioServerPlugInDriverInterface, and drives it the way the HAL would, but
//  under whatever sanitizer the harness was compiled with. Run it through
//  tests/run_property_sweep.sh, which builds the driver three ways (plain,
//  ASan+UBSan, TSan) and runs this against each.
//
//  What it covers:
//    1. property sweep   objects 0..6 (1..5 are the real ones) x every common
//                        selector x global/input/output scope, with exact,
//                        one-byte-short and zero-length buffers. Buffers are
//                        heap-allocated at EXACTLY the size handed to the
//                        driver, so ASan's redzones catch any overrun that a
//                        stack buffer would silently absorb.
//    2. qualifiers       TranslateUIDToDevice with a matching UID, a wrong
//                        UID, a NULL pointer at the right size, and a wrong
//                        size.
//    3. setters          volume (scalar + dB), mute, IsActive, the stream
//                        format, and the device sample rate — including the
//                        cases that must be REFUSED.
//    4. persistence      counts WriteToStorage calls to prove a burst of
//                        volume steps is coalesced and that StopIO flushes.
//    5. timeline         StartIO then GetZeroTimeStamp for 2 s: sample time
//                        must be monotonic and move in whole 19200-frame
//                        steps, one per ~400 ms at 48 kHz.
//    6. concurrency      property getters/setters on several threads while a
//                        sixth calls GetZeroTimeStamp — the case the two-mutex
//                        split exists for. Meaningful under TSan.
//

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>

#include <dlfcn.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Mirrors of the driver's private constants. Deliberately duplicated rather
// than included: the harness is a client, and a client only knows what the
// driver advertises. If one of these drifts, that is a finding, not a merge.
#define kTest_Device_UID            "SyncCastAudio_UID"
#define kTest_ObjectID_PlugIn       1
#define kTest_ObjectID_Device       2
#define kTest_ObjectID_Stream       3
#define kTest_ObjectID_Volume       4
#define kTest_ObjectID_Mute         5
#define kTest_RingBufferSize        19200
#define kTest_DefaultSampleRate     48000.0

typedef void* (*SyncCastAudio_CreateProc)(CFAllocatorRef, CFUUIDRef);

static AudioServerPlugInDriverRef   gDriver             = NULL;
static unsigned long                gChecks             = 0;
static unsigned long                gFailures           = 0;

// Storage stub -----------------------------------------------------------

static pthread_mutex_t              gStorageMutex       = PTHREAD_MUTEX_INITIALIZER;
static CFMutableDictionaryRef       gStorage            = NULL;
static unsigned long                gWriteCount         = 0;
static unsigned long                gPropertiesChanged  = 0;

#define CHECK(cond, fmt, ...)                                                   \
    do {                                                                        \
        ++gChecks;                                                              \
        if(!(cond))                                                             \
        {                                                                       \
            ++gFailures;                                                        \
            fprintf(stderr, "FAIL %s:%d: " fmt "\n", __FILE__, __LINE__, ##__VA_ARGS__); \
        }                                                                       \
    } while(0)

static OSStatus Host_PropertiesChanged(AudioServerPlugInHostRef inHost, AudioObjectID inObjectID, UInt32 inNumberAddresses, const AudioObjectPropertyAddress* inAddresses)
{
    (void)inHost; (void)inObjectID;
    // Read every address the driver claims changed: if it ever hands back a
    // short array, ASan reports it here rather than in some later client.
    for(UInt32 i = 0; i < inNumberAddresses; ++i)
    {
        volatile AudioObjectPropertySelector theSelector = inAddresses[i].mSelector;
        (void)theSelector;
    }
    __sync_fetch_and_add(&gPropertiesChanged, 1);
    return 0;
}

static OSStatus Host_CopyFromStorage(AudioServerPlugInHostRef inHost, CFStringRef inKey, CFPropertyListRef* outData)
{
    (void)inHost;
    if(outData == NULL) { return kAudioHardwareIllegalOperationError; }
    *outData = NULL;
    pthread_mutex_lock(&gStorageMutex);
    if((gStorage != NULL) && (inKey != NULL))
    {
        CFPropertyListRef theValue = CFDictionaryGetValue(gStorage, inKey);
        if(theValue != NULL) { *outData = CFRetain(theValue); }
    }
    pthread_mutex_unlock(&gStorageMutex);
    return (*outData != NULL) ? 0 : kAudioHardwareUnknownPropertyError;
}

static OSStatus Host_WriteToStorage(AudioServerPlugInHostRef inHost, CFStringRef inKey, CFPropertyListRef inData)
{
    (void)inHost;
    if((inKey == NULL) || (inData == NULL)) { return kAudioHardwareIllegalOperationError; }
    pthread_mutex_lock(&gStorageMutex);
    if(gStorage != NULL) { CFDictionarySetValue(gStorage, inKey, inData); }
    ++gWriteCount;
    pthread_mutex_unlock(&gStorageMutex);
    return 0;
}

static OSStatus Host_DeleteFromStorage(AudioServerPlugInHostRef inHost, CFStringRef inKey)
{
    (void)inHost;
    pthread_mutex_lock(&gStorageMutex);
    if((gStorage != NULL) && (inKey != NULL)) { CFDictionaryRemoveValue(gStorage, inKey); }
    pthread_mutex_unlock(&gStorageMutex);
    return 0;
}

// The HAL answers a configuration-change request by stopping IO and calling
// PerformDeviceConfigurationChange. Doing the same here is what makes the rate
// path testable at all.
static OSStatus Host_RequestDeviceConfigurationChange(AudioServerPlugInHostRef inHost, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo)
{
    (void)inHost;
    return (*gDriver)->PerformDeviceConfigurationChange(gDriver, inDeviceObjectID, inChangeAction, inChangeInfo);
}

static AudioServerPlugInHostInterface gHostInterface =
{
    Host_PropertiesChanged,
    Host_CopyFromStorage,
    Host_WriteToStorage,
    Host_DeleteFromStorage,
    Host_RequestDeviceConfigurationChange
};

static unsigned long StorageWriteCount(void)
{
    pthread_mutex_lock(&gStorageMutex);
    unsigned long theAnswer = gWriteCount;
    pthread_mutex_unlock(&gStorageMutex);
    return theAnswer;
}

// Sweep ------------------------------------------------------------------

typedef struct { AudioObjectPropertySelector mSelector; const char* mName; } TestSelector;

static const TestSelector kSelectors[] =
{
    { kAudioObjectPropertyBaseClass,                        "BaseClass" },
    { kAudioObjectPropertyClass,                            "Class" },
    { kAudioObjectPropertyOwner,                            "Owner" },
    { kAudioObjectPropertyName,                             "Name" },
    { kAudioObjectPropertyManufacturer,                     "Manufacturer" },
    { kAudioObjectPropertyOwnedObjects,                     "OwnedObjects" },
    { kAudioObjectPropertyControlList,                      "ControlList" },
    { kAudioPlugInPropertyBoxList,                          "BoxList" },
    { kAudioPlugInPropertyTranslateUIDToBox,                "TranslateUIDToBox" },
    { kAudioPlugInPropertyDeviceList,                       "DeviceList" },
    { kAudioPlugInPropertyTranslateUIDToDevice,             "TranslateUIDToDevice" },
    { kAudioPlugInPropertyResourceBundle,                   "ResourceBundle" },
    { kAudioDevicePropertyDeviceUID,                        "DeviceUID" },
    { kAudioDevicePropertyModelUID,                         "ModelUID" },
    { kAudioDevicePropertyTransportType,                    "TransportType" },
    { kAudioDevicePropertyRelatedDevices,                   "RelatedDevices" },
    { kAudioDevicePropertyClockDomain,                      "ClockDomain" },
    { kAudioDevicePropertyDeviceIsAlive,                    "DeviceIsAlive" },
    { kAudioDevicePropertyDeviceIsRunning,                  "DeviceIsRunning" },
    { kAudioDevicePropertyDeviceCanBeDefaultDevice,         "CanBeDefault" },
    { kAudioDevicePropertyDeviceCanBeDefaultSystemDevice,   "CanBeDefaultSystem" },
    { kAudioDevicePropertyLatency,                          "Latency" },
    { kAudioDevicePropertyStreams,                          "Streams" },
    { kAudioDevicePropertySafetyOffset,                     "SafetyOffset" },
    { kAudioDevicePropertyNominalSampleRate,                "NominalSampleRate" },
    { kAudioDevicePropertyAvailableNominalSampleRates,      "AvailableRates" },
    { kAudioDevicePropertyIsHidden,                         "IsHidden" },
    { kAudioDevicePropertyZeroTimeStampPeriod,              "ZeroTimeStampPeriod" },
    { kAudioDevicePropertyPreferredChannelsForStereo,       "PreferredChannelsForStereo" },
    { kAudioDevicePropertyPreferredChannelLayout,           "PreferredChannelLayout" },
    { kAudioStreamPropertyIsActive,                         "IsActive" },
    { kAudioStreamPropertyDirection,                        "Direction" },
    { kAudioStreamPropertyTerminalType,                     "TerminalType" },
    { kAudioStreamPropertyStartingChannel,                  "StartingChannel" },
    { kAudioStreamPropertyLatency,                          "StreamLatency" },
    { kAudioStreamPropertyVirtualFormat,                    "VirtualFormat" },
    { kAudioStreamPropertyPhysicalFormat,                   "PhysicalFormat" },
    { kAudioStreamPropertyAvailableVirtualFormats,          "AvailableVirtualFormats" },
    { kAudioStreamPropertyAvailablePhysicalFormats,         "AvailablePhysicalFormats" },
    { kAudioControlPropertyScope,                           "ControlScope" },
    { kAudioControlPropertyElement,                         "ControlElement" },
    { kAudioLevelControlPropertyScalarValue,                "ScalarValue" },
    { kAudioLevelControlPropertyDecibelValue,               "DecibelValue" },
    { kAudioLevelControlPropertyDecibelRange,               "DecibelRange" },
    { kAudioLevelControlPropertyConvertScalarToDecibels,    "ConvertScalarToDecibels" },
    { kAudioLevelControlPropertyConvertDecibelsToScalar,    "ConvertDecibelsToScalar" },
    { kAudioBooleanControlPropertyValue,                    "BooleanValue" },
    { kAudioSelectorControlPropertyCurrentItem,             "CurrentItem (unsupported)" },
    { 'zzzz',                                               "bogus selector" },
};

static const AudioObjectPropertyScope kScopes[3] =
{
    kAudioObjectPropertyScopeGlobal,
    kAudioObjectPropertyScopeInput,
    kAudioObjectPropertyScopeOutput
};

/// One GetPropertyData call against a heap buffer of exactly inDataSize bytes.
static void ProbeGet(AudioObjectID inObjectID, const AudioObjectPropertyAddress* inAddress, UInt32 inDataSize, const char* inWhat, const char* inName)
{
    // malloc(0) may return a non-NULL zero-length block; ask for one byte so
    // there is always a valid pointer, but still tell the driver zero.
    size_t theAllocation = (inDataSize > 0) ? inDataSize : 1;
    unsigned char* theBuffer = (unsigned char*)malloc(theAllocation);
    if(theBuffer == NULL) { return; }
    memset(theBuffer, 0xAA, theAllocation);

    UInt32 theOutSize = 0xDEADBEEF;
    OSStatus theStatus = (*gDriver)->GetPropertyData(gDriver, inObjectID, 0, inAddress, 0, NULL, inDataSize, &theOutSize, theBuffer);
    if(theStatus == 0)
    {
        ++gChecks;
        if(theOutSize > inDataSize)
        {
            ++gFailures;
            fprintf(stderr, "FAIL object %u %s (%s buffer, %u bytes): success but reported %u bytes written\n",
                    inObjectID, inName, inWhat, inDataSize, theOutSize);
        }
    }
    free(theBuffer);
}

static void SweepProperties(void)
{
    const AudioObjectID theObjects[] = { 0, 1, 2, 3, 4, 5, 6 };
    unsigned long theSupported = 0;

    for(size_t o = 0; o < sizeof(theObjects) / sizeof(theObjects[0]); ++o)
    {
        AudioObjectID theObject = theObjects[o];
        Boolean theIsKnown = (theObject >= kTest_ObjectID_PlugIn) && (theObject <= kTest_ObjectID_Mute);

        for(size_t s = 0; s < 3; ++s)
        {
            for(size_t p = 0; p < sizeof(kSelectors) / sizeof(kSelectors[0]); ++p)
            {
                AudioObjectPropertyAddress theAddress;
                theAddress.mSelector = kSelectors[p].mSelector;
                theAddress.mScope = kScopes[s];
                theAddress.mElement = kAudioObjectPropertyElementMain;

                Boolean theHas = (*gDriver)->HasProperty(gDriver, theObject, 0, &theAddress);
                if(!theIsKnown)
                {
                    CHECK(!theHas, "unknown object %u claims to have %s", theObject, kSelectors[p].mName);
                }

                Boolean theSettable = false;
                OSStatus theSettableStatus = (*gDriver)->IsPropertySettable(gDriver, theObject, 0, &theAddress, &theSettable);
                if(!theIsKnown)
                {
                    CHECK(theSettableStatus == kAudioHardwareBadObjectError,
                          "IsPropertySettable on unknown object %u returned %d, expected BadObject", theObject, (int)theSettableStatus);
                }

                UInt32 theSize = 0;
                OSStatus theSizeStatus = (*gDriver)->GetPropertyDataSize(gDriver, theObject, 0, &theAddress, 0, NULL, &theSize);
                if(!theIsKnown)
                {
                    CHECK(theSizeStatus == kAudioHardwareBadObjectError,
                          "GetPropertyDataSize on unknown object %u returned %d, expected BadObject", theObject, (int)theSizeStatus);
                    continue;
                }

                // The contract clients rely on: HasProperty and
                // GetPropertyDataSize must agree about what exists.
                CHECK(theHas == (theSizeStatus == 0),
                      "object %u scope %.4s %s: HasProperty=%d but GetPropertyDataSize=%d",
                      theObject, (const char*)&theAddress.mScope, kSelectors[p].mName, (int)theHas, (int)theSizeStatus);

                if(theSizeStatus != 0) { continue; }
                ++theSupported;

                ProbeGet(theObject, &theAddress, theSize, "exact", kSelectors[p].mName);
                if(theSize > 1) { ProbeGet(theObject, &theAddress, theSize - 1, "short", kSelectors[p].mName); }
                ProbeGet(theObject, &theAddress, 0, "zero", kSelectors[p].mName);
            }
        }
    }

    printf("  swept %zu selectors x 3 scopes x 7 object ids; %lu supported (object, scope) pairs\n",
           sizeof(kSelectors) / sizeof(kSelectors[0]), theSupported);
}

// Qualifiers -------------------------------------------------------------

static void TestQualifiers(void)
{
    AudioObjectPropertyAddress theAddress =
    {
        kAudioPlugInPropertyTranslateUIDToDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectID theResult = 0xFFFFFFFF;
    UInt32 theOutSize = 0;
    OSStatus theStatus;

    CFStringRef theMatchingUID = CFSTR(kTest_Device_UID);
    theStatus = (*gDriver)->GetPropertyData(gDriver, kTest_ObjectID_PlugIn, 0, &theAddress,
                                            sizeof(CFStringRef), &theMatchingUID,
                                            sizeof(theResult), &theOutSize, &theResult);
    CHECK((theStatus == 0) && (theResult == kTest_ObjectID_Device),
          "TranslateUIDToDevice(matching) -> status %d, id %u", (int)theStatus, theResult);

    CFStringRef theOtherUID = CFSTR("BlackHole2ch_UID");
    theStatus = (*gDriver)->GetPropertyData(gDriver, kTest_ObjectID_PlugIn, 0, &theAddress,
                                            sizeof(CFStringRef), &theOtherUID,
                                            sizeof(theResult), &theOutSize, &theResult);
    CHECK((theStatus == 0) && (theResult == kAudioObjectUnknown),
          "TranslateUIDToDevice(other) -> status %d, id %u", (int)theStatus, theResult);

    // The regression: right size, NULL pointer. Must not dereference NULL.
    theStatus = (*gDriver)->GetPropertyData(gDriver, kTest_ObjectID_PlugIn, 0, &theAddress,
                                            sizeof(CFStringRef), NULL,
                                            sizeof(theResult), &theOutSize, &theResult);
    CHECK(theStatus != 0, "TranslateUIDToDevice(NULL qualifier) -> status %d, expected an error", (int)theStatus);

    theStatus = (*gDriver)->GetPropertyData(gDriver, kTest_ObjectID_PlugIn, 0, &theAddress,
                                            1, &theMatchingUID,
                                            sizeof(theResult), &theOutSize, &theResult);
    CHECK(theStatus == kAudioHardwareBadPropertySizeError,
          "TranslateUIDToDevice(wrong qualifier size) -> status %d, expected BadPropertySize", (int)theStatus);
}

// Setters ----------------------------------------------------------------

static OSStatus SetFloat32(AudioObjectID inObjectID, AudioObjectPropertySelector inSelector, Float32 inValue)
{
    AudioObjectPropertyAddress theAddress = { inSelector, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
    return (*gDriver)->SetPropertyData(gDriver, inObjectID, 0, &theAddress, 0, NULL, sizeof(inValue), &inValue);
}

static OSStatus SetUInt32(AudioObjectID inObjectID, AudioObjectPropertySelector inSelector, UInt32 inValue)
{
    AudioObjectPropertyAddress theAddress = { inSelector, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
    return (*gDriver)->SetPropertyData(gDriver, inObjectID, 0, &theAddress, 0, NULL, sizeof(inValue), &inValue);
}

static Float32 GetVolumeScalar(void)
{
    AudioObjectPropertyAddress theAddress = { kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
    Float32 theValue = -1.0f;
    UInt32 theOutSize = 0;
    (*gDriver)->GetPropertyData(gDriver, kTest_ObjectID_Volume, 0, &theAddress, 0, NULL, sizeof(theValue), &theOutSize, &theValue);
    return theValue;
}

static Float64 GetNominalRate(void)
{
    AudioObjectPropertyAddress theAddress = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    Float64 theValue = 0.0;
    UInt32 theOutSize = 0;
    (*gDriver)->GetPropertyData(gDriver, kTest_ObjectID_Device, 0, &theAddress, 0, NULL, sizeof(theValue), &theOutSize, &theValue);
    return theValue;
}

static void FillValidFormat(AudioStreamBasicDescription* outFormat, Float64 inRate)
{
    memset(outFormat, 0, sizeof(*outFormat));
    outFormat->mSampleRate = inRate;
    outFormat->mFormatID = kAudioFormatLinearPCM;
    outFormat->mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    outFormat->mBytesPerPacket = 8;
    outFormat->mFramesPerPacket = 1;
    outFormat->mBytesPerFrame = 8;
    outFormat->mChannelsPerFrame = 2;
    outFormat->mBitsPerChannel = 32;
}

static OSStatus SetFormat(const AudioStreamBasicDescription* inFormat)
{
    AudioObjectPropertyAddress theAddress = { kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
    return (*gDriver)->SetPropertyData(gDriver, kTest_ObjectID_Stream, 0, &theAddress, 0, NULL, sizeof(*inFormat), inFormat);
}

static void TestSetters(void)
{
    OSStatus theStatus;

    // Volume, both representations.
    theStatus = SetFloat32(kTest_ObjectID_Volume, kAudioLevelControlPropertyScalarValue, 0.25f);
    CHECK(theStatus == 0, "set scalar 0.25 -> %d", (int)theStatus);
    CHECK(GetVolumeScalar() == 0.25f, "scalar read back as %f, expected 0.25", (double)GetVolumeScalar());

    theStatus = SetFloat32(kTest_ObjectID_Volume, kAudioLevelControlPropertyScalarValue, 7.0f);
    CHECK((theStatus == 0) && (GetVolumeScalar() == 1.0f), "out-of-range scalar 7.0 must clamp to 1.0, got %f", (double)GetVolumeScalar());

    theStatus = SetFloat32(kTest_ObjectID_Volume, kAudioLevelControlPropertyDecibelValue, -63.5f);
    CHECK((theStatus == 0) && (GetVolumeScalar() == 0.0f), "dB -63.5 must map to scalar 0, got %f", (double)GetVolumeScalar());

    {
        // A genuinely wrong size — UInt32 and Float32 are both 4 bytes, so a
        // "wrong type" set would sail through the size check.
        AudioObjectPropertyAddress theScalar = { kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
        unsigned char theShortValue[2] = { 0, 0 };
        theStatus = (*gDriver)->SetPropertyData(gDriver, kTest_ObjectID_Volume, 0, &theScalar, 0, NULL, sizeof(theShortValue), theShortValue);
        CHECK(theStatus == kAudioHardwareBadPropertySizeError, "wrong-size volume set -> %d, expected BadPropertySize", (int)theStatus);
    }

    // Mute.
    theStatus = SetUInt32(kTest_ObjectID_Mute, kAudioBooleanControlPropertyValue, 1);
    CHECK(theStatus == 0, "set mute -> %d", (int)theStatus);

    // IsActive: not settable, and the set must be refused.
    AudioObjectPropertyAddress theActive = { kAudioStreamPropertyIsActive, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
    Boolean theSettable = true;
    theStatus = (*gDriver)->IsPropertySettable(gDriver, kTest_ObjectID_Stream, 0, &theActive, &theSettable);
    CHECK((theStatus == 0) && !theSettable, "IsActive settable=%d, expected false", (int)theSettable);
    theStatus = SetUInt32(kTest_ObjectID_Stream, kAudioStreamPropertyIsActive, 0);
    CHECK(theStatus == kAudioHardwareUnsupportedOperationError,
          "set IsActive -> %d, expected UnsupportedOperation", (int)theStatus);

    // Format: the valid one at the current rate, then each invalid variant.
    AudioStreamBasicDescription theFormat;
    FillValidFormat(&theFormat, kTest_DefaultSampleRate);
    CHECK(SetFormat(&theFormat) == 0, "valid format was refused");

    struct { const char* mName; void (*mBreak)(AudioStreamBasicDescription*); } theBreakers[] = {
        { "non-interleaved",    NULL },
        { "FramesPerPacket 2",  NULL },
        { "BytesPerFrame 4",    NULL },
        { "BytesPerPacket 4",   NULL },
        { "24-bit",             NULL },
        { "mono",               NULL },
        { "integer",            NULL },
        { "rate 22050",         NULL },
    };
    for(size_t i = 0; i < sizeof(theBreakers) / sizeof(theBreakers[0]); ++i)
    {
        FillValidFormat(&theFormat, kTest_DefaultSampleRate);
        switch(i)
        {
            case 0: theFormat.mFormatFlags |= kAudioFormatFlagIsNonInterleaved; break;
            case 1: theFormat.mFramesPerPacket = 2; break;
            case 2: theFormat.mBytesPerFrame = 4; break;
            case 3: theFormat.mBytesPerPacket = 4; break;
            case 4: theFormat.mBitsPerChannel = 24; break;
            case 5: theFormat.mChannelsPerFrame = 1; break;
            case 6: theFormat.mFormatFlags &= (UInt32)~kAudioFormatFlagIsFloat; break;
            case 7: theFormat.mSampleRate = 22050.0; break;
            default: break;
        }
        theStatus = SetFormat(&theFormat);
        CHECK(theStatus == kAudioDeviceUnsupportedFormatError,
              "format '%s' accepted with status %d, expected UnsupportedFormat", theBreakers[i].mName, (int)theStatus);
    }

    // Sample rate: a supported one goes through the host round trip, an
    // unsupported one is an illegal value (not a bad object).
    AudioObjectPropertyAddress theRateAddress = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    Float64 theRate = 96000.0;
    theStatus = (*gDriver)->SetPropertyData(gDriver, kTest_ObjectID_Device, 0, &theRateAddress, 0, NULL, sizeof(theRate), &theRate);
    CHECK((theStatus == 0) && (GetNominalRate() == 96000.0), "set rate 96000 -> %d, rate now %f", (int)theStatus, GetNominalRate());

    theRate = 12345.0;
    theStatus = (*gDriver)->SetPropertyData(gDriver, kTest_ObjectID_Device, 0, &theRateAddress, 0, NULL, sizeof(theRate), &theRate);
    CHECK(theStatus == kAudioHardwareIllegalOperationError, "set rate 12345 -> %d, expected IllegalOperation", (int)theStatus);

    theStatus = (*gDriver)->PerformDeviceConfigurationChange(gDriver, kTest_ObjectID_Device, (UInt64)12345, NULL);
    CHECK(theStatus == kAudioHardwareIllegalOperationError,
          "PerformDeviceConfigurationChange(12345) -> %d, expected IllegalOperation", (int)theStatus);

    // Back to the pipeline rate for the timeline test.
    theRate = kTest_DefaultSampleRate;
    (*gDriver)->SetPropertyData(gDriver, kTest_ObjectID_Device, 0, &theRateAddress, 0, NULL, sizeof(theRate), &theRate);
    CHECK(GetNominalRate() == kTest_DefaultSampleRate, "rate did not return to 48000 (%f)", GetNominalRate());
}

// Persistence ------------------------------------------------------------

static void TestPersistenceCoalescing(void)
{
    // Settle: force whatever is pending out so the burst starts from a known
    // write count and a fresh rate-limit window.
    (*gDriver)->StartIO(gDriver, kTest_ObjectID_Device, 1);
    (*gDriver)->StopIO(gDriver, kTest_ObjectID_Device, 1);

    unsigned long theBefore = StorageWriteCount();
    const int kSteps = 200;
    for(int i = 0; i < kSteps; ++i)
    {
        SetFloat32(kTest_ObjectID_Volume, kAudioLevelControlPropertyScalarValue, (Float32)i / (Float32)kSteps);
    }
    unsigned long theBurstWrites = StorageWriteCount() - theBefore;
    printf("  %d volume steps in one burst produced %lu storage writes\n", kSteps, theBurstWrites);
    // The burst runs well inside one 500 ms window, so the honest expectation
    // is 0 or 1 writes; anything per-step means the coalescing is gone.
    CHECK(theBurstWrites <= 2, "a burst of %d volume steps wrote storage %lu times; coalescing is not working", kSteps, theBurstWrites);

    // ...and once the window has passed, the next step DOES reach storage:
    // coalescing must delay writes, not drop them.
    usleep(600000);
    unsigned long theBeforeLate = StorageWriteCount();
    SetFloat32(kTest_ObjectID_Volume, kAudioLevelControlPropertyScalarValue, 0.4321f);
    unsigned long theLateWrites = StorageWriteCount() - theBeforeLate;
    printf("  one more step after a 600 ms pause produced %lu storage writes\n", theLateWrites);
    CHECK(theLateWrites == 1, "a step after the rate-limit window produced %lu writes, expected 1", theLateWrites);

    // StopIO on the last client must flush the final value unconditionally.
    Float32 theFinal = 0.6875f;
    SetFloat32(kTest_ObjectID_Volume, kAudioLevelControlPropertyScalarValue, theFinal);
    (*gDriver)->StartIO(gDriver, kTest_ObjectID_Device, 1);
    unsigned long theBeforeStop = StorageWriteCount();
    (*gDriver)->StopIO(gDriver, kTest_ObjectID_Device, 1);
    CHECK(StorageWriteCount() > theBeforeStop, "StopIO did not flush the pending volume");

    pthread_mutex_lock(&gStorageMutex);
    CFNumberRef theStored = (CFNumberRef)CFDictionaryGetValue(gStorage, CFSTR("volumeScalar"));
    Float32 theStoredValue = -1.0f;
    if(theStored != NULL) { CFNumberGetValue(theStored, kCFNumberFloat32Type, &theStoredValue); }
    pthread_mutex_unlock(&gStorageMutex);
    CHECK(theStoredValue == theFinal, "storage holds %f after StopIO, expected %f", (double)theStoredValue, (double)theFinal);

    // Mute is forced, not coalesced: two toggles, two writes.
    unsigned long theBeforeMute = StorageWriteCount();
    SetUInt32(kTest_ObjectID_Mute, kAudioBooleanControlPropertyValue, 0);
    SetUInt32(kTest_ObjectID_Mute, kAudioBooleanControlPropertyValue, 1);
    CHECK((StorageWriteCount() - theBeforeMute) >= 2, "mute toggles were coalesced; they must not be");
}

// Timeline ---------------------------------------------------------------

static void TestZeroTimeStamps(double inSeconds)
{
    OSStatus theStatus = (*gDriver)->StartIO(gDriver, kTest_ObjectID_Device, 1);
    CHECK(theStatus == 0, "StartIO -> %d", (int)theStatus);

    struct mach_timebase_info theTimeBase;
    mach_timebase_info(&theTimeBase);
    double theTicksPerSecond = 1e9 * (double)theTimeBase.denom / (double)theTimeBase.numer;

    UInt64 theStart = mach_absolute_time();
    UInt64 theDeadline = theStart + (UInt64)(inSeconds * theTicksPerSecond);

    Float64 thePrevSampleTime = -1.0;
    UInt64 thePrevHostTime = 0;
    unsigned long theSteps = 0;
    unsigned long thePolls = 0;
    double theWorstPeriodError = 0.0;

    while(mach_absolute_time() < theDeadline)
    {
        Float64 theSampleTime = 0.0;
        UInt64 theHostTime = 0;
        UInt64 theSeed = 0;
        theStatus = (*gDriver)->GetZeroTimeStamp(gDriver, kTest_ObjectID_Device, 1, &theSampleTime, &theHostTime, &theSeed);
        ++thePolls;
        if(theStatus != 0)
        {
            CHECK(false, "GetZeroTimeStamp -> %d", (int)theStatus);
            break;
        }

        if(thePrevSampleTime >= 0.0)
        {
            Float64 theDelta = theSampleTime - thePrevSampleTime;
            CHECK((theDelta == 0.0) || (theDelta == (Float64)kTest_RingBufferSize),
                  "sample time moved by %f, expected 0 or %d", theDelta, kTest_RingBufferSize);
            if(theDelta > 0.0)
            {
                ++theSteps;
                double thePeriod = (double)(theHostTime - thePrevHostTime) / theTicksPerSecond;
                double theExpected = (double)kTest_RingBufferSize / kTest_DefaultSampleRate;
                double theError = thePeriod - theExpected;
                if(theError < 0.0) { theError = -theError; }
                if(theError > theWorstPeriodError) { theWorstPeriodError = theError; }
            }
            else
            {
                CHECK(theHostTime == thePrevHostTime, "host time moved while sample time did not");
            }
        }
        thePrevSampleTime = theSampleTime;
        thePrevHostTime = theHostTime;
        usleep(5000);
    }

    double theExpectedSteps = inSeconds / ((double)kTest_RingBufferSize / kTest_DefaultSampleRate);
    printf("  %.0f s of GetZeroTimeStamp: %lu polls, %lu steps of %d frames (expected ~%.0f), worst period error %.6f s\n",
           inSeconds, thePolls, theSteps, kTest_RingBufferSize, theExpectedSteps, theWorstPeriodError);
    CHECK(theSteps >= (unsigned long)(theExpectedSteps - 1.0),
          "only %lu timeline steps in %.0f s, expected about %.0f", theSteps, inSeconds, theExpectedSteps);
    CHECK(theWorstPeriodError < 0.005, "period drifted by %.6f s, expected under 5 ms", theWorstPeriodError);

    theStatus = (*gDriver)->StopIO(gDriver, kTest_ObjectID_Device, 1);
    CHECK(theStatus == 0, "StopIO -> %d", (int)theStatus);
}

// Concurrency ------------------------------------------------------------

// Atomic, not merely volatile: TSan is right to call a plain flag a race,
// and a race in the harness would mask one in the driver.
static _Atomic int gStopThreads = 0;

static void* IOThread(void* inArg)
{
    (void)inArg;
    unsigned long theCount = 0;
    while(!gStopThreads)
    {
        Float64 theSampleTime = 0.0;
        UInt64 theHostTime = 0, theSeed = 0;
        (*gDriver)->GetZeroTimeStamp(gDriver, kTest_ObjectID_Device, 1, &theSampleTime, &theHostTime, &theSeed);
        ++theCount;
    }
    return (void*)theCount;
}

static void* PropertyThread(void* inArg)
{
    long theIndex = (long)inArg;
    unsigned long theCount = 0;
    while(!gStopThreads)
    {
        SetFloat32(kTest_ObjectID_Volume, kAudioLevelControlPropertyScalarValue, (Float32)((theCount % 100) / 100.0));
        (void)GetVolumeScalar();
        (void)GetNominalRate();
        if((theIndex == 0) && ((theCount % 64) == 0))
        {
            SetUInt32(kTest_ObjectID_Mute, kAudioBooleanControlPropertyValue, (UInt32)(theCount & 1));
        }
        ++theCount;
    }
    return (void*)theCount;
}

static void TestConcurrency(double inSeconds)
{
    (*gDriver)->StartIO(gDriver, kTest_ObjectID_Device, 1);
    gStopThreads = 0;

    pthread_t theIOThread;
    pthread_t thePropertyThreads[4];
    pthread_create(&theIOThread, NULL, IOThread, NULL);
    for(long i = 0; i < 4; ++i) { pthread_create(&thePropertyThreads[i], NULL, PropertyThread, (void*)i); }

    usleep((useconds_t)(inSeconds * 1000000.0));
    gStopThreads = 1;

    void* theIOCount = NULL;
    pthread_join(theIOThread, &theIOCount);
    unsigned long thePropertyCount = 0;
    for(int i = 0; i < 4; ++i)
    {
        void* theCount = NULL;
        pthread_join(thePropertyThreads[i], &theCount);
        thePropertyCount += (unsigned long)theCount;
    }
    (*gDriver)->StopIO(gDriver, kTest_ObjectID_Device, 1);

    printf("  %.0f s of contention: %lu GetZeroTimeStamp calls against %lu property operations\n",
           inSeconds, (unsigned long)theIOCount, thePropertyCount);
    CHECK((unsigned long)theIOCount > 0, "the IO thread made no progress");
    CHECK(thePropertyCount > 0, "the property threads made no progress");
}

// ------------------------------------------------------------------------

int main(int argc, const char* argv[])
{
    if(argc < 2)
    {
        fprintf(stderr, "usage: %s <path to SyncCastAudio Mach-O> [io seconds]\n", argv[0]);
        return 2;
    }
    double theIOSeconds = (argc > 2) ? atof(argv[2]) : 2.0;

    void* theHandle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if(theHandle == NULL)
    {
        fprintf(stderr, "dlopen failed: %s\n", dlerror());
        return 2;
    }

    SyncCastAudio_CreateProc theFactory = (SyncCastAudio_CreateProc)dlsym(theHandle, "SyncCastAudio_Create");
    if(theFactory == NULL)
    {
        fprintf(stderr, "SyncCastAudio_Create not exported: %s\n", dlerror());
        return 2;
    }

    printf("loaded %s\n", argv[1]);

    // The factory contract: the wrong type, and a NULL type, must both be
    // refused without crashing.
    CHECK(theFactory(NULL, kAudioServerPlugInDriverInterfaceUUID) == NULL, "factory returned a driver for the wrong type UUID");
    CHECK(theFactory(NULL, NULL) == NULL, "factory returned a driver for a NULL type UUID");

    gDriver = (AudioServerPlugInDriverRef)theFactory(NULL, kAudioServerPlugInTypeUUID);
    if(gDriver == NULL)
    {
        fprintf(stderr, "factory refused kAudioServerPlugInTypeUUID\n");
        return 2;
    }

    gStorage = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    OSStatus theStatus = (*gDriver)->Initialize(gDriver, &gHostInterface);
    CHECK(theStatus == 0, "Initialize -> %d", (int)theStatus);

    ULONG theRefCount = (*gDriver)->AddRef(gDriver);
    CHECK(theRefCount > 0, "AddRef returned %lu", (unsigned long)theRefCount);
    (*gDriver)->Release(gDriver);

    printf("[1/6] property sweep\n");        SweepProperties();
    printf("[2/6] qualifiers\n");            TestQualifiers();
    printf("[3/6] setters\n");               TestSetters();
    printf("[4/6] persistence coalescing\n");TestPersistenceCoalescing();
    printf("[5/6] zero timestamps\n");       TestZeroTimeStamps(theIOSeconds);
    printf("[6/6] concurrency\n");           TestConcurrency(1.0);

    printf("\n%lu checks, %lu failures, %lu PropertiesChanged notifications, %lu storage writes\n",
           gChecks, gFailures, gPropertiesChanged, StorageWriteCount());

    if(gStorage != NULL) { CFRelease(gStorage); gStorage = NULL; }
    // Deliberately NOT dlclose(): the driver keeps global state and the HAL
    // never unloads it either.
    return (gFailures == 0) ? 0 : 1;
}
