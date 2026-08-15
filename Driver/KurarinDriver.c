// Kurarin Microphone — a minimal loopback Audio Server plug-in.
//
// The device exposes one output stream and one input stream over a shared ring
// buffer: whatever an application writes to the output comes back out of the
// input. Kurarin.app is the writer; Discord, Roblox and friends are the readers.
//
// Everything that can change at runtime lives in the app, not here. This plug-in
// is hosted inside coreaudiod, so a crash takes down audio for the whole machine
// and every fix costs an admin password and a daemon restart. It stays small.

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

#pragma mark - Configuration

#define kDevice_Name            "Kurarin Microphone"
#define kDevice_UID             "com.byeolki.kurarin.microphone"
#define kDevice_ModelUID        "com.byeolki.kurarin.microphone.model"
#define kBox_UID                "com.byeolki.kurarin.box"
#define kManufacturer_Name      "Kurarin"

#define kChannelCount           2
#define kRingFrames             65536   // power of two, ~1.4 s at 48 kHz
#define kRingMask               (kRingFrames - 1)

// How long the input keeps echoing the ring after the last write before it
// falls back to silence. Bounds how much stale audio a listener can hear when
// the app stops its render callback.
#define kWriterTimeoutNanos     100000000ULL  // 100 ms

#define kZeroTimeStampPeriod    kRingFrames
#define kLatency_Frames         0
#define kSafetyOffset_Frames    0

enum {
    kObjectID_PlugIn        = kAudioObjectPlugInObject,
    kObjectID_Box           = 2,
    kObjectID_Device        = 3,
    kObjectID_Stream_Input  = 4,
    kObjectID_Stream_Output = 5
};

static const Float64 kSupportedSampleRates[] = { 44100.0, 48000.0, 96000.0 };
static const UInt32  kSupportedSampleRateCount =
    sizeof(kSupportedSampleRates) / sizeof(kSupportedSampleRates[0]);

#pragma mark - Driver state

// gStateMutex guards everything below except the ring buffer and the fields
// marked as IO-thread state, which are only touched from the real-time thread.
static pthread_mutex_t              gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static AudioServerPlugInDriverRef   gDriverRef  = NULL;
static AudioServerPlugInHostRef     gHost       = NULL;
static UInt32                       gRefCount   = 0;

static Float64  gSampleRate         = 48000.0;
static Float64  gPendingSampleRate  = 0.0;
static UInt32   gDeviceRunCount     = 0;
static bool     gBoxAcquired        = true;
static bool     gInputStreamActive  = true;
static bool     gOutputStreamActive = true;

// Ring buffer shared between the write and read halves of the loopback.
static Float32  gRing[kRingFrames * kChannelCount];
static volatile uint64_t gLastWriteHostTime = 0;

// Zero timestamp bookkeeping, IO thread only.
static UInt64   gAnchorHostTime     = 0;
static UInt64   gAnchorSampleTime   = 0;
static UInt64   gTimestampCount     = 0;
static Float64  gHostTicksPerFrame  = 0.0;

static Float64 HostTicksPerSecond(void)
{
    static Float64 sTicksPerSecond = 0.0;
    if (sTicksPerSecond == 0.0) {
        struct mach_timebase_info info;
        mach_timebase_info(&info);
        sTicksPerSecond = 1000000000.0 * ((Float64)info.denom / (Float64)info.numer);
    }
    return sTicksPerSecond;
}

// Built on the cached tick rate rather than caching the timebase struct here.
// Two IO threads reaching an uninitialised two-field cache at the same moment
// can see one field written and the other not, and the not-yet-written one is
// the divisor — a division by zero inside coreaudiod. A single scalar cache
// has no such window: the worst two threads can do is compute the same value
// twice.
static uint64_t NanosToHostTicks(uint64_t inNanos)
{
    return (uint64_t)((Float64)inNanos * HostTicksPerSecond() / 1000000000.0);
}

#pragma mark - Prototypes

static HRESULT      Kurarin_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG        Kurarin_AddRef(void* inDriver);
static ULONG        Kurarin_Release(void* inDriver);
static OSStatus     Kurarin_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus     Kurarin_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus     Kurarin_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus     Kurarin_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus     Kurarin_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus     Kurarin_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static OSStatus     Kurarin_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static Boolean      Kurarin_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus     Kurarin_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus     Kurarin_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus     Kurarin_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus     Kurarin_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData);
static OSStatus     Kurarin_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus     Kurarin_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus     Kurarin_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus     Kurarin_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
static OSStatus     Kurarin_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
static OSStatus     Kurarin_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer);
static OSStatus     Kurarin_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

#pragma mark - Interface table

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    Kurarin_QueryInterface,
    Kurarin_AddRef,
    Kurarin_Release,
    Kurarin_Initialize,
    Kurarin_CreateDevice,
    Kurarin_DestroyDevice,
    Kurarin_AddDeviceClient,
    Kurarin_RemoveDeviceClient,
    Kurarin_PerformDeviceConfigurationChange,
    Kurarin_AbortDeviceConfigurationChange,
    Kurarin_HasProperty,
    Kurarin_IsPropertySettable,
    Kurarin_GetPropertyDataSize,
    Kurarin_GetPropertyData,
    Kurarin_SetPropertyData,
    Kurarin_StartIO,
    Kurarin_StopIO,
    Kurarin_GetZeroTimeStamp,
    Kurarin_WillDoIOOperation,
    Kurarin_BeginIOOperation,
    Kurarin_DoIOOperation,
    Kurarin_EndIOOperation
};

static AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;

