/** @file
  RtcRamRedirect - serve the AppleRTC hibernation window from NVRAM.

  Problem
  -------
  macOS keeps its hibernation credentials in CMOS RTC offsets 0x80-0xAB
  (xnu: AppleRTCHibernateVars = 'AAPL' + revision + booterSignature[20] +
  wiredCryptKey[16] = 44 bytes). On this HP laptop any write to that region
  makes the firmware declare "Real-Time Clock Power Loss" (POST 005) and reload
  factory defaults, so every mechanism that protects the region also destroys
  hibernation resume:

    kernel stage  -> RTCMemoryFixup with rtcfx_exclude=0E-FF swallows the write
                     inside AppleRTC.kext, so CMOS never receives the blob.
    firmware stage-> OpenCore's AppleRtcRam protocol with rtc-blacklist=0E..FF
                     swallows boot.efi's write the same way.

  Both layers are correct for avoiding 005 and both are fatal for resume.
  What nobody noticed is that AppleRTC.kext publishes the *same* 44 byte blob a
  second time, as the IODTNVRAM "/options" property "IOHibernateRTCVariables",
  and that path does not touch CMOS at all.

  What this driver does
  ---------------------
  It takes over the AppleRtcRam protocol (the one boot.efi actually uses, see
  OpenCore Configuration.tex: DisableRtcChecksum "will not protect areas from
  being overwritten at firmware stage (e.g. macOS bootloader), see AppleRtcRam
  protocol description") and hands boot.efi the NVRAM copy for 0x80-0xAB
  instead of the CMOS copy.

  Everything else is delegated to the instance that was already installed, i.e.
  to OpenCore's blacklist implementation. That is deliberate: this driver must
  not open a new 005 surface by letting boot.efi touch checksum (0x58/0x59),
  boot status (0x5C) or power bytes (0xB0) directly. Net behaviour change is
  therefore exactly one bit of logic: "who answers reads of 0x80-0xAB".

  Fail-safe
  ---------
  - No pre-existing protocol instance -> the driver does not install anything
    and stays inert. A machine without AppleRtcRam=true keeps today's behaviour.
  - NVRAM blob absent -> the hibernation window falls back to the pre-existing
    instance as well, so a machine that never hibernated behaves identically.

  Note: this does NOT address the iGPU garbled framebuffer after resume.

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

#include "AppleRtcRam.h"

//
// Apple's protocol GUID. Defined as an object so the header stays declarative.
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
// Hibernation window: 0x80..0xAB inclusive == 44 bytes.
//
#define HIB_START           0x80
#define HIB_END             0xAC
#define HIB_LEN             (HIB_END - HIB_START)

//
// AppleRTC.kext stores the blob through IODTNVRAM "/options", which surfaces as
// a plain NVRAM variable.
//
STATIC CHAR16 mHibVarName[] = L"IOHibernateRTCVariables";

//
// Apple boot variable namespace (7C436110-...). Correct for "/options" on every
// Apple build we know of; the real GUID is still discovered by enumeration.
//
STATIC EFI_GUID mHibVarGuid = {
  0x7C436110, 0xAB2A, 0x4BBB, { 0xA8, 0x80, 0xFE, 0x41, 0x99, 0x5C, 0x9F, 0x82 }
};

STATIC BOOLEAN mHibGuidScanned = FALSE;

//
// Instance we replaced. All non-hibernation traffic is delegated to it.
//
STATIC APPLE_RTC_RAM_PROTOCOL  *mOrigRtc = NULL;
STATIC APPLE_RTC_RAM_PROTOCOL  mRtcRamProtocol;

/**
  Read one byte from real CMOS/RTC. Used only when no previous protocol
  instance exists (i.e. AppleRtcRam=false).
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
  Write one byte to real CMOS/RTC. Fallback path only.
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
  Walk the UEFI variable namespace once to learn which GUID carries
  IOHibernateRTCVariables.
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

  if (mHibGuidScanned) {
    return;
  }

  ZeroMem (Name, sizeof (Name));
  NameSize = sizeof (Name);
  Status   = gRT->GetNextVariableName (&NameSize, Name, &Guid);
  while (!EFI_ERROR (Status)) {
    if (StrCmp (Name, mHibVarName) == 0) {
      mHibVarGuid   = Guid;
      mHibGuidScanned = TRUE;
      DEBUG ((DEBUG_INFO, "RtcRamRedirect: hibernate var GUID %g\n", &Guid));
      return;
    }

    ZeroMem (Name, sizeof (Name));
    NameSize = sizeof (Name);
    Status   = gRT->GetNextVariableName (&NameSize, Name, &Guid);
  }

  mHibGuidScanned = TRUE;
}

/**
  Load the hibernation blob from NVRAM.

  @param[out] Buffer  HIB_LEN bytes.
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
  Persist the blob back into NVRAM. Zero size deletes the variable.
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

/**
  Read a sub-range, delegating to the original instance when possible.
**/
STATIC
EFI_STATUS
ChainRead (
  OUT UINT8  *Buffer,
  IN  UINTN   BufferSize,
  IN  UINTN   Address
  )
{
  UINTN  Index;

  if (mOrigRtc != NULL) {
    return mOrigRtc->ReadMemory (mOrigRtc, Buffer, BufferSize, Address);
  }

  for (Index = 0; Index < BufferSize; ++Index) {
    Buffer[Index] = RtcHwRead (Address + Index);
  }

  return EFI_SUCCESS;
}

