//
//  IOHIDSPI.h
//
//  Declarations for the parts of the IOHIDEventSystemClient API that Apple ships in the shipping
//  binary but not in any public header.
//
//  IMPORTANT: `IOHIDServiceClientRef` and `IOHIDEventSystemClientRef` are NOT declared here. The
//  macOS SDK declares both publicly, as CF_BRIDGED_TYPE typedefs, in
//  <IOKit/hidsystem/IOHIDServiceClient.h> and <IOKit/hidsystem/IOHIDEventSystemClient.h>. Swift
//  imports them as the class types `IOHIDServiceClient` and `IOHIDEventSystemClient`. Re-declaring
//  them here would conflict with the SDK, so those headers are imported instead.
//
//  Everything the project needs for reading and writing service properties
//  (IOHIDServiceClientCopyProperty / SetProperty / GetRegistryID / ConformsTo) is public. Only the
//  matching, enumeration and notification calls below are SPI.
//

#ifndef IOHIDSPI_h
#define IOHIDSPI_h

#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#import <IOKit/hid/IOHIDDevice.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hid/IOHIDUsageTables.h>
#import <IOKit/hidsystem/IOHIDServiceClient.h>
#import <IOKit/hidsystem/IOHIDEventSystemClient.h>

__BEGIN_DECLS
CF_ASSUME_NONNULL_BEGIN
CF_IMPLICIT_BRIDGING_ENABLED

typedef void (^IOHIDServiceClientBlock)(void * _Nullable, void * _Nullable, IOHIDServiceClientRef _Nullable);

typedef CF_ENUM(int, IOHIDEventSystemClientType) {
    kIOHIDEventSystemClientTypeAdmin,
    kIOHIDEventSystemClientTypeMonitor,
    kIOHIDEventSystemClientTypePassive,
    kIOHIDEventSystemClientTypeRateControlled,
    kIOHIDEventSystemClientTypeSimple
};

IOHIDEventSystemClientRef _Nullable IOHIDEventSystemClientCreate(CFAllocatorRef _Nullable allocator);
IOHIDEventSystemClientRef _Nullable IOHIDEventSystemClientCreateWithType(CFAllocatorRef _Nullable allocator,
                                                               IOHIDEventSystemClientType clientType,
                                                               CFDictionaryRef _Nullable attributes);

void IOHIDEventSystemClientSetMatchingMultiple(IOHIDEventSystemClientRef client, CFArrayRef _Nullable matching);

void IOHIDEventSystemClientRegisterDeviceMatchingBlock(IOHIDEventSystemClientRef client,
                                                       IOHIDServiceClientBlock _Nullable callback,
                                                       void * _Nullable target,
                                                       void * _Nullable context);
void IOHIDEventSystemClientUnregisterDeviceMatchingBlock(IOHIDEventSystemClientRef client);

void IOHIDEventSystemClientScheduleWithDispatchQueue(IOHIDEventSystemClientRef client, dispatch_queue_t queue);
void IOHIDEventSystemClientUnscheduleFromDispatchQueue(IOHIDEventSystemClientRef client, dispatch_queue_t queue);
void IOHIDEventSystemClientActivate(IOHIDEventSystemClientRef client);

void IOHIDServiceClientRegisterRemovalBlock(IOHIDServiceClientRef service,
                                            IOHIDServiceClientBlock _Nullable callback,
                                            void * _Nullable target,
                                            void * _Nullable context);

typedef void (*IOHIDEventSystemClientPropertyChangedCallback)(void * _Nullable target,
                                                              void * _Nullable context,
                                                              CFStringRef property,
                                                              CFTypeRef _Nullable value);

void IOHIDEventSystemClientRegisterPropertyChangedCallback(IOHIDEventSystemClientRef client,
                                                           CFStringRef property,
                                                           IOHIDEventSystemClientPropertyChangedCallback callback,
                                                           void * _Nullable target,
                                                           void * _Nullable context);

CF_IMPLICIT_BRIDGING_DISABLED
CF_ASSUME_NONNULL_END
__END_DECLS

#endif /* IOHIDSPI_h */