// Referenced by CFPlugInFactories in Info.plist.
void* KurarinCreate(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
void* KurarinCreate(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID)
{
    (void)inAllocator;
    if (!CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return NULL;
    }
    return &gInterfacePtr;
}

#pragma mark - COM plumbing

static HRESULT Kurarin_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface)
{
    if (inDriver != &gInterfacePtr || outInterface == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (requested == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) ||
        CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gStateMutex);
        ++gRefCount;
        pthread_mutex_unlock(&gStateMutex);
        *outInterface = &gInterfacePtr;
        result = S_OK;
    }

    CFRelease(requested);
    return result;
}

static ULONG Kurarin_AddRef(void* inDriver)
{
    if (inDriver != &gInterfacePtr) {
        return 0;
    }
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount < UINT32_MAX) {
        ++gRefCount;
    }
    ULONG result = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return result;
}

static ULONG Kurarin_Release(void* inDriver)
{
    if (inDriver != &gInterfacePtr) {
        return 0;
    }
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount > 0) {
        --gRefCount;
    }
    ULONG result = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return result;
}

#pragma mark - Lifecycle

static OSStatus Kurarin_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)
{
    if (inDriver != &gInterfacePtr) {
        return kAudioHardwareBadObjectError;
    }
    gDriverRef = inDriver;
    gHost = inHost;
    memset(gRing, 0, sizeof(gRing));
    gHostTicksPerFrame = HostTicksPerSecond() / gSampleRate;
    return 0;
}

// The device is static, so the dynamic device calls are all unsupported.
static OSStatus Kurarin_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID)
{
    (void)inDriver; (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus Kurarin_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID)
{
    (void)inDriver; (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus Kurarin_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo)
{
    (void)inClientInfo;
    if (inDriver != &gInterfacePtr) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return 0;
}

static OSStatus Kurarin_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo)
{
    (void)inClientInfo;
    if (inDriver != &gInterfacePtr) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return 0;
}

static OSStatus Kurarin_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo)
{
    (void)inChangeInfo;
    if (inDriver != &gInterfacePtr) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;

    // inChangeAction carries the new sample rate, encoded by the requester below.
    Float64 requested = 0.0;
    for (UInt32 i = 0; i < kSupportedSampleRateCount; ++i) {
        if ((UInt64)kSupportedSampleRates[i] == inChangeAction) {
            requested = kSupportedSampleRates[i];
            break;
        }
    }
    if (requested == 0.0) {
        return kAudioHardwareIllegalOperationError;
    }

    pthread_mutex_lock(&gStateMutex);
    gSampleRate = requested;
    gPendingSampleRate = 0.0;
    gHostTicksPerFrame = HostTicksPerSecond() / gSampleRate;
    memset(gRing, 0, sizeof(gRing));
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus Kurarin_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo)
{
    (void)inChangeAction; (void)inChangeInfo;
    if (inDriver != &gInterfacePtr) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    gPendingSampleRate = 0.0;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

#pragma mark - Property helpers

static void FillStreamFormat(AudioStreamBasicDescription* outFormat, Float64 inSampleRate)
{
    outFormat->mSampleRate       = inSampleRate;
    outFormat->mFormatID         = kAudioFormatLinearPCM;
    outFormat->mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    outFormat->mBytesPerPacket   = kChannelCount * sizeof(Float32);
    outFormat->mFramesPerPacket  = 1;
    outFormat->mBytesPerFrame    = kChannelCount * sizeof(Float32);
    outFormat->mChannelsPerFrame = kChannelCount;
    outFormat->mBitsPerChannel   = 32;
    outFormat->mReserved         = 0;
}

static Boolean IsStreamObject(AudioObjectID inObjectID)
{
    return inObjectID == kObjectID_Stream_Input || inObjectID == kObjectID_Stream_Output;
}

#pragma mark - HasProperty

static Boolean Kurarin_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress)
{
    (void)inClientProcessID;
    if (inDriver != &gInterfacePtr || inAddress == NULL) {
        return false;
    }

    UInt32 size = 0;
    OSStatus status = Kurarin_GetPropertyDataSize(inDriver, inObjectID, inClientProcessID, inAddress, 0, NULL, &size);
    return status == 0;
}

#pragma mark - IsPropertySettable

static OSStatus Kurarin_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
    (void)inClientProcessID;
    if (inDriver != &gInterfacePtr || inAddress == NULL || outIsSettable == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    *outIsSettable = false;

    if (inObjectID == kObjectID_Device) {
        if (inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) {
            *outIsSettable = true;
        }
    } else if (IsStreamObject(inObjectID)) {
        if (inAddress->mSelector == kAudioStreamPropertyIsActive) {
            *outIsSettable = true;
        }
    } else if (inObjectID == kObjectID_Box) {
        if (inAddress->mSelector == kAudioObjectPropertyIdentify ||
            inAddress->mSelector == kAudioBoxPropertyAcquired) {
            *outIsSettable = true;
        }
    }

    return 0;
}

#pragma mark - GetPropertyDataSize

