//
//  SyncCastAudioPlugIn.c
//  SyncCastAudio.driver
//
//  The COM plumbing, the driver interface table, and the IO path.
//  Property handling lives in SyncCastAudioProperties.c.
//
//  See SyncCastAudio.h for what this driver is and why it exists.
//

#include "SyncCastAudio.h"

#include <CoreFoundation/CoreFoundation.h>

#pragma mark - State

pthread_mutex_t             gPlugIn_StateMutex          = PTHREAD_MUTEX_INITIALIZER;
pthread_mutex_t             gDevice_IOMutex             = PTHREAD_MUTEX_INITIALIZER;
AudioServerPlugInHostRef    gPlugIn_Host                = NULL;
UInt32                      gPlugIn_RefCount            = 0;

// gPlugIn_StateMutex
Float64                     gDevice_SampleRate          = kDevice_DefaultSampleRate;
UInt64                      gDevice_IORunningCounter    = 0;

// gDevice_IOMutex
Float64                     gDevice_HostTicksPerFrame   = 0.0;
UInt64                      gDevice_NumberTimeStamps    = 0;
Float64                     gDevice_AnchorSampleTime    = 0.0;
UInt64                      gDevice_AnchorHostTime      = 0;

// Full scale, unmuted: the device must not silence a machine that has just
// selected it. macOS restores the user's last level for a device it knows.
Float32                     gVolume_Output_Scalar       = 1.0f;
bool                        gMute_Output_Value          = false;

#pragma mark - Volume law (pure, mirrored by SystemSinkVolumeLaw.swift)

Float32 SyncCastAudio_ClampScalar(Float32 inScalar)
{
    if(!(inScalar > 0.0f))  { return 0.0f; }   // also catches NaN
    if(inScalar > 1.0f)     { return 1.0f; }
    return inScalar;
}

Float32 SyncCastAudio_ScalarToDecibels(Float32 inScalar)
{
    // dB(s) = minDB * (1 - s): linear in decibels, the curve measured on the
    // built-in speakers. See the header for the measured points.
    return kVolume_MinDB * (1.0f - SyncCastAudio_ClampScalar(inScalar));
}

Float32 SyncCastAudio_DecibelsToScalar(Float32 inDecibels)
{
    Float32 theDecibels = inDecibels;
    if(theDecibels < kVolume_MinDB) { theDecibels = kVolume_MinDB; }
    if(theDecibels > kVolume_MaxDB) { theDecibels = kVolume_MaxDB; }
    return SyncCastAudio_ClampScalar(1.0f + (theDecibels / (-kVolume_MinDB)));
}

#pragma mark - Timeline

// The timeline is entirely derived from the host clock: no hardware, so a
// "zero timestamp" is just the anchor plus a whole number of ring-buffer
// periods. Re-derived on every rate change and re-anchored whenever IO starts.
void SyncCastAudio_ResetTimeline(Float64 inSampleRate)
{
    struct mach_timebase_info theTimeBaseInfo;
    mach_timebase_info(&theTimeBaseInfo);
    Float64 theHostClockFrequency = (Float64)theTimeBaseInfo.denom / (Float64)theTimeBaseInfo.numer;
    theHostClockFrequency *= 1000000000.0;

    pthread_mutex_lock(&gDevice_IOMutex);
    gDevice_HostTicksPerFrame = theHostClockFrequency / inSampleRate;
    gDevice_NumberTimeStamps = 0;
    gDevice_AnchorSampleTime = 0.0;
    gDevice_AnchorHostTime = mach_absolute_time();
    pthread_mutex_unlock(&gDevice_IOMutex);
}

#pragma mark - Prototypes

static HRESULT      SyncCastAudio_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG        SyncCastAudio_AddRef(void* inDriver);
static ULONG        SyncCastAudio_Release(void* inDriver);
static OSStatus     SyncCastAudio_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus     SyncCastAudio_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus     SyncCastAudio_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus     SyncCastAudio_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus     SyncCastAudio_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus     SyncCastAudio_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static OSStatus     SyncCastAudio_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static OSStatus     SyncCastAudio_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus     SyncCastAudio_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus     SyncCastAudio_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus     SyncCastAudio_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
static OSStatus     SyncCastAudio_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
static OSStatus     SyncCastAudio_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer);
static OSStatus     SyncCastAudio_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

