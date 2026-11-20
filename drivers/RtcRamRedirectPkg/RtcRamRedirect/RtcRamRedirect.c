/** @file
  RtcRamRedirect - Apple RTC RAM protocol replacement.

  Purpose
  -------
  macOS stores its hibernation variables (AppleRTCHibernateVars: 'AAPL' signature,
  booterSignature[20], wiredCryptKey[16]) in CMOS RTC offsets 0x80-0xAB. On HP
  laptops writing that region makes the firmware believe the RTC lost power and
  it throws POST error 005 ("Real-Time Clock Power Loss") and reloads factory
  defaults.

  boot.efi reads/writes that region through the Apple RTC RAM protocol, so if we
  install our own instance we can serve that window from a persistent UEFI
  variable instead of CMOS. The firmware never sees a modified RTC, and
  boot.efi still finds the resume marker -> no 005, resume still possible.

  Where the variable comes from
  -----------------------------
  Stock AppleRTC.kext::setHibernateState() already publishes the exact same 44
  byte blob twice during hibernation: once into RTC offset 0x80 and once into
  the IODTNVRAM "/options" node as variable "IOHibernateRTCVariables". Only the
  RTC copy is what the firmware later complains about, so this driver reuses the
  NVRAM copy that macOS itself wrote. No kernel component is required.

  Verified against the AppleRTC image inside BootKernelExtensions.kc
  (com.apple.driver.AppleRTC, macOS 26): the function first rejects RTC RAM
  smaller than 256 bytes, then calls a helper with (this, blob, 0x80, len) and
  afterwards sets the property on "/options".

  Fail-safe behaviour
  -------------------
  The redirect is armed only when the NVRAM variable exists. If it does not
  exist, every access falls straight through to the real hardware, so a machine
  that never hibernated behaves exactly as if this driver were absent.

  This driver only redirects the hibernate window 0x80-0xAB. Every other RTC
  offset is passed through to the real hardware unchanged.

  Note: this does NOT fix the iGPU garbled framebuffer after resume.

  Copyright (C) 2026. BSD-2-Clause.
**/

#include <Uefi.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Library/UefiRuntimeServicesTableLib.h>
#include <Library/UefiLib.h>
#include <Library/DebugLib.h>
#include <Library/BaseLib.h>
#include <Library/BaseMemoryLib.h>
#include <Library/MemoryAllocationLib.h>
#include <Library/IoLib.h>
#include <Library/PrintLib.h>

#include "AppleRtcRam.h"

//
// Apple's protocol GUID. Defined here as an object so the header can stay a
// pure declaration (same pattern Apple/OpenCore use).
//
EFI_GUID gAppleRtcRamProtocolGuid = APPLE_RTC_RAM_PROTOCOL_GUID;

//
// RTC geometry. Offsets below 0x80 live in bank 0 (index/data 0x70/0x71),
// offsets 0x80 and above in the extended bank (index/data 0x72/0x73).
//
#define RTC_TOTAL_SIZE      256
#define RTC_BANK_SIZE       128
#define RTC_INDEX_PORT      0x70
#define RTC_DATA_PORT       0x71
#define RTC_EXT_INDEX_PORT  0x72
#define RTC_EXT_DATA_PORT   0x73
#define RTC_NMI_MASK        0x80
#define RTC_OFFSET_MASK     0x7F

//
// Hibernate variable window: 0x80..0xAB inclusive == 44 bytes.
//
#define HIB_START           0x80
#define HIB_END             0xAC
#define HIB_LEN             (HIB_END - HIB_START)

//
// xnu publishes the blob as IOService property "IOHibernateRTCVariables"
// (see xnu iokit/Kernel/IOHibernateIO.cpp). HibernationFixup stores that blob
// through Lilu NVStorage, which writes a plain NVRAM variable of the same name
// into IODTNVRAM "/options". We therefore look it up as a UEFI variable.
//
STATIC CHAR16 mHibVarName[] = L"IOHibernateRTCVariables";

