# Community Post Draft — CML-H DeepIdle stuck at Package C3 (complete forensics)

> Destination: r/hackintosh + acidanthera Discord #power-management
> Post only after user approves (external action requires explicit consent).

---

**Title:** Comet Lake H DeepIdle permanently stuck at Package C3 (C6–C10 = 0) — full forensics, every user-space fix tested and negative. Any ideas left?

**Platform:** HP ZBook Power G7 (T75), i7-10750H (CML-H, UHD630), macOS 26.7.3 (Darwin 25.6.0), OpenCore 1.0.9 (Mod), SMBIOS MacBookPro16,4, no OCLP. No S3/S4 available (firmware is AOAC-only: Windows `powercfg /a` shows S3 disabled by firmware; forcing S3 in macOS = EC OBF strike + hang, tested twice).

**Symptom:** With SSDT-DeepIdle (S0ix emulation, DeepIdle type 7) the machine sleeps fine and wakes in ~2.5 s, but battery drain in sleep is **3.7 W** (5.5 %/h on a 67.7 Wh pack). `machdep.xcpm.deep_idle_last_stats` after every sleep: **C3: 98–100 %, C6–C10: 0 %**. awake fine.

**Forensic data (custom kext, real measurements):**
- Core C-states during sleep: every core reaches C6 82–98 %, **core C7 = 0**.
- Package residency counters (MSR 0x3F8–0x632, frozen pre/post sleep): **PC3 accumulates, PC6+ strictly 0** → a "double ceiling": cores go deep, package demoted to PC3.
- MSR 0xE2 = 0x1E008008: Package C-State Limit (bits 10:8) = 0 (unlimited); clearing demotion bits 28:25 on **all cores** (rendezvous) → no change.
- `machdep.xcpm.maxbusdelay = 0xFFFFFFFF` (and tracing the actual holder: IntelMausi kMaxDmaLatency=75000 µs, registered, never released) → no change.
- Real LTR read at sleep entry via extended-cap chain (LTR ext cap 0x0018): all configured devices 3.15–8.39 ms (CNVW/NVMe/15e8/15e9/TB), rest noLTR — **no blocker-scale LTR**. ASPM L1 enabled on all readable links.
- Sleep-entry PMCSR scan of all 25 PCI devices: all D0, no anomalies.
- Gating XHC/CNVW/I2C0/I2C1/HDEF to D3 inside SystemWillSleep → no change.
- Gating the driverless devices too (xDCI/SPI/TB/LAN, Windows-S0ix model) → **hard panic**: `[IGPU] SafeForceWake acknowledgement never received on RENDER domain` (A/B interleaved: mode2 2/2 panic vs mode1 3/3 OK) — so driverless-device gating is untestable on this machine.
- CNVI L1.2 / LTR injection (registers verified applied via ioreg) → no change.
- WiFi off, tcpkeepalive=0, SSDT-XHC-Sleep, CPUFriend, NVMe APST → all no change.

**Known-good reference:** Windows on the same hardware sleeps properly (user report). Hardware is capable; something macOS-side (or the DeepIdle shim's interaction with the PCH) keeps the package at C3.

**Similar precedent:** Dell XPS 9510 (i7-11800H) shows the *same* signature — cores reach C7, package stuck at C3, ~5 W sleep drain — across Windows/Ubuntu/Fedora (askubuntu.com/questions/1505669), attributed to a firmware-level issue fixed there by a BIOS update. No newer HP BIOS exists for this machine (01.25.00 is current).

**Questions:**
1. Has anyone ever gotten CML-H past PC3 during DeepIdle sleep? Any SSDT/kext/PMC trick beyond the above?
2. Is DeepIdle type 7 on CML-H known to be capped at PC3 by design (e.g. missing SLP_S0 handshake that only real S0ix firmware path performs)?
3. On Windows, Modern Standby asserts SLP_S0 and the EC/PD firmware participates. Is there any known OpenCore-side way to emulate what Windows does (e.g. via PMC LTR_IGNORE / PWRM, or BIOS NVS variables)?

Any pointer appreciated — full logs/measurements available.