#pragma mark - The interface

static AudioServerPlugInDriverInterface gAudioServerPlugInDriverInterface =
{
    NULL,
    SyncCastAudio_QueryInterface,
    SyncCastAudio_AddRef,
    SyncCastAudio_Release,
    SyncCastAudio_Initialize,
    SyncCastAudio_CreateDevice,
    SyncCastAudio_DestroyDevice,
    SyncCastAudio_AddDeviceClient,
    SyncCastAudio_RemoveDeviceClient,
    SyncCastAudio_PerformDeviceConfigurationChange,
    SyncCastAudio_AbortDeviceConfigurationChange,
    SyncCastAudio_HasProperty,
    SyncCastAudio_IsPropertySettable,
    SyncCastAudio_GetPropertyDataSize,
    SyncCastAudio_GetPropertyData,
    SyncCastAudio_SetPropertyData,
    SyncCastAudio_StartIO,
    SyncCastAudio_StopIO,
    SyncCastAudio_GetZeroTimeStamp,
    SyncCastAudio_WillDoIOOperation,
    SyncCastAudio_BeginIOOperation,
    SyncCastAudio_DoIOOperation,
    SyncCastAudio_EndIOOperation
};

static AudioServerPlugInDriverInterface*    gAudioServerPlugInDriverInterfacePtr    = &gAudioServerPlugInDriverInterface;
static AudioServerPlugInDriverRef           gAudioServerPlugInDriverRef             = &gAudioServerPlugInDriverInterfacePtr;

#pragma mark - Factory

// Referenced by Info.plist's CFPlugInFactories. The HAL asks for exactly one
// interface type; anything else is refused so a mismatched host cannot get a
// half-initialised driver.
void* SyncCastAudio_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID)
{
    #pragma unused(inAllocator)
    void* theAnswer = NULL;
    if(CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID))
    {
        theAnswer = gAudioServerPlugInDriverRef;
    }
    return theAnswer;
}

#pragma mark - COM

static HRESULT SyncCastAudio_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface)
{
    if((inDriver != gAudioServerPlugInDriverRef) || (outInterface == NULL))
    {
        return kAudioHardwareIllegalOperationError;
    }

    CFUUIDRef theRequestedUUID = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if(theRequestedUUID == NULL)
    {
        return kAudioHardwareIllegalOperationError;
    }

    HRESULT theAnswer = E_NOINTERFACE;
    if(CFEqual(theRequestedUUID, IUnknownUUID) || CFEqual(theRequestedUUID, kAudioServerPlugInDriverInterfaceUUID))
    {
        pthread_mutex_lock(&gPlugIn_StateMutex);
        ++gPlugIn_RefCount;
        pthread_mutex_unlock(&gPlugIn_StateMutex);
        *outInterface = gAudioServerPlugInDriverRef;
        theAnswer = S_OK;
    }
    CFRelease(theRequestedUUID);
    return theAnswer;
}

static ULONG SyncCastAudio_AddRef(void* inDriver)
{
    if(inDriver != gAudioServerPlugInDriverRef) { return 0; }
    pthread_mutex_lock(&gPlugIn_StateMutex);
    if(gPlugIn_RefCount < UINT32_MAX) { ++gPlugIn_RefCount; }
    ULONG theAnswer = gPlugIn_RefCount;
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    return theAnswer;
}

static ULONG SyncCastAudio_Release(void* inDriver)
{
    if(inDriver != gAudioServerPlugInDriverRef) { return 0; }
    pthread_mutex_lock(&gPlugIn_StateMutex);
    if(gPlugIn_RefCount > 0) { --gPlugIn_RefCount; }
    ULONG theAnswer = gPlugIn_RefCount;
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    return theAnswer;
}

#pragma mark - Lifecycle