//
// Default guess: Apple boot variable namespace. The real GUID is discovered by
// enumerating variables at runtime, so this is only a fallback.
//
STATIC EFI_GUID mHibVarGuid = {
  0x7C436110, 0xAB2A, 0x4BBB, { 0xA8, 0x80, 0xFE, 0x41, 0x99, 0x5C, 0x9F, 0x82 }
};

STATIC BOOLEAN mHibGuidResolved = FALSE;

STATIC APPLE_RTC_RAM_PROTOCOL mRtcRamProtocol;

/**
  Read one byte from real CMOS/RTC.

  @param[in] Offset  RTC offset 0..255.
  @retval Byte value.
**/
STATIC
UINT8
RtcHwRead (
  IN UINTN  Offset
  )
{
  UINT8  IndexPort;
  UINT8  DataPort;
  UINT8  Nmi;

  if (Offset < RTC_BANK_SIZE) {
    IndexPort = RTC_INDEX_PORT;
    DataPort  = RTC_DATA_PORT;
  } else {
    IndexPort = RTC_EXT_INDEX_PORT;
    DataPort  = RTC_EXT_DATA_PORT;
  }

  Nmi = IoRead8 (IndexPort) & RTC_NMI_MASK;
  IoWrite8 (IndexPort, (UINT8)((Offset & RTC_OFFSET_MASK) | Nmi));
  return IoRead8 (DataPort);
}

/**
  Write one byte to real CMOS/RTC.

  @param[in] Offset  RTC offset 0..255.
  @param[in] Value   Byte to write.
**/
STATIC
VOID
RtcHwWrite (
  IN UINTN  Offset,
  IN UINT8  Value
  )
{
  UINT8  IndexPort;
  UINT8  DataPort;
  UINT8  Nmi;

  if (Offset < RTC_BANK_SIZE) {
    IndexPort = RTC_INDEX_PORT;
    DataPort  = RTC_DATA_PORT;
  } else {
    IndexPort = RTC_EXT_INDEX_PORT;
    DataPort  = RTC_EXT_DATA_PORT;
  }

  Nmi = IoRead8 (IndexPort) & RTC_NMI_MASK;
  IoWrite8 (IndexPort, (UINT8)((Offset & RTC_OFFSET_MASK) | Nmi));
  IoWrite8 (DataPort, Value);
}

/**
  Return TRUE when the byte range [Address, Address+Size) touches the
  hibernation window that we redirect to NVRAM.
**/
STATIC
BOOLEAN
TouchesHibWindow (
  IN UINTN  Address,
  IN UINTN  Size
  )
{
  if (Size == 0) {
    return FALSE;
  }

  return (Address < HIB_END) && ((Address + Size) > HIB_START);
}

/**
  Walk the UEFI variable namespace once to learn which GUID carries
  IOHibernateRTCVariables. HibernationFixup writes it via IODTNVRAM, and the
  namespace used may differ from our fallback guess.
**/
STATIC
VOID
ResolveHibVarGuid (
  VOID
  )
{
  EFI_STATUS  Status;
  CHAR16      Name[128];
  EFI_GUID    Guid;
  UINTN       NameSize;

  if (mHibGuidResolved) {
    return;
  }

  ZeroMem (Name, sizeof (Name));
  NameSize = sizeof (Name);
  Status   = gRT->GetNextVariableName (&NameSize, Name, &Guid);
  while (!EFI_ERROR (Status)) {
    if (StrCmp (Name, mHibVarName) == 0) {
      mHibVarGuid      = Guid;
      mHibGuidResolved = TRUE;
      DEBUG ((DEBUG_INFO, "RtcRamRedirect: hibernate var GUID = %g\n", &Guid));
      return;
    }

    ZeroMem (Name, sizeof (Name));
    NameSize = sizeof (Name);
    Status   = gRT->GetNextVariableName (&NameSize, Name, &Guid);
  }
}

