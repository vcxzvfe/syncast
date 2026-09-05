//
//  SyncCastAudioStreamControls.c
//  SyncCastAudio.driver
//
//  The output stream and the two controls that are the reason this driver
//  exists: a volume control and a mute control on an otherwise ordinary
//  output device, so macOS gives it a working system volume.
//
//  Neither control touches audio data — see DoIOOperation. They are read by
//  SyncCastRouter, which applies the level to the real speakers.
//

#include "SyncCastAudio.h"

#include <CoreFoundation/CoreFoundation.h>

#pragma mark - Format helpers

static void SyncCastAudio_FillFormat(AudioStreamBasicDescription* outFormat, Float64 inSampleRate)
{
    memset(outFormat, 0, sizeof(AudioStreamBasicDescription));
    outFormat->mSampleRate = inSampleRate;
    outFormat->mFormatID = kAudioFormatLinearPCM;
    outFormat->mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    outFormat->mBytesPerPacket = kDevice_BytesPerFrame;
    outFormat->mFramesPerPacket = 1;
    outFormat->mBytesPerFrame = kDevice_BytesPerFrame;
    outFormat->mChannelsPerFrame = kDevice_ChannelCount;
    outFormat->mBitsPerChannel = kDevice_BitsPerChannel;
}

static void SyncCastAudio_FillFormatRange(AudioStreamRangedDescription* outRange, Float64 inSampleRate)
{
    memset(outRange, 0, sizeof(AudioStreamRangedDescription));
    SyncCastAudio_FillFormat(&outRange->mFormat, inSampleRate);
    outRange->mSampleRateRange.mMinimum = inSampleRate;
    outRange->mSampleRateRange.mMaximum = inSampleRate;
}

#pragma mark - HasProperty

Boolean SyncCastAudio_StreamControl_HasProperty(AudioObjectID inObjectID, const AudioObjectPropertyAddress* inAddress)
{
    switch(inObjectID)
    {
        case kObjectID_Stream_Output:
            switch(inAddress->mSelector)
            {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioStreamPropertyIsActive:
                case kAudioStreamPropertyDirection:
                case kAudioStreamPropertyTerminalType:
                case kAudioStreamPropertyStartingChannel:
                case kAudioStreamPropertyLatency:
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats:
                    return true;
                default:
                    return false;
            }

        case kObjectID_Volume_Output:
            switch(inAddress->mSelector)
            {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioControlPropertyScope:
                case kAudioControlPropertyElement:
                case kAudioLevelControlPropertyScalarValue:
                case kAudioLevelControlPropertyDecibelValue:
                case kAudioLevelControlPropertyDecibelRange:
                case kAudioLevelControlPropertyConvertScalarToDecibels:
                case kAudioLevelControlPropertyConvertDecibelsToScalar:
                    return true;
                default:
                    return false;
            }

        case kObjectID_Mute_Output:
            switch(inAddress->mSelector)
            {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioControlPropertyScope:
                case kAudioControlPropertyElement:
                case kAudioBooleanControlPropertyValue:
                    return true;
                default:
                    return false;
            }

        default:
            return false;
    }
}

#pragma mark - IsPropertySettable

OSStatus SyncCastAudio_StreamControl_IsPropertySettable(AudioObjectID inObjectID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
    if(!SyncCastAudio_StreamControl_HasProperty(inObjectID, inAddress))
    {
        return kAudioHardwareUnknownPropertyError;
    }

    switch(inAddress->mSelector)
    {
        // The writable properties. The volume pair is the point of the whole
        // driver: macOS greys the system slider out for any device whose level
        // is not settable.
        //
        // kAudioStreamPropertyIsActive is deliberately NOT here. The stream is
        // permanently active, so claiming it is settable and then ignoring the
        // write tells clients a lie they cannot detect — a client that
        // deactivates the stream and reads back 1 has no way to know whether it
        // failed or raced. Reporting false, and failing the set, is the honest
        // answer and the one clients already handle.
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioLevelControlPropertyScalarValue:
        case kAudioLevelControlPropertyDecibelValue:
        case kAudioBooleanControlPropertyValue:
            *outIsSettable = true;
            break;
        default:
            *outIsSettable = false;
            break;
    }
    return 0;
}

#pragma mark - GetPropertyDataSize

