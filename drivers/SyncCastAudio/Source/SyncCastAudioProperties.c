//
//  SyncCastAudioProperties.c
//  SyncCastAudio.driver
//
//  Property implementation for the plug-in and device objects, plus the four
//  public entry points that dispatch every object. Stream and control
//  properties live in SyncCastAudioStreamControls.c.
//

#include "SyncCastAudio.h"

#include <CoreFoundation/CoreFoundation.h>

#pragma mark - Helpers

static Boolean SyncCastAudio_IsKnownObject(AudioObjectID inObjectID)
{
    return (inObjectID == kObjectID_PlugIn) ||
           (inObjectID == kObjectID_Device) ||
           (inObjectID == kObjectID_Stream_Output) ||
           (inObjectID == kObjectID_Volume_Output) ||
           (inObjectID == kObjectID_Mute_Output);
}

static Boolean SyncCastAudio_ScopeIsOutputOrGlobal(AudioObjectPropertyScope inScope)
{
    return (inScope == kAudioObjectPropertyScopeGlobal) ||
           (inScope == kAudioObjectPropertyScopeOutput);
}

#pragma mark - PlugIn object

static Boolean SyncCastAudio_HasPlugInProperty(const AudioObjectPropertyAddress* inAddress)
{
    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyBoxList:
        case kAudioPlugInPropertyTranslateUIDToBox:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
            return true;
        default:
            return false;
    }
}