static OSStatus Kurarin_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize)
{
    (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inDriver != &gInterfacePtr || inAddress == NULL || outDataSize == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    switch (inObjectID) {
        case kObjectID_PlugIn:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:            *outDataSize = sizeof(AudioClassID); return 0;
                case kAudioObjectPropertyOwner:            *outDataSize = sizeof(AudioObjectID); return 0;
                case kAudioObjectPropertyManufacturer:     *outDataSize = sizeof(CFStringRef); return 0;
                case kAudioObjectPropertyOwnedObjects:     *outDataSize = 2 * sizeof(AudioObjectID); return 0;
                case kAudioPlugInPropertyBoxList:          *outDataSize = sizeof(AudioObjectID); return 0;
                case kAudioPlugInPropertyTranslateUIDToBox:*outDataSize = sizeof(AudioObjectID); return 0;
                case kAudioPlugInPropertyDeviceList:       *outDataSize = sizeof(AudioObjectID); return 0;
                case kAudioPlugInPropertyTranslateUIDToDevice: *outDataSize = sizeof(AudioObjectID); return 0;
                case kAudioPlugInPropertyResourceBundle:   *outDataSize = sizeof(CFStringRef); return 0;
                default: return kAudioHardwareUnknownPropertyError;
            }

        case kObjectID_Box:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:            *outDataSize = sizeof(AudioClassID); return 0;
                case kAudioObjectPropertyOwner:            *outDataSize = sizeof(AudioObjectID); return 0;
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyModelName:
                case kAudioObjectPropertyManufacturer:
                case kAudioObjectPropertySerialNumber:
                case kAudioObjectPropertyFirmwareVersion:
                case kAudioBoxPropertyBoxUID:              *outDataSize = sizeof(CFStringRef); return 0;
                case kAudioObjectPropertyOwnedObjects:
                case kAudioBoxPropertyDeviceList:          *outDataSize = gBoxAcquired ? sizeof(AudioObjectID) : 0; return 0;
                case kAudioObjectPropertyIdentify:
                case kAudioBoxPropertyTransportType:
                case kAudioBoxPropertyHasAudio:
                case kAudioBoxPropertyHasVideo:
                case kAudioBoxPropertyHasMIDI:
                case kAudioBoxPropertyIsProtected:
                case kAudioBoxPropertyAcquired:            *outDataSize = sizeof(UInt32); return 0;
                case kAudioBoxPropertyAcquisitionFailed:   *outDataSize = sizeof(UInt32); return 0;
                case kAudioBoxPropertyClockDeviceList:     *outDataSize = 0; return 0;
                default: return kAudioHardwareUnknownPropertyError;
            }

        case kObjectID_Device:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:            *outDataSize = sizeof(AudioClassID); return 0;
                case kAudioObjectPropertyOwner:            *outDataSize = sizeof(AudioObjectID); return 0;
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyManufacturer:
                case kAudioDevicePropertyDeviceUID:
                case kAudioDevicePropertyModelUID:         *outDataSize = sizeof(CFStringRef); return 0;
                case kAudioObjectPropertyOwnedObjects:     *outDataSize = 2 * sizeof(AudioObjectID); return 0;
                case kAudioDevicePropertyStreams:
                    switch (inAddress->mScope) {
                        case kAudioObjectPropertyScopeGlobal: *outDataSize = 2 * sizeof(AudioObjectID); return 0;
                        case kAudioObjectPropertyScopeInput:
                        case kAudioObjectPropertyScopeOutput: *outDataSize = sizeof(AudioObjectID); return 0;
                        default: *outDataSize = 0; return 0;
                    }
                case kAudioObjectPropertyControlList:      *outDataSize = 0; return 0;
                case kAudioDevicePropertyTransportType:
                case kAudioDevicePropertyClockDomain:
                case kAudioDevicePropertyDeviceIsAlive:
                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertySafetyOffset:
                case kAudioDevicePropertyZeroTimeStampPeriod:
                case kAudioDevicePropertyIsHidden:         *outDataSize = sizeof(UInt32); return 0;
                case kAudioDevicePropertyRelatedDevices:   *outDataSize = sizeof(AudioObjectID); return 0;
                case kAudioDevicePropertyNominalSampleRate: *outDataSize = sizeof(Float64); return 0;
                case kAudioDevicePropertyAvailableNominalSampleRates:
                    *outDataSize = kSupportedSampleRateCount * sizeof(AudioValueRange); return 0;
                case kAudioDevicePropertyPreferredChannelsForStereo:
                    *outDataSize = 2 * sizeof(UInt32); return 0;
                case kAudioDevicePropertyPreferredChannelLayout:
                    *outDataSize = offsetof(AudioChannelLayout, mChannelDescriptions) + (kChannelCount * sizeof(AudioChannelDescription));
                    return 0;
                default: return kAudioHardwareUnknownPropertyError;
            }

        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:            *outDataSize = sizeof(AudioClassID); return 0;
                case kAudioObjectPropertyOwner:            *outDataSize = sizeof(AudioObjectID); return 0;
                case kAudioObjectPropertyOwnedObjects:     *outDataSize = 0; return 0;
                case kAudioStreamPropertyIsActive:
                case kAudioStreamPropertyDirection:
                case kAudioStreamPropertyTerminalType:
                case kAudioStreamPropertyStartingChannel:
                case kAudioStreamPropertyLatency:          *outDataSize = sizeof(UInt32); return 0;
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:   *outDataSize = sizeof(AudioStreamBasicDescription); return 0;
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats:
                    *outDataSize = kSupportedSampleRateCount * sizeof(AudioStreamRangedDescription); return 0;
                default: return kAudioHardwareUnknownPropertyError;
            }

        default:
            return kAudioHardwareBadObjectError;
    }
}

#pragma mark - GetPropertyData