OSStatus SyncCastAudio_StreamControl_GetPropertyDataSize(AudioObjectID inObjectID, const AudioObjectPropertyAddress* inAddress, UInt32* outDataSize)
{
    if(!SyncCastAudio_StreamControl_HasProperty(inObjectID, inAddress))
    {
        return kAudioHardwareUnknownPropertyError;
    }

    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            return 0;
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID);
            return 0;
        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0;
            return 0;
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioBooleanControlPropertyValue:
            *outDataSize = sizeof(UInt32);
            return 0;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return 0;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            *outDataSize = 3 * sizeof(AudioStreamRangedDescription);
            return 0;
        case kAudioControlPropertyScope:
            *outDataSize = sizeof(AudioObjectPropertyScope);
            return 0;
        case kAudioControlPropertyElement:
            *outDataSize = sizeof(AudioObjectPropertyElement);
            return 0;
        case kAudioLevelControlPropertyScalarValue:
        case kAudioLevelControlPropertyDecibelValue:
        case kAudioLevelControlPropertyConvertScalarToDecibels:
        case kAudioLevelControlPropertyConvertDecibelsToScalar:
            *outDataSize = sizeof(Float32);
            return 0;
        case kAudioLevelControlPropertyDecibelRange:
            *outDataSize = sizeof(AudioValueRange);
            return 0;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - GetPropertyData

