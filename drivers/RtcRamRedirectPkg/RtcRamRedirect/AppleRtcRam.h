/** @file
  AppleRtcRam.h - minimal local copy of the Apple RTC RAM protocol definition.

  Source of truth: OpenCorePkg Include/Apple/Protocol/AppleRtcRam.h
  (verified verbatim 2026-11-20). Reproduced here so this driver builds
  without pulling in the whole OpenCorePkg tree.

  Copyright (C) 2020, vit9696. BSD-2-Clause.
**/

#ifndef APPLE_RTC_RAM_PROTOCOL_H
#define APPLE_RTC_RAM_PROTOCOL_H

#define APPLE_RTC_RAM_PROTOCOL_GUID \
  { 0xE121EC07, 0x9C42, 0x45EE, { 0xB0, 0xB6, 0xFF, 0xF8, 0xEF, 0x03, 0xC5, 0x21 } }

typedef struct APPLE_RTC_RAM_PROTOCOL_ APPLE_RTC_RAM_PROTOCOL;

typedef UINTN (EFIAPI *APPLE_RTC_RAM_GET_AVAILABLE_MEMORY)(
  IN APPLE_RTC_RAM_PROTOCOL *This
  );

typedef EFI_STATUS (EFIAPI *APPLE_RTC_RAM_READ_MEMORY)(
  IN  APPLE_RTC_RAM_PROTOCOL *This,
  OUT UINT8                  *Buffer,
  IN  UINTN                   BufferSize,
  IN  UINTN                   Address
  );

typedef EFI_STATUS (EFIAPI *APPLE_RTC_RAM_WRITE_MEMORY)(
  IN APPLE_RTC_RAM_PROTOCOL *This,
  IN CONST UINT8            *Buffer,
  IN UINTN                   BufferSize,
  IN UINTN                   Address
  );

typedef EFI_STATUS (EFIAPI *APPLE_RTC_RAM_RESET_MEMORY)(
  IN APPLE_RTC_RAM_PROTOCOL *This
  );

struct APPLE_RTC_RAM_PROTOCOL_ {
  APPLE_RTC_RAM_GET_AVAILABLE_MEMORY GetAvailableMemory;
  APPLE_RTC_RAM_READ_MEMORY          ReadMemory;
  APPLE_RTC_RAM_WRITE_MEMORY         WriteMemory;
  APPLE_RTC_RAM_RESET_MEMORY         ResetMemory;
};

extern EFI_GUID gAppleRtcRamProtocolGuid;

#endif // APPLE_RTC_RAM_PROTOCOL_H