static OSStatus Kurarin_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    (void)inClientProcessID;
    if (inDriver != &gInterfacePtr || inAddress == NULL || outDataSize == NULL || outData == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    #define REQUIRE(bytes) if (inDataSize < (bytes)) { return kAudioHardwareBadPropertySizeError; }

    switch (inObjectID) {
        case kObjectID_PlugIn:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    REQUIRE(sizeof(AudioClassID));
                    *(AudioClassID*)outData = kAudioObjectClassID;
                    *outDataSize = sizeof(AudioClassID); return 0;
                case kAudioObjectPropertyClass:
                    REQUIRE(sizeof(AudioClassID));
                    *(AudioClassID*)outData = kAudioPlugInClassID;
                    *outDataSize = sizeof(AudioClassID); return 0;
                case kAudioObjectPropertyOwner:
                    REQUIRE(sizeof(AudioObjectID));
                    *(AudioObjectID*)outData = kAudioObjectUnknown;
                    *outDataSize = sizeof(AudioObjectID); return 0;
                case kAudioObjectPropertyManufacturer:
                    REQUIRE(sizeof(CFStringRef));
                    *(CFStringRef*)outData = CFSTR(kManufacturer_Name);
                    CFRetain(*(CFStringRef*)outData);
                    *outDataSize = sizeof(CFStringRef); return 0;
                case kAudioObjectPropertyOwnedObjects: {
                    AudioObjectID owned[2] = { kObjectID_Box, kObjectID_Device };
                    UInt32 count = inDataSize / sizeof(AudioObjectID);
                    if (count > 2) count = 2;
                    memcpy(outData, owned, count * sizeof(AudioObjectID));
                    *outDataSize = count * sizeof(AudioObjectID); return 0;
                }
                case kAudioPlugInPropertyBoxList: {
                    REQUIRE(sizeof(AudioObjectID));
                    *(AudioObjectID*)outData = kObjectID_Box;
                    *outDataSize = sizeof(AudioObjectID); return 0;
                }
                case kAudioPlugInPropertyTranslateUIDToBox: {
                    REQUIRE(sizeof(AudioObjectID));
                    if (inQualifierDataSize != sizeof(CFStringRef) || inQualifierData == NULL) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    CFStringRef uid = *(const CFStringRef*)inQualifierData;
                    *(AudioObjectID*)outData = CFStringCompare(uid, CFSTR(kBox_UID), 0) == kCFCompareEqualTo
                        ? kObjectID_Box : kAudioObjectUnknown;
                    *outDataSize = sizeof(AudioObjectID); return 0;
                }
                case kAudioPlugInPropertyDeviceList: {
                    UInt32 count = inDataSize / sizeof(AudioObjectID);
                    if (count >= 1 && gBoxAcquired) {
                        *(AudioObjectID*)outData = kObjectID_Device;
                        *outDataSize = sizeof(AudioObjectID);
                    } else {
                        *outDataSize = 0;
                    }
                    return 0;
                }
                case kAudioPlugInPropertyTranslateUIDToDevice: {
                    REQUIRE(sizeof(AudioObjectID));
                    if (inQualifierDataSize != sizeof(CFStringRef) || inQualifierData == NULL) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    CFStringRef uid = *(const CFStringRef*)inQualifierData;
                    *(AudioObjectID*)outData = CFStringCompare(uid, CFSTR(kDevice_UID), 0) == kCFCompareEqualTo
                        ? kObjectID_Device : kAudioObjectUnknown;
                    *outDataSize = sizeof(AudioObjectID); return 0;
                }
                case kAudioPlugInPropertyResourceBundle:
                    REQUIRE(sizeof(CFStringRef));
                    *(CFStringRef*)outData = CFSTR("");
                    *outDataSize = sizeof(CFStringRef); return 0;
                default:
                    return kAudioHardwareUnknownPropertyError;
            }

        case kObjectID_Box:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    REQUIRE(sizeof(AudioClassID));
                    *(AudioClassID*)outData = kAudioObjectClassID;
                    *outDataSize = sizeof(AudioClassID); return 0;
                case kAudioObjectPropertyClass:
                    REQUIRE(sizeof(AudioClassID));
                    *(AudioClassID*)outData = kAudioBoxClassID;
                    *outDataSize = sizeof(AudioClassID); return 0;
                case kAudioObjectPropertyOwner:
                    REQUIRE(sizeof(AudioObjectID));
                    *(AudioObjectID*)outData = kObjectID_PlugIn;
                    *outDataSize = sizeof(AudioObjectID); return 0;
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyModelName:
                    REQUIRE(sizeof(CFStringRef));
                    *(CFStringRef*)outData = CFSTR(kDevice_Name);
                    CFRetain(*(CFStringRef*)outData);
                    *outDataSize = sizeof(CFStringRef); return 0;
                case kAudioObjectPropertyManufacturer:
                    REQUIRE(sizeof(CFStringRef));
                    *(CFStringRef*)outData = CFSTR(kManufacturer_Name);
                    CFRetain(*(CFStringRef*)outData);
                    *outDataSize = sizeof(CFStringRef); return 0;
                case kAudioObjectPropertySerialNumber:
                case kAudioObjectPropertyFirmwareVersion:
                    REQUIRE(sizeof(CFStringRef));
                    *(CFStringRef*)outData = CFSTR("1.0");
                    CFRetain(*(CFStringRef*)outData);
                    *outDataSize = sizeof(CFStringRef); return 0;
                case kAudioBoxPropertyBoxUID:
                    REQUIRE(sizeof(CFStringRef));
                    *(CFStringRef*)outData = CFSTR(kBox_UID);
                    CFRetain(*(CFStringRef*)outData);
                    *outDataSize = sizeof(CFStringRef); return 0;
                case kAudioObjectPropertyIdentify:
                    REQUIRE(sizeof(UInt32));
                    *(UInt32*)outData = 0;
                    *outDataSize = sizeof(UInt32); return 0;
                case kAudioBoxPropertyTransportType:
                    REQUIRE(sizeof(UInt32));
                    *(UInt32*)outData = kAudioDeviceTransportTypeVirtual;
                    *outDataSize = sizeof(UInt32); return 0;
                case kAudioBoxPropertyHasAudio:
                    REQUIRE(sizeof(UInt32));
                    *(UInt32*)outData = 1;
                    *outDataSize = sizeof(UInt32); return 0;
                case kAudioBoxPropertyHasVideo:
                case kAudioBoxPropertyHasMIDI:
                case kAudioBoxPropertyIsProtected:
                case kAudioBoxPropertyAcquisitionFailed:
                    REQUIRE(sizeof(UInt32));
                    *(UInt32*)outData = 0;
                    *outDataSize = sizeof(UInt32); return 0;
                case kAudioBoxPropertyAcquired:
                    REQUIRE(sizeof(UInt32));
                    pthread_mutex_lock(&gStateMutex);
                    *(UInt32*)outData = gBoxAcquired ? 1 : 0;
                    pthread_mutex_unlock(&gStateMutex);
                    *outDataSize = sizeof(UInt32); return 0;
                case kAudioObjectPropertyOwnedObjects:
                case kAudioBoxPropertyDeviceList: {
                    UInt32 count = inDataSize / sizeof(AudioObjectID);
                    pthread_mutex_lock(&gStateMutex);
                    bool acquired = gBoxAcquired;
                    pthread_mutex_unlock(&gStateMutex);
                    if (acquired && count >= 1) {
                        *(AudioObjectID*)outData = kObjectID_Device;
                        *outDataSize = sizeof(AudioObjectID);
                    } else {
                        *outDataSize = 0;
                    }
                    return 0;
                }
                case kAudioBoxPropertyClockDeviceList:
                    *outDataSize = 0; return 0;
                default:
                    return kAudioHardwareUnknownPropertyError;
            }

        case kObjectID_Device:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    REQUIRE(sizeof(AudioClassID));
                    *(AudioClassID*)outData = kAudioObjectClassID;
                    *outDataSize = sizeof(AudioClassID); return 0;
                case kAudioObjectPropertyClass:
                    REQUIRE(sizeof(AudioClassID));
                    *(AudioClassID*)outData = kAudioDeviceClassID;
                    *outDataSize = sizeof(AudioClassID); return 0;
                case kAudioObjectPropertyOwner:
                    REQUIRE(sizeof(AudioObjectID));
                    *(AudioObjectID*)outData = kObjectID_PlugIn;
                    *outDataSize = sizeof(AudioObjectID); return 0;
                case kAudioObjectPropertyName:
                    REQUIRE(sizeof(CFStringRef));
                    *(CFStringRef*)outData = CFSTR(kDevice_Name);
                    CFRetain(*(CFStringRef*)outData);
                    *outDataSize = sizeof(CFStringRef); return 0;
                case kAudioObjectPropertyManufacturer:
                    REQUIRE(sizeof(CFStringRef));
                    *(CFStringRef*)outData = CFSTR(kManufacturer_Name);
                    CFRetain(*(CFStringRef*)outData);
                    *outDataSize = sizeof(CFStringRef); return 0;
                case kAudioDevicePropertyDeviceUID:
                    REQUIRE(sizeof(CFStringRef));
                    *(CFStringRef*)outData = CFSTR(kDevice_UID);
                    CFRetain(*(CFStringRef*)outData);
                    *outDataSize = sizeof(CFStringRef); return 0;
                case kAudioDevicePropertyModelUID:
                    REQUIRE(sizeof(CFStringRef));
                    *(CFStringRef*)outData = CFSTR(kDevice_ModelUID);
                    CFRetain(*(CFStringRef*)outData);
                    *outDataSize = sizeof(CFStringRef); return 0;
                case kAudioObjectPropertyOwnedObjects: {
                    AudioObjectID owned[2] = { kObjectID_Stream_Input, kObjectID_Stream_Output };
                    UInt32 count = inDataSize / sizeof(AudioObjectID);
                    if (count > 2) count = 2;
                    memcpy(outData, owned, count * sizeof(AudioObjectID));
                    *outDataSize = count * sizeof(AudioObjectID); return 0;
                }
                case kAudioDevicePropertyStreams: {
                    AudioObjectID streams[2];
                    UInt32 available = 0;
                    switch (inAddress->mScope) {
                        case kAudioObjectPropertyScopeGlobal:
                            streams[0] = kObjectID_Stream_Input;
                            streams[1] = kObjectID_Stream_Output;
                            available = 2;
                            break;
                        case kAudioObjectPropertyScopeInput:
                            streams[0] = kObjectID_Stream_Input;
                            available = 1;
                            break;
                        case kAudioObjectPropertyScopeOutput:
                            streams[0] = kObjectID_Stream_Output;
                            available = 1;
                            break;
                        default:
                            available = 0;
                            break;
                    }
                    UInt32 count = inDataSize / sizeof(AudioObjectID);
                    if (count > available) count = available;
                    memcpy(outData, streams, count * sizeof(AudioObjectID));
                    *outDataSize = count * sizeof(AudioObjectID); return 0;
                }
                case kAudioObjectPropertyControlList:
                    *outDataSize = 0; return 0;
                case kAudioDevicePropertyTransportType:
                    REQUIRE(sizeof(UInt32));
                    *(UInt32*)outData = kAudioDeviceTransportTypeVirtual;
                    *outDataSize = sizeof(UInt32); return 0;
                case kAudioDevicePropertyRelatedDevices:
                    REQUIRE(sizeof(AudioObjectID));
                    *(AudioObjectID*)outData = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID); return 0;
                case kAudioDevicePropertyClockDomain:
                    REQUIRE(sizeof(UInt32));
                    *(UInt32*)outData = 0;
                    *outDataSize = sizeof(UInt32); return 0;
                case kAudioDevicePropertyDeviceIsAlive:
                    REQUIRE(sizeof(UInt32));
                    *(UInt32*)outData = 1;
                    *outDataSize = sizeof(UInt32); return 0;
                case kAudioDevicePropertyDeviceIsRunning:
                    REQUIRE(sizeof(UInt32));
                    pthread_mutex_lock(&gStateMutex);
                    *(UInt32*)outData = gDeviceRunCount > 0 ? 1 : 0;
                    pthread_mutex_unlock(&gStateMutex);
                    *outDataSize = sizeof(UInt32); return 0;
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                    REQUIRE(sizeof(UInt32));
                    *(UInt32*)outData = 1;
                    *outDataSize = sizeof(UInt32); return 0;
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                    // Keep alerts and system beeps out of the virtual microphone.
                    REQUIRE(sizeof(UInt32));
                    *(UInt32*)outData = 0;
                    *outDataSize = sizeof(UInt32); return 0;
                case kAudioDevicePropertyLatency:
                    REQUIRE(sizeof(UInt32));
                    *(UInt32*)outData = kLatency_Frames;
                    *outDataSize = sizeof(UInt32); return 0;
                case kAudioDevicePropertySafetyOffset:
                    REQUIRE(sizeof(UInt32));
                    *(UInt32*)outData = kSafetyOffset_Frames;
                    *outDataSize = sizeof(UInt32); return 0;
                case kAudioDevicePropertyNominalSampleRate:
                    REQUIRE(sizeof(Float64));
                    pthread_mutex_lock(&gStateMutex);
                    *(Float64*)outData = gSampleRate;
                    pthread_mutex_unlock(&gStateMutex);
                    *outDataSize = sizeof(Float64); return 0;
                case kAudioDevicePropertyAvailableNominalSampleRates: {
                    UInt32 count = inDataSize / sizeof(AudioValueRange);
                    if (count > kSupportedSampleRateCount) count = kSupportedSampleRateCount;
                    AudioValueRange* ranges = (AudioValueRange*)outData;
                    for (UInt32 i = 0; i < count; ++i) {
                        ranges[i].mMinimum = kSupportedSampleRates[i];
                        ranges[i].mMaximum = kSupportedSampleRates[i];
                    }
                    *outDataSize = count * sizeof(AudioValueRange); return 0;
                }
                case kAudioDevicePropertyPreferredChannelsForStereo: {
                    REQUIRE(2 * sizeof(UInt32));
                    ((UInt32*)outData)[0] = 1;
                    ((UInt32*)outData)[1] = 2;
                    *outDataSize = 2 * sizeof(UInt32); return 0;
                }
                case kAudioDevicePropertyPreferredChannelLayout: {
                    UInt32 needed = offsetof(AudioChannelLayout, mChannelDescriptions) + (kChannelCount * sizeof(AudioChannelDescription));
                    REQUIRE(needed);
                    AudioChannelLayout* layout = (AudioChannelLayout*)outData;
                    layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
                    layout->mChannelBitmap = 0;
                    layout->mNumberChannelDescriptions = kChannelCount;
                    for (UInt32 i = 0; i < kChannelCount; ++i) {
                        layout->mChannelDescriptions[i].mChannelLabel = kAudioChannelLabel_Left + i;
                        layout->mChannelDescriptions[i].mChannelFlags = 0;
                        layout->mChannelDescriptions[i].mCoordinates[0] = 0;
                        layout->mChannelDescriptions[i].mCoordinates[1] = 0;
                        layout->mChannelDescriptions[i].mCoordinates[2] = 0;
                    }
                    *outDataSize = needed; return 0;
                }
                case kAudioDevicePropertyZeroTimeStampPeriod:
                    REQUIRE(sizeof(UInt32));
                    *(UInt32*)outData = kZeroTimeStampPeriod;
                    *outDataSize = sizeof(UInt32); return 0;
                case kAudioDevicePropertyIsHidden:
                    REQUIRE(sizeof(UInt32));
                    *(UInt32*)outData = 0;
                    *outDataSize = sizeof(UInt32); return 0;
                default:
                    return kAudioHardwareUnknownPropertyError;
            }

        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    REQUIRE(sizeof(AudioClassID));
                    *(AudioClassID*)outData = kAudioObjectClassID;
                    *outDataSize = sizeof(AudioClassID); return 0;
                case kAudioObjectPropertyClass:
                    REQUIRE(sizeof(AudioClassID));
                    *(AudioClassID*)outData = kAudioStreamClassID;
                    *outDataSize = sizeof(AudioClassID); return 0;
                case kAudioObjectPropertyOwner:
                    REQUIRE(sizeof(AudioObjectID));
                    *(AudioObjectID*)outData = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID); return 0;
                case kAudioObjectPropertyOwnedObjects:
                    *outDataSize = 0; return 0;
                case kAudioStreamPropertyIsActive:
                    REQUIRE(sizeof(UInt32));
                    pthread_mutex_lock(&gStateMutex);
                    *(UInt32*)outData = (inObjectID == kObjectID_Stream_Input ? gInputStreamActive : gOutputStreamActive) ? 1 : 0;
                    pthread_mutex_unlock(&gStateMutex);
                    *outDataSize = sizeof(UInt32); return 0;
                case kAudioStreamPropertyDirection:
                    REQUIRE(sizeof(UInt32));
                    *(UInt32*)outData = (inObjectID == kObjectID_Stream_Input) ? 1 : 0;
                    *outDataSize = sizeof(UInt32); return 0;
                case kAudioStreamPropertyTerminalType:
                    REQUIRE(sizeof(UInt32));
                    *(UInt32*)outData = (inObjectID == kObjectID_Stream_Input)
                        ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker;
                    *outDataSize = sizeof(UInt32); return 0;
                case kAudioStreamPropertyStartingChannel:
                    REQUIRE(sizeof(UInt32));
                    *(UInt32*)outData = 1;
                    *outDataSize = sizeof(UInt32); return 0;
                case kAudioStreamPropertyLatency:
                    REQUIRE(sizeof(UInt32));
                    *(UInt32*)outData = 0;
                    *outDataSize = sizeof(UInt32); return 0;
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat: {
                    REQUIRE(sizeof(AudioStreamBasicDescription));
                    pthread_mutex_lock(&gStateMutex);
                    Float64 rate = gSampleRate;
                    pthread_mutex_unlock(&gStateMutex);
                    FillStreamFormat((AudioStreamBasicDescription*)outData, rate);
                    *outDataSize = sizeof(AudioStreamBasicDescription); return 0;
                }
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats: {
                    UInt32 count = inDataSize / sizeof(AudioStreamRangedDescription);
                    if (count > kSupportedSampleRateCount) count = kSupportedSampleRateCount;
                    AudioStreamRangedDescription* formats = (AudioStreamRangedDescription*)outData;
                    for (UInt32 i = 0; i < count; ++i) {
                        FillStreamFormat(&formats[i].mFormat, kSupportedSampleRates[i]);
                        formats[i].mSampleRateRange.mMinimum = kSupportedSampleRates[i];
                        formats[i].mSampleRateRange.mMaximum = kSupportedSampleRates[i];
                    }
                    *outDataSize = count * sizeof(AudioStreamRangedDescription); return 0;
                }
                default:
                    return kAudioHardwareUnknownPropertyError;
            }

        default:
            return kAudioHardwareBadObjectError;
    }

    #undef REQUIRE
}

