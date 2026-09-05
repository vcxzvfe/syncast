//
//  SyncCastAudio.h
//  SyncCastAudio.driver — a userland AudioServerPlugIn for SyncCast
//
//  WHY THIS DRIVER EXISTS
//  ---------------------
//  SyncCast's local Stereo path plays one stereo stream on several real
//  speakers at once. macOS has no volume control for that arrangement: an
//  aggregate/multi-output device exposes no kAudioDevicePropertyVolumeScalar,
//  so the menu-bar slider greys out, F11/F12 show the "forbidden" HUD, and
//  third-party helpers (LinearMouse) have nothing to drive. SyncCast used to
//  work around it by intercepting the media keys with a CGEventTap, which
//  needs Accessibility permission and steals the keys from everything else.
//
//  This driver removes that workaround. It publishes ONE ordinary-looking
//  output device that HAS a volume and a mute control. SyncCast makes it the
//  default output, so macOS treats it as a normal, volume-controllable
//  speaker; a Core Audio Process Tap pinned to it captures what apps render
//  (verified pre-driver, so the control below never attenuates what we
//  capture), and SyncCast re-applies the volume on the real speakers.
//
//  The device therefore DISCARDS all audio data — it is a control surface and
//  a capture point, not a loopback. That is also why it deliberately has NO
//  input stream: nothing needs to read from it, and an input stream would put
//  the driver in microphone-shaped territory for TCC.
//
//  Derived from Apple's NullAudio sample (AudioServerPlugIn skeleton,
//  Apple sample-code licence) with the volume/mute controls, the device
//  identity and the sample-rate set replaced.
//

#ifndef SyncCastAudio_h
#define SyncCastAudio_h

#include <CoreAudio/AudioServerPlugIn.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdbool.h>
#include <string.h>

#pragma mark - Identity

// Must match `SystemSinkDevice.syncCastDriverUID` in core/router. The Swift
// side looks the device up by this UID; changing one without the other
// silently disables the whole sink path.
#define kDevice_UID                 "SyncCastAudio_UID"
#define kDevice_ModelUID            "SyncCastAudio_ModelUID"
#define kDevice_Name                "SyncCast"
#define kManufacturer_Name          "SyncCast"
#define kPlugIn_BundleID            "io.syncast.audio.driver"

#pragma mark - Object IDs
//
// A fixed, tiny object graph: the plug-in, one device, one output stream, and
// the two controls that are the entire point of this driver.

#define kObjectID_PlugIn            kAudioObjectPlugInObject
#define kObjectID_Device            2
#define kObjectID_Stream_Output     3
#define kObjectID_Volume_Output     4
#define kObjectID_Mute_Output       5

#pragma mark - Audio format

#define kDevice_ChannelCount        2
#define kDevice_BitsPerChannel      32
#define kDevice_BytesPerFrame       (kDevice_ChannelCount * (kDevice_BitsPerChannel / 8))

// 48 kHz is SyncCast's pipeline rate and the default here; the other two are
// advertised so an app that insists on them still opens the device (macOS
// re-rates the device rather than refusing to play).
#define kDevice_DefaultSampleRate   48000.0
#define kDevice_SampleRate_44100    44100.0
#define kDevice_SampleRate_96000    96000.0

// Zero-timestamp period. The device has no hardware, so the timeline is
// synthesised from the host clock in whole "ring buffer" periods, exactly as
// Apple's sample does. 19200 frames is 400 ms at 48 kHz — long enough that the
// timestamp maths is cheap, short enough that a rate change settles quickly.
#define kDevice_RingBufferSize      19200

#pragma mark - Volume law
//
// Measured on the reference machine (2026-09-05): macOS's built-in speaker
// control is LINEAR IN DECIBELS over [-63.5, 0] dB —
//   scalar 0.00 -> -63.5 dB, 0.25 -> -47.6, 0.50 -> -31.8,
//          0.75 -> -15.9,   0.90 ->  -6.4, 1.00 ->   0.0.
// Advertising the same range and the same curve is what makes this device's
// slider feel identical to the built-in speakers', which is the point: the
// user should not be able to tell that SyncCast is in the path.
//
// The control does NOT scale audio data (there is no audio data to scale).
// SyncCastRouter reads this scalar and re-applies it to the real outputs.

#define kVolume_MinDB               (-63.5f)
#define kVolume_MaxDB               (0.0f)

#pragma mark - Shared state
//
// TWO mutexes, exactly as Apple's NullAudio splits them, because they are
// taken from threads with completely different deadlines:
//
//   gPlugIn_StateMutex   property state — the rate, the ref count, the IO
//                        client count, the volume/mute values. Taken by every
//                        property getter and setter, i.e. by the HAL's
//                        property thread and by any client that reads the
//                        device, so it can be held for as long as a
//                        CFPropertyList write to storage.
//
//   gDevice_IOMutex      timeline state — gDevice_HostTicksPerFrame,
//                        gDevice_NumberTimeStamps, gDevice_AnchorSampleTime,
//                        gDevice_AnchorHostTime. Taken by GetZeroTimeStamp on
//                        the real-time IO thread, and by the (rare) StartIO /
//                        StopIO / PerformDeviceConfigurationChange re-anchor.
//                        Every critical section under it is a handful of
//                        arithmetic ops with no allocation and no CF call, so
//                        the IO thread can never be made to wait on a property
//                        getter.
//
// LOCK ORDER: never hold both at once. Where a path needs both (the rate
// change: rate under the state mutex, the derived tick count and the anchor
// under the IO mutex) it takes them one after the other, state first.