/**
  Load the hibernation blob from NVRAM.

  @param[out] Buffer  HIB_LEN bytes, pre-filled with 0xFF.
  @retval Number of valid bytes, 0 when the variable is absent.
**/
STATIC
UINTN
LoadHibVar (
  OUT UINT8  *Buffer
  )
{
  EFI_STATUS  Status;
  UINTN       Size;

  SetMem (Buffer, HIB_LEN, 0xFF);

  ResolveHibVarGuid ();

  Size   = HIB_LEN;
  Status = gRT->GetVariable (mHibVarName, &mHibVarGuid, NULL, &Size, Buffer);
  if (EFI_ERROR (Status) || (Size == 0)) {
    return 0;
  }

  if (Size > HIB_LEN) {
    Size = HIB_LEN;
  }

  return Size;
}

/**
  Persist the hibernation blob into NVRAM.

  A zero-size write deletes the variable, which is what boot.efi effectively
  does once the image has been consumed.
**/
STATIC
EFI_STATUS
StoreHibVar (
  IN CONST UINT8  *Buffer,
  IN UINTN         Size
  )
{
  ResolveHibVarGuid ();

  if (Size == 0) {
    return gRT->SetVariable (mHibVarName, &mHibVarGuid, 0, 0, NULL);
  }

  return gRT->SetVariable (
                mHibVarName,
                &mHibVarGuid,
                EFI_VARIABLE_NON_VOLATILE | EFI_VARIABLE_BOOTSERVICE_ACCESS | EFI_VARIABLE_RUNTIME_ACCESS,
                Size,
                (VOID *)Buffer
                );
}

//
// Protocol implementation
//

STATIC
UINTN
EFIAPI
RtcGetAvailableMemory (
  IN APPLE_RTC_RAM_PROTOCOL  *This
  )
{
  return RTC_TOTAL_SIZE;
}

STATIC
EFI_STATUS
EFIAPI
RtcReadMemory (
  IN  APPLE_RTC_RAM_PROTOCOL  *This,
  OUT UINT8                   *Buffer,
  IN  UINTN                    BufferSize,
  IN  UINTN                    Address
  )
{
  UINT8  Hib[HIB_LEN];
  UINTN  HibLen;
  UINTN  Index;

  if ((Buffer == NULL) || (BufferSize == 0)) {
    return EFI_INVALID_PARAMETER;
  }

  if ((Address >= RTC_TOTAL_SIZE) || (BufferSize > (RTC_TOTAL_SIZE - Address))) {
    return EFI_INVALID_PARAMETER;
  }

  HibLen = 0;
  if (TouchesHibWindow (Address, BufferSize)) {
    HibLen = LoadHibVar (Hib);
  }

  for (Index = 0; Index < BufferSize; ++Index) {
    UINTN Offset = Address + Index;

    //
    // Serve the window from NVRAM only when a blob is actually there.
    // Otherwise pass straight through to the hardware: a machine that never
    // hibernated must behave exactly as if this driver were absent.
    //
    if ((HibLen != 0) && (Offset >= HIB_START) && (Offset < HIB_END)) {
      UINTN HibIndex = Offset - HIB_START;
      Buffer[Index] = (HibIndex < HibLen) ? Hib[HibIndex] : 0xFF;
    } else {
      Buffer[Index] = RtcHwRead (Offset);
    }
  }

  return EFI_SUCCESS;
}