OSStatus SyncCastAudio_StreamControl_GetPropertyData(AudioObjectID inObjectID, const AudioObjectPropertyAddress* inAddress, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    if(!SyncCastAudio_StreamControl_HasProperty(inObjectID, inAddress))
    {
        return kAudioHardwareUnknownPropertyError;
    }

    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
        {
            if(inDataSize < sizeof(AudioClassID)) { return kAudioHardwareBadPropertySizeError; }
            AudioClassID theBase = kAudioObjectClassID;
            if(inObjectID == kObjectID_Volume_Output) { theBase = kAudioLevelControlClassID; }
            if(inObjectID == kObjectID_Mute_Output)   { theBase = kAudioBooleanControlClassID; }
            *((AudioClassID*)outData) = theBase;
            *outDataSize = sizeof(AudioClassID);
            return 0;
        }

        case kAudioObjectPropertyClass:
        {
            if(inDataSize < sizeof(AudioClassID)) { return kAudioHardwareBadPropertySizeError; }
            AudioClassID theClass = kAudioStreamClassID;
            if(inObjectID == kObjectID_Volume_Output) { theClass = kAudioVolumeControlClassID; }
            if(inObjectID == kObjectID_Mute_Output)   { theClass = kAudioMuteControlClassID; }
            *((AudioClassID*)outData) = theClass;
            *outDataSize = sizeof(AudioClassID);
            return 0;
        }

        case kAudioObjectPropertyOwner:
            if(inDataSize < sizeof(AudioObjectID)) { return kAudioHardwareBadPropertySizeError; }
            *((AudioObjectID*)outData) = kObjectID_Device;
            *outDataSize = sizeof(AudioObjectID);
            return 0;

        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0;
            return 0;

        case kAudioStreamPropertyIsActive:
            // Always active: the stream exists so the device is a legal
            // output, and there is no state in which deactivating it helps.
            if(inDataSize < sizeof(UInt32)) { return kAudioHardwareBadPropertySizeError; }
            *((UInt32*)outData) = 1;
            *outDataSize = sizeof(UInt32);
            return 0;

        case kAudioStreamPropertyDirection:
            if(inDataSize < sizeof(UInt32)) { return kAudioHardwareBadPropertySizeError; }
            *((UInt32*)outData) = 0;    // 0 = output
            *outDataSize = sizeof(UInt32);
            return 0;

        case kAudioStreamPropertyTerminalType:
            if(inDataSize < sizeof(UInt32)) { return kAudioHardwareBadPropertySizeError; }
            *((UInt32*)outData) = kAudioStreamTerminalTypeSpeaker;
            *outDataSize = sizeof(UInt32);
            return 0;

        case kAudioStreamPropertyStartingChannel:
            if(inDataSize < sizeof(UInt32)) { return kAudioHardwareBadPropertySizeError; }
            *((UInt32*)outData) = 1;
            *outDataSize = sizeof(UInt32);
            return 0;

        case kAudioStreamPropertyLatency:
            if(inDataSize < sizeof(UInt32)) { return kAudioHardwareBadPropertySizeError; }
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            return 0;

        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        {
            if(inDataSize < sizeof(AudioStreamBasicDescription)) { return kAudioHardwareBadPropertySizeError; }
            pthread_mutex_lock(&gPlugIn_StateMutex);
            Float64 theRate = gDevice_SampleRate;
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            SyncCastAudio_FillFormat((AudioStreamBasicDescription*)outData, theRate);
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return 0;
        }

        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
        {
            const Float64 theRates[3] = {
                kDevice_SampleRate_44100, kDevice_DefaultSampleRate, kDevice_SampleRate_96000
            };
            UInt32 theRequested = inDataSize / sizeof(AudioStreamRangedDescription);
            if(theRequested > 3) { theRequested = 3; }
            for(UInt32 i = 0; i < theRequested; ++i)
            {
                SyncCastAudio_FillFormatRange(&((AudioStreamRangedDescription*)outData)[i], theRates[i]);
            }
            *outDataSize = theRequested * sizeof(AudioStreamRangedDescription);
            return 0;
        }

        case kAudioControlPropertyScope:
            if(inDataSize < sizeof(AudioObjectPropertyScope)) { return kAudioHardwareBadPropertySizeError; }
            *((AudioObjectPropertyScope*)outData) = kAudioObjectPropertyScopeOutput;
            *outDataSize = sizeof(AudioObjectPropertyScope);
            return 0;

        case kAudioControlPropertyElement:
            // Element 0 (main): one master control, which is what the system
            // slider and every volume API expect to find.
            if(inDataSize < sizeof(AudioObjectPropertyElement)) { return kAudioHardwareBadPropertySizeError; }
            *((AudioObjectPropertyElement*)outData) = kAudioObjectPropertyElementMain;
            *outDataSize = sizeof(AudioObjectPropertyElement);
            return 0;

        case kAudioLevelControlPropertyScalarValue:
        {
            if(inDataSize < sizeof(Float32)) { return kAudioHardwareBadPropertySizeError; }
            pthread_mutex_lock(&gPlugIn_StateMutex);
            *((Float32*)outData) = gVolume_Output_Scalar;
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            *outDataSize = sizeof(Float32);
            return 0;
        }

        case kAudioLevelControlPropertyDecibelValue:
        {
            if(inDataSize < sizeof(Float32)) { return kAudioHardwareBadPropertySizeError; }
            pthread_mutex_lock(&gPlugIn_StateMutex);
            Float32 theScalar = gVolume_Output_Scalar;
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            *((Float32*)outData) = SyncCastAudio_ScalarToDecibels(theScalar);
            *outDataSize = sizeof(Float32);
            return 0;
        }

        case kAudioLevelControlPropertyDecibelRange:
            if(inDataSize < sizeof(AudioValueRange)) { return kAudioHardwareBadPropertySizeError; }
            ((AudioValueRange*)outData)->mMinimum = kVolume_MinDB;
            ((AudioValueRange*)outData)->mMaximum = kVolume_MaxDB;
            *outDataSize = sizeof(AudioValueRange);
            return 0;

        case kAudioLevelControlPropertyConvertScalarToDecibels:
            // In-place conversion: the caller passes a scalar, gets decibels.
            if(inDataSize < sizeof(Float32)) { return kAudioHardwareBadPropertySizeError; }
            *((Float32*)outData) = SyncCastAudio_ScalarToDecibels(*((Float32*)outData));
            *outDataSize = sizeof(Float32);
            return 0;

        case kAudioLevelControlPropertyConvertDecibelsToScalar:
            if(inDataSize < sizeof(Float32)) { return kAudioHardwareBadPropertySizeError; }
            *((Float32*)outData) = SyncCastAudio_DecibelsToScalar(*((Float32*)outData));
            *outDataSize = sizeof(Float32);
            return 0;

        case kAudioBooleanControlPropertyValue:
        {
            if(inDataSize < sizeof(UInt32)) { return kAudioHardwareBadPropertySizeError; }
            pthread_mutex_lock(&gPlugIn_StateMutex);
            *((UInt32*)outData) = gMute_Output_Value ? 1 : 0;
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            *outDataSize = sizeof(UInt32);
            return 0;
        }

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - SetPropertyData

/// Persist the level and the mute so a reboot — or a coreaudiod restart, which
/// every driver install performs — comes back where the user left it, the way
/// a real device does. Mute matters MORE than the level: without it a user who
/// was muted comes back unmuted at their previous level, which is the loud
/// surprise the seeding logic on the SyncCast side exists to prevent.
///
/// The catch is the rate. A volume drag or a scroll gesture sets the scalar
/// dozens of times a second, and each WriteToStorage is a CF allocation plus a
/// preference write; doing one per step is pointless I/O on the thread the HAL
/// uses to answer every other client's property calls. So the setters only mark
/// the value dirty and the write is coalesced to at most one per
/// kPersist_MinIntervalNanos, with an unconditional flush when IO stops.
///
/// Trade-off worth naming: the last value of a burst is not written until the
/// next set after the interval, or until StopIO. Losing it means coming back at
/// the level from ~500 ms earlier in the same gesture — inaudible, and the
/// common case (a level the user then leaves alone) still ends at StopIO with
/// the true value on disk.

#define kPersist_MinIntervalNanos   500000000ull

// All four are guarded by gPlugIn_StateMutex.
static Boolean  gPersist_VolumeDirty        = false;
static Float32  gPersist_VolumeScalar       = 1.0f;
static Boolean  gPersist_MuteDirty          = false;
static bool     gPersist_MuteValue          = false;
static UInt64   gPersist_LastWriteHostTime  = 0;

static UInt64 SyncCastAudio_NanosToHostTicks(UInt64 inNanos)
{
    struct mach_timebase_info theTimeBaseInfo;
    mach_timebase_info(&theTimeBaseInfo);
    if(theTimeBaseInfo.numer == 0) { return inNanos; }
    return (inNanos * (UInt64)theTimeBaseInfo.denom) / (UInt64)theTimeBaseInfo.numer;
}

static void SyncCastAudio_WriteNumberToStorage(CFStringRef inKey, CFNumberType inType, const void* inValue)
{
    CFNumberRef theValue = CFNumberCreate(NULL, inType, inValue);
    if(theValue != NULL)
    {
        gPlugIn_Host->WriteToStorage(gPlugIn_Host, inKey, theValue);
        CFRelease(theValue);
    }
}

void SyncCastAudio_FlushPersistentState(Boolean inForce)
{
    if(gPlugIn_Host == NULL) { return; }

    Boolean theWriteVolume = false;
    Boolean theWriteMute = false;
    Float32 theVolume = 1.0f;
    SInt32 theMute = 0;

    pthread_mutex_lock(&gPlugIn_StateMutex);
    if(gPersist_VolumeDirty || gPersist_MuteDirty)
    {
        UInt64 theNow = mach_absolute_time();
        UInt64 theInterval = SyncCastAudio_NanosToHostTicks(kPersist_MinIntervalNanos);
        // A first write (last == 0) is never held back: the interesting case is
        // a single deliberate change, not a drag.
        if(inForce || (gPersist_LastWriteHostTime == 0) ||
           ((theNow - gPersist_LastWriteHostTime) >= theInterval))
        {
            theWriteVolume = gPersist_VolumeDirty;
            theWriteMute = gPersist_MuteDirty;
            theVolume = gPersist_VolumeScalar;
            theMute = gPersist_MuteValue ? 1 : 0;
            gPersist_VolumeDirty = false;
            gPersist_MuteDirty = false;
            gPersist_LastWriteHostTime = theNow;
        }
    }
    pthread_mutex_unlock(&gPlugIn_StateMutex);

    // Outside the mutex: WriteToStorage can re-enter us, and it must not be
    // able to block a property getter.
    if(theWriteVolume) { SyncCastAudio_WriteNumberToStorage(CFSTR("volumeScalar"), kCFNumberFloat32Type, &theVolume); }
    if(theWriteMute)   { SyncCastAudio_WriteNumberToStorage(CFSTR("muted"), kCFNumberSInt32Type, &theMute); }
}

OSStatus SyncCastAudio_StreamControl_SetPropertyData(AudioObjectID inObjectID, const AudioObjectPropertyAddress* inAddress, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2])
{
    if(!SyncCastAudio_StreamControl_HasProperty(inObjectID, inAddress))
    {
        return kAudioHardwareUnknownPropertyError;
    }
    *outNumberPropertiesChanged = 0;

    switch(inAddress->mSelector)
    {
        case kAudioStreamPropertyIsActive:
            // The stream cannot be deactivated — the device has exactly one
            // stream and it exists to make the device a legal output. Say so,
            // rather than swallowing the write and continuing to report 1.
            // IsPropertySettable reports false for the same reason.
            return kAudioHardwareUnsupportedOperationError;

        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        {
            if(inDataSize != sizeof(AudioStreamBasicDescription)) { return kAudioHardwareBadPropertySizeError; }
            const AudioStreamBasicDescription* theFormat = (const AudioStreamBasicDescription*)inData;
            if(theFormat->mFormatID != kAudioFormatLinearPCM) { return kAudioDeviceUnsupportedFormatError; }
            if((theFormat->mFormatFlags & kAudioFormatFlagIsFloat) == 0) { return kAudioDeviceUnsupportedFormatError; }
            if(theFormat->mBitsPerChannel != kDevice_BitsPerChannel) { return kAudioDeviceUnsupportedFormatError; }
            if(theFormat->mChannelsPerFrame != kDevice_ChannelCount) { return kAudioDeviceUnsupportedFormatError; }
            // The layout fields matter as much as the sample size: the stream
            // advertises one interleaved packed frame per packet, and a client
            // that gets a "yes" for a non-interleaved or differently-strided
            // format would lay its buffers out to match a format this device
            // never agreed to. Check everything FillFormat sets.
            if((theFormat->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0) { return kAudioDeviceUnsupportedFormatError; }
            if(theFormat->mFramesPerPacket != 1) { return kAudioDeviceUnsupportedFormatError; }
            if(theFormat->mBytesPerFrame != kDevice_BytesPerFrame) { return kAudioDeviceUnsupportedFormatError; }
            if(theFormat->mBytesPerPacket != kDevice_BytesPerFrame) { return kAudioDeviceUnsupportedFormatError; }
            if((theFormat->mSampleRate != kDevice_SampleRate_44100) &&
               (theFormat->mSampleRate != kDevice_DefaultSampleRate) &&
               (theFormat->mSampleRate != kDevice_SampleRate_96000))
            {
                return kAudioDeviceUnsupportedFormatError;
            }
            // Only the rate can actually differ, and changing it is a device
            // configuration change, not a property write.
            pthread_mutex_lock(&gPlugIn_StateMutex);
            Float64 theCurrentRate = gDevice_SampleRate;
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            if((theFormat->mSampleRate != theCurrentRate) && (gPlugIn_Host != NULL))
            {
                gPlugIn_Host->RequestDeviceConfigurationChange(
                    gPlugIn_Host, kObjectID_Device, (UInt64)theFormat->mSampleRate, NULL);
            }
            return 0;
        }

        case kAudioLevelControlPropertyScalarValue:
        case kAudioLevelControlPropertyDecibelValue:
        {
            if(inDataSize != sizeof(Float32)) { return kAudioHardwareBadPropertySizeError; }
            Float32 theNewScalar = (inAddress->mSelector == kAudioLevelControlPropertyScalarValue)
                ? SyncCastAudio_ClampScalar(*((const Float32*)inData))
                : SyncCastAudio_DecibelsToScalar(*((const Float32*)inData));

            pthread_mutex_lock(&gPlugIn_StateMutex);
            Boolean theChanged = (gVolume_Output_Scalar != theNewScalar);
            gVolume_Output_Scalar = theNewScalar;
            if(theChanged)
            {
                gPersist_VolumeScalar = theNewScalar;
                gPersist_VolumeDirty = true;
            }
            pthread_mutex_unlock(&gPlugIn_StateMutex);

            if(theChanged)
            {
                // BOTH representations change together, and both must be
                // announced: the system slider watches the scalar, other
                // clients watch the decibel value, and SyncCast's own
                // listener is registered on the scalar.
                *outNumberPropertiesChanged = 2;
                outChangedAddresses[0].mSelector = kAudioLevelControlPropertyScalarValue;
                outChangedAddresses[0].mScope = kAudioObjectPropertyScopeGlobal;
                outChangedAddresses[0].mElement = kAudioObjectPropertyElementMain;
                outChangedAddresses[1].mSelector = kAudioLevelControlPropertyDecibelValue;
                outChangedAddresses[1].mScope = kAudioObjectPropertyScopeGlobal;
                outChangedAddresses[1].mElement = kAudioObjectPropertyElementMain;
                // Rate-limited: a drag writes storage at most twice a second.
                SyncCastAudio_FlushPersistentState(false);
            }
            return 0;
        }

        case kAudioBooleanControlPropertyValue:
        {
            if(inDataSize != sizeof(UInt32)) { return kAudioHardwareBadPropertySizeError; }
            bool theNewValue = (*((const UInt32*)inData) != 0);
            pthread_mutex_lock(&gPlugIn_StateMutex);
            Boolean theChanged = (gMute_Output_Value != theNewValue);
            gMute_Output_Value = theNewValue;
            if(theChanged)
            {
                gPersist_MuteValue = theNewValue;
                gPersist_MuteDirty = true;
            }
            pthread_mutex_unlock(&gPlugIn_StateMutex);

            if(theChanged)
            {
                *outNumberPropertiesChanged = 1;
                outChangedAddresses[0].mSelector = kAudioBooleanControlPropertyValue;
                outChangedAddresses[0].mScope = kAudioObjectPropertyScopeGlobal;
                outChangedAddresses[0].mElement = kAudioObjectPropertyElementMain;
                // Forced: mute is one discrete press, never a burst, and it is
                // the value whose loss is actually audible.
                SyncCastAudio_FlushPersistentState(true);
            }
            return 0;
        }

        default:
            return kAudioHardwareUnsupportedOperationError;
    }
}