extern pthread_mutex_t              gPlugIn_StateMutex;
extern pthread_mutex_t              gDevice_IOMutex;
extern AudioServerPlugInHostRef     gPlugIn_Host;
extern UInt32                       gPlugIn_RefCount;

// gPlugIn_StateMutex
extern Float64                      gDevice_SampleRate;
extern UInt64                       gDevice_IORunningCounter;
extern Float32                      gVolume_Output_Scalar;
extern bool                         gMute_Output_Value;

// gDevice_IOMutex
extern Float64                      gDevice_HostTicksPerFrame;
extern UInt64                       gDevice_NumberTimeStamps;
extern Float64                      gDevice_AnchorSampleTime;
extern UInt64                       gDevice_AnchorHostTime;

/// Recompute the host-ticks-per-frame from a sample rate. Takes gDevice_IOMutex
/// itself; the caller must NOT hold it (and must not hold the state mutex
/// either — see the lock order above).
void SyncCastAudio_ResetTimeline(Float64 inSampleRate);

#pragma mark - Volume law helpers (pure)

Float32 SyncCastAudio_ScalarToDecibels(Float32 inScalar);
Float32 SyncCastAudio_DecibelsToScalar(Float32 inDecibels);
Float32 SyncCastAudio_ClampScalar(Float32 inScalar);

#pragma mark - Property implementation (SyncCastAudioProperties.c)

Boolean SyncCastAudio_HasProperty(AudioServerPlugInDriverRef inDriver,
                                  AudioObjectID inObjectID,
                                  pid_t inClientProcessID,
                                  const AudioObjectPropertyAddress* inAddress);

OSStatus SyncCastAudio_IsPropertySettable(AudioServerPlugInDriverRef inDriver,
                                          AudioObjectID inObjectID,
                                          pid_t inClientProcessID,
                                          const AudioObjectPropertyAddress* inAddress,
                                          Boolean* outIsSettable);

OSStatus SyncCastAudio_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                           AudioObjectID inObjectID,
                                           pid_t inClientProcessID,
                                           const AudioObjectPropertyAddress* inAddress,
                                           UInt32 inQualifierDataSize,
                                           const void* inQualifierData,
                                           UInt32* outDataSize);

OSStatus SyncCastAudio_GetPropertyData(AudioServerPlugInDriverRef inDriver,
                                       AudioObjectID inObjectID,
                                       pid_t inClientProcessID,
                                       const AudioObjectPropertyAddress* inAddress,
                                       UInt32 inQualifierDataSize,
                                       const void* inQualifierData,
                                       UInt32 inDataSize,
                                       UInt32* outDataSize,
                                       void* outData);

OSStatus SyncCastAudio_SetPropertyData(AudioServerPlugInDriverRef inDriver,
                                       AudioObjectID inObjectID,
                                       pid_t inClientProcessID,
                                       const AudioObjectPropertyAddress* inAddress,
                                       UInt32 inQualifierDataSize,
                                       const void* inQualifierData,
                                       UInt32 inDataSize,
                                       const void* inData);

#pragma mark - Stream + control properties (SyncCastAudioStreamControls.c)
//
// Same signatures as the entry points above, minus the driver ref: the public
// entry points validate the driver and the object id, then dispatch here for
// the output stream and the two controls. Split across two files only to keep
// each one readable — the object graph is one unit.

/// Write any volume/mute change that has not reached storage yet.
///
/// The volume setter is called once per scroll tick / arrow key, so it marks
/// the value dirty and lets this coalesce the writes; `inForce` bypasses the
/// rate limit and is what StopIO uses to make sure the final level is on disk.
///
/// Storage writes allocate and touch the filesystem: call this from the
/// property/control path only, NEVER from the IO thread.
void SyncCastAudio_FlushPersistentState(Boolean inForce);

Boolean SyncCastAudio_StreamControl_HasProperty(AudioObjectID inObjectID,
                                                const AudioObjectPropertyAddress* inAddress);

OSStatus SyncCastAudio_StreamControl_IsPropertySettable(AudioObjectID inObjectID,
                                                        const AudioObjectPropertyAddress* inAddress,
                                                        Boolean* outIsSettable);

OSStatus SyncCastAudio_StreamControl_GetPropertyDataSize(AudioObjectID inObjectID,
                                                         const AudioObjectPropertyAddress* inAddress,
                                                         UInt32* outDataSize);

OSStatus SyncCastAudio_StreamControl_GetPropertyData(AudioObjectID inObjectID,
                                                     const AudioObjectPropertyAddress* inAddress,
                                                     UInt32 inDataSize,
                                                     UInt32* outDataSize,
                                                     void* outData);

OSStatus SyncCastAudio_StreamControl_SetPropertyData(AudioObjectID inObjectID,
                                                     const AudioObjectPropertyAddress* inAddress,
                                                     UInt32 inDataSize,
                                                     const void* inData,
                                                     UInt32* outNumberPropertiesChanged,
                                                     AudioObjectPropertyAddress outChangedAddresses[2]);

#endif /* SyncCastAudio_h */