static OSStatus SyncCastAudio_GetPlugInPropertyDataSize(const AudioObjectPropertyAddress* inAddress, UInt32* outDataSize)
{
    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            return 0;
        case kAudioObjectPropertyOwner:
        case kAudioPlugInPropertyTranslateUIDToBox:
        case kAudioPlugInPropertyTranslateUIDToDevice:
            *outDataSize = sizeof(AudioObjectID);
            return 0;
        case kAudioObjectPropertyManufacturer:
        case kAudioPlugInPropertyResourceBundle:
            *outDataSize = sizeof(CFStringRef);
            return 0;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
            *outDataSize = sizeof(AudioObjectID);   // exactly one device
            return 0;
        case kAudioPlugInPropertyBoxList:
            // This driver publishes no box. A box exists to model removable
            // hardware; there is none, and an empty list is a valid answer.
            *outDataSize = 0;
            return 0;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus SyncCastAudio_GetPlugInPropertyData(const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
            if(inDataSize < sizeof(AudioClassID)) { return kAudioHardwareBadPropertySizeError; }
            *((AudioClassID*)outData) = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            return 0;

        case kAudioObjectPropertyClass:
            if(inDataSize < sizeof(AudioClassID)) { return kAudioHardwareBadPropertySizeError; }
            *((AudioClassID*)outData) = kAudioPlugInClassID;
            *outDataSize = sizeof(AudioClassID);
            return 0;

        case kAudioObjectPropertyOwner:
            if(inDataSize < sizeof(AudioObjectID)) { return kAudioHardwareBadPropertySizeError; }
            *((AudioObjectID*)outData) = kAudioObjectUnknown;
            *outDataSize = sizeof(AudioObjectID);
            return 0;

        case kAudioObjectPropertyManufacturer:
            if(inDataSize < sizeof(CFStringRef)) { return kAudioHardwareBadPropertySizeError; }
            *((CFStringRef*)outData) = CFSTR(kManufacturer_Name);
            CFRetain(*((CFStringRef*)outData));
            *outDataSize = sizeof(CFStringRef);
            return 0;

        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
            if(inDataSize < sizeof(AudioObjectID))
            {
                // A caller asking for zero devices gets zero devices, not an
                // error — that is how the HAL probes sizes.
                *outDataSize = 0;
                return 0;
            }
            ((AudioObjectID*)outData)[0] = kObjectID_Device;
            *outDataSize = sizeof(AudioObjectID);
            return 0;

        case kAudioPlugInPropertyBoxList:
            *outDataSize = 0;
            return 0;

        case kAudioPlugInPropertyTranslateUIDToBox:
            if(inDataSize < sizeof(AudioObjectID)) { return kAudioHardwareBadPropertySizeError; }
            *((AudioObjectID*)outData) = kAudioObjectUnknown;
            *outDataSize = sizeof(AudioObjectID);
            return 0;

        case kAudioPlugInPropertyTranslateUIDToDevice:
        {
            if(inQualifierDataSize != sizeof(CFStringRef)) { return kAudioHardwareBadPropertySizeError; }
            if(inDataSize < sizeof(AudioObjectID)) { return kAudioHardwareBadPropertySizeError; }
            CFStringRef theUID = *((const CFStringRef*)inQualifierData);
            *((AudioObjectID*)outData) =
                (theUID != NULL && CFStringCompare(theUID, CFSTR(kDevice_UID), 0) == kCFCompareEqualTo)
                    ? kObjectID_Device
                    : kAudioObjectUnknown;
            *outDataSize = sizeof(AudioObjectID);
            return 0;
        }

        case kAudioPlugInPropertyResourceBundle:
            if(inDataSize < sizeof(CFStringRef)) { return kAudioHardwareBadPropertySizeError; }
            *((CFStringRef*)outData) = CFSTR("");
            CFRetain(*((CFStringRef*)outData));
            *outDataSize = sizeof(CFStringRef);
            return 0;

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - Device object

static Boolean SyncCastAudio_HasDeviceProperty(const AudioObjectPropertyAddress* inAddress)
{
    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyControlList:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertyStreams:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyPreferredChannelsForStereo:
        case kAudioDevicePropertyPreferredChannelLayout:
            return true;
        default:
            return false;
    }
}

static OSStatus SyncCastAudio_GetDevicePropertyDataSize(const AudioObjectPropertyAddress* inAddress, UInt32* outDataSize)
{
    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            return 0;
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID);
            return 0;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
            *outDataSize = sizeof(CFStringRef);
            return 0;
        case kAudioObjectPropertyOwnedObjects:
            // Output scope (or global): the stream plus both controls.
            *outDataSize = (inAddress->mScope == kAudioObjectPropertyScopeInput)
                ? 0
                : 3 * sizeof(AudioObjectID);
            return 0;
        case kAudioObjectPropertyControlList:
            *outDataSize = 2 * sizeof(AudioObjectID);
            return 0;
        case kAudioDevicePropertyStreams:
            *outDataSize = SyncCastAudio_ScopeIsOutputOrGlobal(inAddress->mScope)
                ? sizeof(AudioObjectID)
                : 0;
            return 0;
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
            *outDataSize = sizeof(UInt32);
            return 0;
        case kAudioDevicePropertyRelatedDevices:
            *outDataSize = sizeof(AudioObjectID);
            return 0;
        case kAudioDevicePropertyNominalSampleRate:
            *outDataSize = sizeof(Float64);
            return 0;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            *outDataSize = 3 * sizeof(AudioValueRange);
            return 0;
        case kAudioDevicePropertyPreferredChannelsForStereo:
            *outDataSize = 2 * sizeof(UInt32);
            return 0;
        case kAudioDevicePropertyPreferredChannelLayout:
            *outDataSize = offsetof(AudioChannelLayout, mChannelDescriptions) +
                           (kDevice_ChannelCount * sizeof(AudioChannelDescription));
            return 0;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus SyncCastAudio_GetDevicePropertyData(const AudioObjectPropertyAddress* inAddress, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
            if(inDataSize < sizeof(AudioClassID)) { return kAudioHardwareBadPropertySizeError; }
            *((AudioClassID*)outData) = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            return 0;

        case kAudioObjectPropertyClass:
            if(inDataSize < sizeof(AudioClassID)) { return kAudioHardwareBadPropertySizeError; }
            *((AudioClassID*)outData) = kAudioDeviceClassID;
            *outDataSize = sizeof(AudioClassID);
            return 0;

        case kAudioObjectPropertyOwner:
            if(inDataSize < sizeof(AudioObjectID)) { return kAudioHardwareBadPropertySizeError; }
            *((AudioObjectID*)outData) = kObjectID_PlugIn;
            *outDataSize = sizeof(AudioObjectID);
            return 0;

        case kAudioObjectPropertyName:
            if(inDataSize < sizeof(CFStringRef)) { return kAudioHardwareBadPropertySizeError; }
            // This is what the Sound menu shows while SyncCast owns the
            // default output.
            *((CFStringRef*)outData) = CFSTR(kDevice_Name);
            CFRetain(*((CFStringRef*)outData));
            *outDataSize = sizeof(CFStringRef);
            return 0;

        case kAudioObjectPropertyManufacturer:
            if(inDataSize < sizeof(CFStringRef)) { return kAudioHardwareBadPropertySizeError; }
            *((CFStringRef*)outData) = CFSTR(kManufacturer_Name);
            CFRetain(*((CFStringRef*)outData));
            *outDataSize = sizeof(CFStringRef);
            return 0;

        case kAudioObjectPropertyOwnedObjects:
        {
            if(inAddress->mScope == kAudioObjectPropertyScopeInput)
            {
                *outDataSize = 0;
                return 0;
            }
            const AudioObjectID theOwned[3] = {
                kObjectID_Stream_Output, kObjectID_Volume_Output, kObjectID_Mute_Output
            };
            UInt32 theRequested = inDataSize / sizeof(AudioObjectID);
            if(theRequested > 3) { theRequested = 3; }
            for(UInt32 i = 0; i < theRequested; ++i)
            {
                ((AudioObjectID*)outData)[i] = theOwned[i];
            }
            *outDataSize = theRequested * sizeof(AudioObjectID);
            return 0;
        }

        case kAudioObjectPropertyControlList:
        {
            const AudioObjectID theControls[2] = { kObjectID_Volume_Output, kObjectID_Mute_Output };
            UInt32 theRequested = inDataSize / sizeof(AudioObjectID);
            if(theRequested > 2) { theRequested = 2; }
            for(UInt32 i = 0; i < theRequested; ++i)
            {
                ((AudioObjectID*)outData)[i] = theControls[i];
            }
            *outDataSize = theRequested * sizeof(AudioObjectID);
            return 0;
        }

        case kAudioDevicePropertyDeviceUID:
            if(inDataSize < sizeof(CFStringRef)) { return kAudioHardwareBadPropertySizeError; }
            *((CFStringRef*)outData) = CFSTR(kDevice_UID);
            CFRetain(*((CFStringRef*)outData));
            *outDataSize = sizeof(CFStringRef);
            return 0;

        case kAudioDevicePropertyModelUID:
            if(inDataSize < sizeof(CFStringRef)) { return kAudioHardwareBadPropertySizeError; }
            *((CFStringRef*)outData) = CFSTR(kDevice_ModelUID);
            CFRetain(*((CFStringRef*)outData));
            *outDataSize = sizeof(CFStringRef);
            return 0;

        case kAudioDevicePropertyTransportType:
            if(inDataSize < sizeof(UInt32)) { return kAudioHardwareBadPropertySizeError; }
            *((UInt32*)outData) = kAudioDeviceTransportTypeVirtual;
            *outDataSize = sizeof(UInt32);
            return 0;

        case kAudioDevicePropertyRelatedDevices:
            if(inDataSize < sizeof(AudioObjectID))
            {
                *outDataSize = 0;
                return 0;
            }
            ((AudioObjectID*)outData)[0] = kObjectID_Device;
            *outDataSize = sizeof(AudioObjectID);
            return 0;

        case kAudioDevicePropertyClockDomain:
            if(inDataSize < sizeof(UInt32)) { return kAudioHardwareBadPropertySizeError; }
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            return 0;

        case kAudioDevicePropertyDeviceIsAlive:
            if(inDataSize < sizeof(UInt32)) { return kAudioHardwareBadPropertySizeError; }
            *((UInt32*)outData) = 1;
            *outDataSize = sizeof(UInt32);
            return 0;

        case kAudioDevicePropertyDeviceIsRunning:
        {
            if(inDataSize < sizeof(UInt32)) { return kAudioHardwareBadPropertySizeError; }
            pthread_mutex_lock(&gPlugIn_StateMutex);
            *((UInt32*)outData) = (gDevice_IORunningCounter > 0) ? 1 : 0;
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            *outDataSize = sizeof(UInt32);
            return 0;
        }

        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            // BOTH must be true. SyncCast sets this device as the default
            // output AND the default system output; refusing the latter would
            // leave alert sounds on the old speaker, bypassing the fan-out.
            if(inDataSize < sizeof(UInt32)) { return kAudioHardwareBadPropertySizeError; }
            *((UInt32*)outData) = 1;
            *outDataSize = sizeof(UInt32);
            return 0;

        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
            // No hardware, no presentation delay to declare. SyncCast's own
            // outputs carry the real latency.
            if(inDataSize < sizeof(UInt32)) { return kAudioHardwareBadPropertySizeError; }
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            return 0;

        case kAudioDevicePropertyStreams:
            if(!SyncCastAudio_ScopeIsOutputOrGlobal(inAddress->mScope) || inDataSize < sizeof(AudioObjectID))
            {
                // Output-only by design: no input stream means nothing here
                // ever looks like a recording device to TCC.
                *outDataSize = 0;
                return 0;
            }
            ((AudioObjectID*)outData)[0] = kObjectID_Stream_Output;
            *outDataSize = sizeof(AudioObjectID);
            return 0;

        case kAudioDevicePropertyNominalSampleRate:
        {
            if(inDataSize < sizeof(Float64)) { return kAudioHardwareBadPropertySizeError; }
            pthread_mutex_lock(&gPlugIn_StateMutex);
            *((Float64*)outData) = gDevice_SampleRate;
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            *outDataSize = sizeof(Float64);
            return 0;
        }

        case kAudioDevicePropertyAvailableNominalSampleRates:
        {
            const Float64 theRates[3] = {
                kDevice_SampleRate_44100, kDevice_DefaultSampleRate, kDevice_SampleRate_96000
            };
            UInt32 theRequested = inDataSize / sizeof(AudioValueRange);
            if(theRequested > 3) { theRequested = 3; }
            for(UInt32 i = 0; i < theRequested; ++i)
            {
                ((AudioValueRange*)outData)[i].mMinimum = theRates[i];
                ((AudioValueRange*)outData)[i].mMaximum = theRates[i];
            }
            *outDataSize = theRequested * sizeof(AudioValueRange);
            return 0;
        }

        case kAudioDevicePropertyIsHidden:
            if(inDataSize < sizeof(UInt32)) { return kAudioHardwareBadPropertySizeError; }
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            return 0;

        case kAudioDevicePropertyZeroTimeStampPeriod:
            if(inDataSize < sizeof(UInt32)) { return kAudioHardwareBadPropertySizeError; }
            *((UInt32*)outData) = kDevice_RingBufferSize;
            *outDataSize = sizeof(UInt32);
            return 0;

        case kAudioDevicePropertyPreferredChannelsForStereo:
            if(inDataSize < (2 * sizeof(UInt32))) { return kAudioHardwareBadPropertySizeError; }
            ((UInt32*)outData)[0] = 1;
            ((UInt32*)outData)[1] = 2;
            *outDataSize = 2 * sizeof(UInt32);
            return 0;

        case kAudioDevicePropertyPreferredChannelLayout:
        {
            UInt32 theSize = offsetof(AudioChannelLayout, mChannelDescriptions) +
                             (kDevice_ChannelCount * sizeof(AudioChannelDescription));
            if(inDataSize < theSize) { return kAudioHardwareBadPropertySizeError; }
            AudioChannelLayout* theLayout = (AudioChannelLayout*)outData;
            memset(theLayout, 0, theSize);
            theLayout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            theLayout->mChannelBitmap = 0;
            theLayout->mNumberChannelDescriptions = kDevice_ChannelCount;
            theLayout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
            theLayout->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
            *outDataSize = theSize;
            return 0;
        }

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - Public entry points

Boolean SyncCastAudio_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress)
{
    #pragma unused(inDriver, inClientProcessID)
    if(inAddress == NULL) { return false; }
    switch(inObjectID)
    {
        case kObjectID_PlugIn:  return SyncCastAudio_HasPlugInProperty(inAddress);
        case kObjectID_Device:  return SyncCastAudio_HasDeviceProperty(inAddress);
        default:                return SyncCastAudio_StreamControl_HasProperty(inObjectID, inAddress);
    }
}

OSStatus SyncCastAudio_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
    #pragma unused(inDriver, inClientProcessID)
    if((inAddress == NULL) || (outIsSettable == NULL)) { return kAudioHardwareIllegalOperationError; }
    if(!SyncCastAudio_IsKnownObject(inObjectID)) { return kAudioHardwareBadObjectError; }

    switch(inObjectID)
    {
        case kObjectID_PlugIn:
            if(!SyncCastAudio_HasPlugInProperty(inAddress)) { return kAudioHardwareUnknownPropertyError; }
            *outIsSettable = false;
            return 0;

        case kObjectID_Device:
            if(!SyncCastAudio_HasDeviceProperty(inAddress)) { return kAudioHardwareUnknownPropertyError; }
            // The sample rate is the only settable device property: SyncCast
            // pins the device to 48 kHz, and other apps may legitimately move
            // it while SyncCast is not running.
            *outIsSettable = (inAddress->mSelector == kAudioDevicePropertyNominalSampleRate);
            return 0;

        default:
            return SyncCastAudio_StreamControl_IsPropertySettable(inObjectID, inAddress, outIsSettable);
    }
}