static OSStatus SyncCastAudio_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)
{
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }

    gPlugIn_Host = inHost;

    // Host ticks per frame — the whole timeline is derived from this, so it is
    // recomputed on every sample-rate change too.
    SyncCastAudio_ResetTimeline(gDevice_SampleRate);

    // Restore the user's last level, the way a real device would. A settings
    // read that fails simply leaves full scale.
    if(gPlugIn_Host != NULL)
    {
        CFPropertyListRef theValue = NULL;
        gPlugIn_Host->CopyFromStorage(gPlugIn_Host, CFSTR("volumeScalar"), &theValue);
        if(theValue != NULL)
        {
            if(CFGetTypeID(theValue) == CFNumberGetTypeID())
            {
                Float32 theScalar = 1.0f;
                CFNumberGetValue((CFNumberRef)theValue, kCFNumberFloat32Type, &theScalar);
                gVolume_Output_Scalar = SyncCastAudio_ClampScalar(theScalar);
            }
            CFRelease(theValue);
        }
        // Mute too: installing the driver restarts coreaudiod, and coming back
        // unmuted at the previous level is exactly the loud surprise this
        // whole path is careful to avoid.
        CFPropertyListRef theMute = NULL;
        gPlugIn_Host->CopyFromStorage(gPlugIn_Host, CFSTR("muted"), &theMute);
        if(theMute != NULL)
        {
            if(CFGetTypeID(theMute) == CFNumberGetTypeID())
            {
                SInt32 theRaw = 0;
                CFNumberGetValue((CFNumberRef)theMute, kCFNumberSInt32Type, &theRaw);
                gMute_Output_Value = (theRaw != 0);
            }
            CFRelease(theMute);
        }
    }

    return 0;
}

// This driver publishes its single device statically; it does not support the
// HAL asking for extra devices to be created (that is for aggregate-style
// plug-ins). Refusing is the documented answer.
static OSStatus SyncCastAudio_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID)
{
    #pragma unused(inDescription, inClientInfo, outDeviceObjectID)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus SyncCastAudio_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID)
{
    #pragma unused(inDeviceObjectID)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus SyncCastAudio_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo)
{
    #pragma unused(inClientInfo)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    if(inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }
    return 0;
}

static OSStatus SyncCastAudio_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo)
{
    #pragma unused(inClientInfo)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    if(inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }
    return 0;
}

// The only configuration change this device makes is a sample-rate change,
// requested from SetPropertyData and carried here as the new rate.
static OSStatus SyncCastAudio_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo)
{
    #pragma unused(inChangeInfo)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    if(inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }

    Float64 theNewSampleRate = (Float64)inChangeAction;
    if((theNewSampleRate != kDevice_SampleRate_44100) &&
       (theNewSampleRate != kDevice_DefaultSampleRate) &&
       (theNewSampleRate != kDevice_SampleRate_96000))
    {
        return kAudioHardwareBadObjectError;
    }

    // Rate first, under the state mutex (the property getters read it there),
    // then the derived timeline under the IO mutex. Taken one after the other,
    // never nested — see the lock order note in SyncCastAudio.h.
    pthread_mutex_lock(&gPlugIn_StateMutex);
    gDevice_SampleRate = theNewSampleRate;
    pthread_mutex_unlock(&gPlugIn_StateMutex);

    // The timeline must restart at the new rate, or the HAL sees a jump.
    SyncCastAudio_ResetTimeline(theNewSampleRate);

    return 0;
}

static OSStatus SyncCastAudio_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo)
{
    #pragma unused(inChangeAction, inChangeInfo)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    if(inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }
    return 0;
}

#pragma mark - IO
//
// There is no hardware and no loopback: the device exists to be selected, to
// carry a volume control, and to be tapped. So IO is only about publishing a
// coherent timeline; the samples themselves are discarded.