STATIC
EFI_STATUS
EFIAPI
RtcWriteMemory (
  IN APPLE_RTC_RAM_PROTOCOL  *This,
  IN CONST UINT8             *Buffer,
  IN UINTN                    BufferSize,
  IN UINTN                    Address
  )
{
  UINT8  Hib[HIB_LEN];
  UINTN  HibLen;
  UINTN  Index;
  BOOLEAN Redirected;

  if ((Buffer == NULL) || (BufferSize == 0)) {
    return EFI_INVALID_PARAMETER;
  }

  if ((Address >= RTC_TOTAL_SIZE) || (BufferSize > (RTC_TOTAL_SIZE - Address))) {
    return EFI_INVALID_PARAMETER;
  }

  Redirected = TouchesHibWindow (Address, BufferSize);

  if (Redirected) {
    //
    // Read-modify-write so a partial update does not wipe the rest of the blob.
    //
    HibLen = LoadHibVar (Hib);

    //
    // No blob yet -> no hibernation has happened, so stay a pure pass-through
    // and never invent a variable the kernel did not publish.
    //
    if (HibLen == 0) {
      Redirected = FALSE;
    } else {
      for (Index = 0; Index < BufferSize; ++Index) {
        UINTN Offset = Address + Index;

        if ((Offset >= HIB_START) && (Offset < HIB_END)) {
          Hib[Offset - HIB_START] = Buffer[Index];
        }
      }

      StoreHibVar (Hib, HIB_LEN);
    }
  }

  for (Index = 0; Index < BufferSize; ++Index) {
    UINTN Offset = Address + Index;

    if ((Offset >= HIB_START) && (Offset < HIB_END) && Redirected) {
      continue;
    }

    RtcHwWrite (Offset, Buffer[Index]);
  }

  return EFI_SUCCESS;
}

STATIC
EFI_STATUS
EFIAPI
RtcResetMemory (
  IN APPLE_RTC_RAM_PROTOCOL  *This
  )
{
  EFI_STATUS  Status;

  //
  // Only the redirected window is reset. Real CMOS is deliberately left alone:
  // the hibernate window there is either stale or never written, and touching
  // it is exactly what we are trying to avoid.
  //
  Status = StoreHibVar (NULL, 0);
  if (Status == EFI_NOT_FOUND) {
    Status = EFI_SUCCESS;
  }

  return Status;
}

/**
  Entry point: install (or take over) the Apple RTC RAM protocol.
**/
EFI_STATUS
EFIAPI
RtcRamRedirectEntry (
  IN EFI_HANDLE        ImageHandle,
  IN EFI_SYSTEM_TABLE  *SystemTable
  )
{
  EFI_STATUS  Status;
  EFI_HANDLE  *Handles;
  UINTN       HandleCount;
  EFI_HANDLE  TargetHandle;
  VOID        *Existing;

  mRtcRamProtocol.GetAvailableMemory = RtcGetAvailableMemory;
  mRtcRamProtocol.ReadMemory         = RtcReadMemory;
  mRtcRamProtocol.WriteMemory        = RtcWriteMemory;
  mRtcRamProtocol.ResetMemory        = RtcResetMemory;

  Handles     = NULL;
  HandleCount = 0;
  Existing    = NULL;
  TargetHandle = NULL;

  Status = gBS->LocateHandleBuffer (
                  ByProtocol,
                  &gAppleRtcRamProtocolGuid,
                  NULL,
                  &HandleCount,
                  &Handles
                  );
  if (!EFI_ERROR (Status) && (HandleCount > 0)) {
    TargetHandle = Handles[0];
    gBS->HandleProtocol (TargetHandle, &gAppleRtcRamProtocolGuid, &Existing);

    //
    // Preferred path: the firmware/OpenCore already published an instance, so
    // swap ours in under the same handle. boot.efi resolves by GUID, therefore
    // whoever holds the protocol last wins.
    //
    Status = gBS->ReinstallProtocolInterface (
                    TargetHandle,
                    &gAppleRtcRamProtocolGuid,
                    Existing,
                    &mRtcRamProtocol
                    );
    DEBUG ((DEBUG_INFO, "RtcRamRedirect: reinstall status %r\n", Status));
    FreePool (Handles);
    return Status;
  }

  if (Handles != NULL) {
    FreePool (Handles);
  }

  TargetHandle = NULL;
  Status       = gBS->InstallProtocolInterface (
                        &TargetHandle,
                        &gAppleRtcRamProtocolGuid,
                        EFI_NATIVE_INTERFACE,
                        &mRtcRamProtocol
                        );
  DEBUG ((DEBUG_INFO, "RtcRamRedirect: install status %r\n", Status));
  return Status;
}