OSStatus SyncCastAudio_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize)
{
    #pragma unused(inDriver, inClientProcessID, inQualifierDataSize, inQualifierData)
    if((inAddress == NULL) || (outDataSize == NULL)) { return kAudioHardwareIllegalOperationError; }
    if(!SyncCastAudio_IsKnownObject(inObjectID)) { return kAudioHardwareBadObjectError; }

    switch(inObjectID)
    {
        case kObjectID_PlugIn:  return SyncCastAudio_GetPlugInPropertyDataSize(inAddress, outDataSize);
        case kObjectID_Device:  return SyncCastAudio_GetDevicePropertyDataSize(inAddress, outDataSize);
        default:                return SyncCastAudio_StreamControl_GetPropertyDataSize(inObjectID, inAddress, outDataSize);
    }
}

OSStatus SyncCastAudio_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    #pragma unused(inDriver, inClientProcessID)
    if((inAddress == NULL) || (outDataSize == NULL) || (outData == NULL)) { return kAudioHardwareIllegalOperationError; }
    if(!SyncCastAudio_IsKnownObject(inObjectID)) { return kAudioHardwareBadObjectError; }

    switch(inObjectID)
    {
        case kObjectID_PlugIn:
            return SyncCastAudio_GetPlugInPropertyData(inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
        case kObjectID_Device:
            return SyncCastAudio_GetDevicePropertyData(inAddress, inDataSize, outDataSize, outData);
        default:
            return SyncCastAudio_StreamControl_GetPropertyData(inObjectID, inAddress, inDataSize, outDataSize, outData);
    }
}