/**
  Write a sub-range, delegating to the original instance when possible.
**/
STATIC
EFI_STATUS
ChainWrite (
  IN CONST UINT8  *Buffer,
  IN UINTN         BufferSize,
  IN UINTN         Address
  )
{
  UINTN  Index;

  if (mOrigRtc != NULL) {
    return mOrigRtc->WriteMemory (mOrigRtc, Buffer, BufferSize, Address);
  }

  for (Index = 0; Index < BufferSize; ++Index) {
    RtcHwWrite (Address + Index, Buffer[Index]);
  }

  return EFI_SUCCESS;
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
  if (mOrigRtc != NULL) {
    return mOrigRtc->GetAvailableMemory (mOrigRtc);
  }

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
  EFI_STATUS  Status;
  UINT8       Hib[HIB_LEN];
  UINTN       HibLen;
  UINTN       Offset;
  UINTN       End;
  UINTN       SegEnd;
  UINTN       SegLen;

  if ((Buffer == NULL) || (BufferSize == 0)) {
    return EFI_INVALID_PARAMETER;
  }

  if ((Address >= RTC_TOTAL_SIZE) || (BufferSize > (RTC_TOTAL_SIZE - Address))) {
    return EFI_INVALID_PARAMETER;
  }

  HibLen = LoadHibVar (Hib);

  Offset = Address;
  End    = Address + BufferSize;
  while (Offset < End) {
    if ((Offset >= HIB_START) && (Offset < HIB_END)) {
      //
      // Hibernation window: answer from NVRAM when the kernel published a blob.
      //
      SegEnd = End < HIB_END ? End : HIB_END;
      SegLen = SegEnd - Offset;

      if (HibLen != 0) {
        UINTN Index;
        for (Index = 0; Index < SegLen; ++Index) {
          UINTN HibIndex = (Offset - HIB_START) + Index;
          Buffer[Offset - Address + Index] = (HibIndex < HibLen) ? Hib[HibIndex] : 0xFF;
        }

        Status = EFI_SUCCESS;
      } else {
        //
        // No blob -> behave exactly as before (the chained instance will
        // swallow it through rtc-blacklist).
        //
        Status = ChainRead (Buffer + (Offset - Address), SegLen, Offset);
      }
    } else {
      //
      // Everything else is not ours. Keep the pre-existing protection intact.
      //
      SegEnd = (Offset < HIB_START) ? (End < HIB_START ? End : HIB_START) : End;
      SegLen = SegEnd - Offset;
      Status = ChainRead (Buffer + (Offset - Address), SegLen, Offset);
    }

    if (EFI_ERROR (Status)) {
      return Status;
    }

    Offset = SegEnd;
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
  EFI_STATUS  Status;
  UINT8       Hib[HIB_LEN];
  UINTN       HibLen;
  UINTN       Offset;
  UINTN       End;
  UINTN       SegEnd;
  UINTN       SegLen;
  BOOLEAN     HibDirty;

  if ((Buffer == NULL) || (BufferSize == 0)) {
    return EFI_INVALID_PARAMETER;
  }

  if ((Address >= RTC_TOTAL_SIZE) || (BufferSize > (RTC_TOTAL_SIZE - Address))) {
    return EFI_INVALID_PARAMETER;
  }

  HibLen   = LoadHibVar (Hib);
  HibDirty = FALSE;

  Offset = Address;
  End    = Address + BufferSize;
  while (Offset < End) {
    if ((Offset >= HIB_START) && (Offset < HIB_END) && (HibLen != 0)) {
      //
      // Blob exists: absorb the write into NVRAM, never into CMOS.
      //
      SegEnd = End < HIB_END ? End : HIB_END;
      SegLen = SegEnd - Offset;

      {
        UINTN Index;
        for (Index = 0; Index < SegLen; ++Index) {
          UINTN HibIndex = (Offset - HIB_START) + Index;
          if (HibIndex < HIB_LEN) {
            Hib[HibIndex] = Buffer[Offset - Address + Index];
          }
        }
      }

      HibDirty = TRUE;
      Status   = EFI_SUCCESS;
    } else if ((Offset >= HIB_START) && (Offset < HIB_END)) {
      //
      // No blob yet: stay a pure pass-through so we never invent a variable
      // the kernel did not publish.
      //
      SegEnd = End < HIB_END ? End : HIB_END;
      SegLen = SegEnd - Offset;
      Status = ChainWrite (Buffer + (Offset - Address), SegLen, Offset);
    } else {
      SegEnd = (Offset < HIB_START) ? (End < HIB_START ? End : HIB_START) : End;
      SegLen = SegEnd - Offset;
      Status = ChainWrite (Buffer + (Offset - Address), SegLen, Offset);
    }

    if (EFI_ERROR (Status)) {
      return Status;
    }

    Offset = SegEnd;
  }

  if (HibDirty) {
    Status = StoreHibVar (Hib, HIB_LEN);
    if (EFI_ERROR (Status)) {
      DEBUG ((DEBUG_WARN, "RtcRamRedirect: NVRAM write failed - %r\n", Status));
    }
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
  // Drop the redirected copy only. CMOS is deliberately left untouched: the
  // chained implementation cannot reach it either (rtc-blacklist covers the
  // whole 0x0E-0xFF span), so calling it would only add risk.
  //
  Status = StoreHibVar (NULL, 0);
  if (Status == EFI_NOT_FOUND) {
    Status = EFI_SUCCESS;
  }

  return Status;
}

/**
  Entry point: take over the existing Apple RTC RAM protocol instance.
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

  Handles      = NULL;
  HandleCount  = 0;
  Existing     = NULL;
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
    // Keep the old table: every access outside 0x80-0xAB is forwarded to it so
    // the rtc-blacklist protection stays exactly as it was.
    //
    mOrigRtc = (APPLE_RTC_RAM_PROTOCOL *)Existing;

    Status = gBS->ReinstallProtocolInterface (
                    TargetHandle,
                    &gAppleRtcRamProtocolGuid,
                    Existing,
                    &mRtcRamProtocol
                    );
    DEBUG ((
      EFI_ERROR (Status) ? DEBUG_ERROR : DEBUG_INFO,
      "RtcRamRedirect: chained onto %p, status %r\n",
      Existing,
      Status
      ));
    FreePool (Handles);
    return Status;
  }

  if (Handles != NULL) {
    FreePool (Handles);
  }

  //
  // Nothing to chain onto. Installing our own instance here would bypass every
  // firmware-stage protection, so stay inert instead and let the config be
  // fixed (AppleRtcRam=true is required).
  //
  DEBUG ((DEBUG_WARN, "RtcRamRedirect: no AppleRtcRam protocol instance, staying inert\n"));
  return EFI_SUCCESS;
}