#pragma mark - SetPropertyData

static OSStatus Kurarin_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData)
{
    (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inDriver != &gInterfacePtr || inAddress == NULL || inData == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    switch (inObjectID) {
        case kObjectID_Box:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyIdentify:
                    return 0;
                case kAudioBoxPropertyAcquired: {
                    if (inDataSize != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    bool wanted = *(const UInt32*)inData != 0;
                    pthread_mutex_lock(&gStateMutex);
                    bool changed = (wanted != gBoxAcquired);
                    gBoxAcquired = wanted;
                    pthread_mutex_unlock(&gStateMutex);
                    if (changed && gHost != NULL) {
                        AudioObjectPropertyAddress changes[] = {
                            { kAudioBoxPropertyAcquired,   kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
                            { kAudioBoxPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
                        };
                        gHost->PropertiesChanged(gHost, kObjectID_Box, 2, changes);
                        AudioObjectPropertyAddress plugInChange =
                            { kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
                        gHost->PropertiesChanged(gHost, kObjectID_PlugIn, 1, &plugInChange);
                    }
                    return 0;
                }
                default:
                    return kAudioHardwareUnknownPropertyError;
            }

        case kObjectID_Device:
            switch (inAddress->mSelector) {
                case kAudioDevicePropertyNominalSampleRate: {
                    if (inDataSize != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
                    Float64 requested = *(const Float64*)inData;

                    bool supported = false;
                    for (UInt32 i = 0; i < kSupportedSampleRateCount; ++i) {
                        if (kSupportedSampleRates[i] == requested) { supported = true; break; }
                    }
                    if (!supported) return kAudioHardwareIllegalOperationError;

                    pthread_mutex_lock(&gStateMutex);
                    bool needsChange = (requested != gSampleRate);
                    if (needsChange) gPendingSampleRate = requested;
                    pthread_mutex_unlock(&gStateMutex);

                    if (needsChange && gHost != NULL) {
                        gHost->RequestDeviceConfigurationChange(gHost, kObjectID_Device, (UInt64)requested, NULL);
                    }
                    return 0;
                }
                default:
                    return kAudioHardwareUnknownPropertyError;
            }

        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            switch (inAddress->mSelector) {
                case kAudioStreamPropertyIsActive: {
                    if (inDataSize != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    bool wanted = *(const UInt32*)inData != 0;
                    pthread_mutex_lock(&gStateMutex);
                    if (inObjectID == kObjectID_Stream_Input) {
                        gInputStreamActive = wanted;
                    } else {
                        gOutputStreamActive = wanted;
                    }
                    pthread_mutex_unlock(&gStateMutex);
                    if (gHost != NULL) {
                        AudioObjectPropertyAddress change =
                            { kAudioStreamPropertyIsActive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
                        gHost->PropertiesChanged(gHost, inObjectID, 1, &change);
                    }
                    return 0;
                }
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat: {
                    if (inDataSize != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
                    const AudioStreamBasicDescription* format = (const AudioStreamBasicDescription*)inData;
                    if (format->mFormatID != kAudioFormatLinearPCM ||
                        format->mChannelsPerFrame != kChannelCount ||
                        format->mBitsPerChannel != 32 ||
                        !(format->mFormatFlags & kAudioFormatFlagIsFloat)) {
                        return kAudioDeviceUnsupportedFormatError;
                    }
                    bool supported = false;
                    for (UInt32 i = 0; i < kSupportedSampleRateCount; ++i) {
                        if (kSupportedSampleRates[i] == format->mSampleRate) { supported = true; break; }
                    }
                    if (!supported) return kAudioDeviceUnsupportedFormatError;

                    pthread_mutex_lock(&gStateMutex);
                    bool needsChange = (format->mSampleRate != gSampleRate);
                    pthread_mutex_unlock(&gStateMutex);
                    if (needsChange && gHost != NULL) {
                        gHost->RequestDeviceConfigurationChange(gHost, kObjectID_Device, (UInt64)format->mSampleRate, NULL);
                    }
                    return 0;
                }
                default:
                    return kAudioHardwareUnknownPropertyError;
            }

        default:
            return kAudioHardwareBadObjectError;
    }
}

#pragma mark - IO

static OSStatus Kurarin_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inClientID;
    if (inDriver != &gInterfacePtr) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;

    pthread_mutex_lock(&gStateMutex);
    if (gDeviceRunCount == 0) {
        memset(gRing, 0, sizeof(gRing));
        gAnchorHostTime = mach_absolute_time();
        gAnchorSampleTime = 0;
        gTimestampCount = 0;
        gHostTicksPerFrame = HostTicksPerSecond() / gSampleRate;
        gLastWriteHostTime = 0;
    }
    ++gDeviceRunCount;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus Kurarin_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inClientID;
    if (inDriver != &gInterfacePtr) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;

    pthread_mutex_lock(&gStateMutex);
    if (gDeviceRunCount > 0) {
        --gDeviceRunCount;
    }
    if (gDeviceRunCount == 0) {
        memset(gRing, 0, sizeof(gRing));
    }
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus Kurarin_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed)
{
    (void)inClientID;
    if (inDriver != &gInterfacePtr) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;

    UInt64 now = mach_absolute_time();
    Float64 ticksPerPeriod = gHostTicksPerFrame * (Float64)kZeroTimeStampPeriod;

    // Advance the anchor by whole periods until it sits ahead of the current
    // host time. The device is virtual, so its clock is simply the host clock.
    //
    // Both guards matter more than they look. An anchor ahead of the clock
    // makes the unsigned subtraction wrap to something astronomical, and this
    // loop runs inside coreaudiod: spinning here does not hang Kurarin, it
    // hangs audio for the whole machine. The anchor is only ever set from the
    // clock, so neither case should arise — which is exactly why it must be
    // cheap to survive one.
    if (ticksPerPeriod > 0.0 && now >= gAnchorHostTime) {
        UInt64 elapsed = now - gAnchorHostTime;
        UInt64 periods = (UInt64)((Float64)elapsed / ticksPerPeriod);
        if (periods > 0) {
            gAnchorHostTime += (UInt64)((Float64)periods * ticksPerPeriod);
            gAnchorSampleTime += periods * kZeroTimeStampPeriod;
            gTimestampCount += periods;
        }
    } else if (now < gAnchorHostTime) {
        // Re-anchor rather than reason about how it happened.
        gAnchorHostTime = now;
    }

    *outSampleTime = (Float64)gAnchorSampleTime;
    *outHostTime   = gAnchorHostTime;
    *outSeed       = 1;
    return 0;
}

static OSStatus Kurarin_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace)
{
    (void)inClientID;
    if (inDriver != &gInterfacePtr) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    if (outWillDo == NULL || outWillDoInPlace == NULL) return kAudioHardwareIllegalOperationError;

    switch (inOperationID) {
        case kAudioServerPlugInIOOperationReadInput:
        case kAudioServerPlugInIOOperationWriteMix:
            *outWillDo = true;
            *outWillDoInPlace = true;
            break;
        default:
            *outWillDo = false;
            *outWillDoInPlace = true;
            break;
    }
    return 0;
}

static OSStatus Kurarin_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    if (inDriver != &gInterfacePtr) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return 0;
}

static OSStatus Kurarin_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer)
{
    (void)inStreamObjectID; (void)inClientID; (void)ioSecondaryBuffer;
    if (inDriver != &gInterfacePtr) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    if (ioMainBuffer == NULL || inIOCycleInfo == NULL) return 0;

    Float32* buffer = (Float32*)ioMainBuffer;

    if (inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        // Via a signed integer: converting a negative Float64 straight to an
        // unsigned type is undefined, and a sample time is not guaranteed to be
        // positive on the first cycles of a stream.
        SInt64 start = (SInt64)inIOCycleInfo->mOutputTime.mSampleTime;
        for (UInt32 frame = 0; frame < inIOBufferFrameSize; ++frame) {
            UInt64 slot = (UInt64)((start + (SInt64)frame) & (SInt64)kRingMask);
            for (UInt32 ch = 0; ch < kChannelCount; ++ch) {
                gRing[slot * kChannelCount + ch] = buffer[frame * kChannelCount + ch];
            }
        }
        gLastWriteHostTime = mach_absolute_time();
        return 0;
    }

    if (inOperationID == kAudioServerPlugInIOOperationReadInput) {
        UInt64 lastWrite = gLastWriteHostTime;
        UInt64 now = mach_absolute_time();
        bool writerIsLive = (lastWrite != 0) &&
                            (now - lastWrite) < NanosToHostTicks(kWriterTimeoutNanos);

        if (!writerIsLive) {
            // Nothing has written recently, so anything still in the ring is
            // stale. Hand out silence rather than looping the last buffer.
            memset(buffer, 0, inIOBufferFrameSize * kChannelCount * sizeof(Float32));
            return 0;
        }

        SInt64 start = (SInt64)inIOCycleInfo->mInputTime.mSampleTime;
        for (UInt32 frame = 0; frame < inIOBufferFrameSize; ++frame) {
            UInt64 slot = (UInt64)((start + (SInt64)frame) & (SInt64)kRingMask);
            for (UInt32 ch = 0; ch < kChannelCount; ++ch) {
                buffer[frame * kChannelCount + ch] = gRing[slot * kChannelCount + ch];
            }
        }
        return 0;
    }

    return 0;
}

static OSStatus Kurarin_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    if (inDriver != &gInterfacePtr) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return 0;
}