OSStatus SyncCastAudio_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData)
{
    #pragma unused(inDriver, inClientProcessID, inQualifierDataSize, inQualifierData)
    if((inAddress == NULL) || (inData == NULL)) { return kAudioHardwareIllegalOperationError; }
    if(!SyncCastAudio_IsKnownObject(inObjectID)) { return kAudioHardwareBadObjectError; }

    UInt32 theNumberPropertiesChanged = 0;
    AudioObjectPropertyAddress theChangedAddresses[2];
    OSStatus theAnswer = 0;

    switch(inObjectID)
    {
        case kObjectID_PlugIn:
            theAnswer = SyncCastAudio_HasPlugInProperty(inAddress)
                ? kAudioHardwareUnsupportedOperationError
                : kAudioHardwareUnknownPropertyError;
            break;

        case kObjectID_Device:
            if(inAddress->mSelector == kAudioDevicePropertyNominalSampleRate)
            {
                if(inDataSize != sizeof(Float64)) { return kAudioHardwareBadPropertySizeError; }
                Float64 theNewRate = *((const Float64*)inData);
                if((theNewRate != kDevice_SampleRate_44100) &&
                   (theNewRate != kDevice_DefaultSampleRate) &&
                   (theNewRate != kDevice_SampleRate_96000))
                {
                    return kAudioHardwareIllegalOperationError;
                }
                pthread_mutex_lock(&gPlugIn_StateMutex);
                Float64 theCurrentRate = gDevice_SampleRate;
                pthread_mutex_unlock(&gPlugIn_StateMutex);
                if(theNewRate != theCurrentRate)
                {
                    // The rate cannot change under a running IO cycle; ask the
                    // host to stop IO, call back into
                    // PerformDeviceConfigurationChange, and restart.
                    if(gPlugIn_Host != NULL)
                    {
                        gPlugIn_Host->RequestDeviceConfigurationChange(
                            gPlugIn_Host, kObjectID_Device, (UInt64)theNewRate, NULL);
                    }
                }
                theAnswer = 0;
            }
            else
            {
                theAnswer = SyncCastAudio_HasDeviceProperty(inAddress)
                    ? kAudioHardwareUnsupportedOperationError
                    : kAudioHardwareUnknownPropertyError;
            }
            break;

        default:
            theAnswer = SyncCastAudio_StreamControl_SetPropertyData(
                inObjectID, inAddress, inDataSize, inData,
                &theNumberPropertiesChanged, theChangedAddresses);
            break;
    }

    // Notification goes out AFTER the state mutex is released (the callee
    // releases it before returning), because the host may re-enter us.
    if((theAnswer == 0) && (theNumberPropertiesChanged > 0) && (gPlugIn_Host != NULL))
    {
        gPlugIn_Host->PropertiesChanged(gPlugIn_Host, inObjectID, theNumberPropertiesChanged, theChangedAddresses);
    }

    return theAnswer;
}