static OSStatus SyncCastAudio_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    #pragma unused(inClientID)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    if(inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }

    pthread_mutex_lock(&gPlugIn_StateMutex);
    Boolean theFirstClient = (gDevice_IORunningCounter == 0);
    if(gDevice_IORunningCounter < UINT64_MAX) { ++gDevice_IORunningCounter; }
    pthread_mutex_unlock(&gPlugIn_StateMutex);

    // Re-anchor outside the state mutex: the timeline belongs to the IO mutex.
    // Safe to do after the counter has been bumped because the HAL does not
    // start the IO thread — and so cannot call GetZeroTimeStamp — until this
    // call returns for the first client.
    if(theFirstClient)
    {
        pthread_mutex_lock(&gPlugIn_StateMutex);
        Float64 theRate = gDevice_SampleRate;
        pthread_mutex_unlock(&gPlugIn_StateMutex);
        SyncCastAudio_ResetTimeline(theRate);
    }

    return 0;
}

static OSStatus SyncCastAudio_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    #pragma unused(inClientID)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    if(inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }

    pthread_mutex_lock(&gPlugIn_StateMutex);
    if(gDevice_IORunningCounter > 0) { --gDevice_IORunningCounter; }
    pthread_mutex_unlock(&gPlugIn_StateMutex);

    return 0;
}

static OSStatus SyncCastAudio_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed)
{
    #pragma unused(inClientID)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    if(inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }

    // IO mutex only: this runs on the real-time IO thread, and the property
    // paths (which can block on storage writes and CF allocation) must never
    // be able to make it wait.
    pthread_mutex_lock(&gDevice_IOMutex);

    UInt64 theCurrentHostTime = mach_absolute_time();
    Float64 theHostTicksPerRingBuffer = gDevice_HostTicksPerFrame * ((Float64)kDevice_RingBufferSize);
    Float64 theHostTickOffset = ((Float64)(gDevice_NumberTimeStamps + 1)) * theHostTicksPerRingBuffer;
    UInt64 theNextHostTime = gDevice_AnchorHostTime + ((UInt64)theHostTickOffset);

    if(theNextHostTime <= theCurrentHostTime)
    {
        ++gDevice_NumberTimeStamps;
        gDevice_AnchorSampleTime += (Float64)kDevice_RingBufferSize;
    }

    *outSampleTime = gDevice_AnchorSampleTime;
    *outHostTime = gDevice_AnchorHostTime + (UInt64)(((Float64)gDevice_NumberTimeStamps) * theHostTicksPerRingBuffer);
    *outSeed = 1;

    pthread_mutex_unlock(&gDevice_IOMutex);

    return 0;
}

static OSStatus SyncCastAudio_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace)
{
    #pragma unused(inClientID)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    if(inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }

    Boolean willDo = false;
    Boolean willDoInPlace = true;
    switch(inOperationID)
    {
        case kAudioServerPlugInIOOperationWriteMix:
            // Accepted and thrown away. Accepting it is what makes the device
            // a valid output; a Process Tap pinned to this device sees the mix
            // BEFORE it reaches us, which is the whole design.
            willDo = true;
            willDoInPlace = true;
            break;
        default:
            break;
    }

    if(outWillDo != NULL)           { *outWillDo = willDo; }
    if(outWillDoInPlace != NULL)    { *outWillDoInPlace = willDoInPlace; }

    return 0;
}

static OSStatus SyncCastAudio_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    #pragma unused(inClientID, inOperationID, inIOBufferFrameSize, inIOCycleInfo)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    if(inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }
    return 0;
}

static OSStatus SyncCastAudio_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer)
{
    #pragma unused(inStreamObjectID, inClientID, inIOCycleInfo, ioSecondaryBuffer)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    if(inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }

    // The mix is discarded — nothing reads this device, so there is nothing to
    // write and nothing to clear. Deliberately NOT scaled by the volume
    // control either: SyncCast applies the level on the real outputs, and
    // scaling here would attenuate twice. (Apple's NullAudio does nothing here
    // for the same reason; zeroing the buffer would be pointless work on a
    // real-time thread.)
    (void)inOperationID;
    (void)inIOBufferFrameSize;
    (void)ioMainBuffer;

    return 0;
}

static OSStatus SyncCastAudio_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    #pragma unused(inClientID, inOperationID, inIOBufferFrameSize, inIOCycleInfo)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    if(inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }
    return 0;
}
