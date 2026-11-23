# RtcRamRedirect

一个 UEFI DXE 驱动，接在 OpenCore 的 Apple RTC RAM 协议之上，把 macOS 休眠变量窗口
（CMOS 0x80–0xAB）的**读**改由 NVRAM 变量 `IOHibernateRTCVariables` 提供，其余偏移全部
**委托**给原实例。用于 HP 笔记本黑苹果上让 S4 能恢复，同时不放开对 CMOS 的写入。

设计/部署/回滚见 `docs/rtc-nvram-redirect-deploy-2026-11-20.md`。

## 为什么是"委托"而不是"替换"

本机两层保护都把 0x80–0xAB 锁死了：

| 阶段 | 拦截者 | 结果 |
|---|---|---|
| kernel（睡眠瞬间） | RTCMemoryFixup，`rtcfx_exclude=0E-FF` | AppleRTC 的写被吸进内核影子，CMOS 不变 |
| firmware（boot.efi） | OC `AppleRtcRam=true` + `rtc-blacklist`=0x0E..0xFF | boot.efi 读到影子，拿不到签名 |

两层都必须保留（去掉任一层都会让 CMOS 被写，也就是 005 的源头）。所以驱动只解 firmware 层的
**读**，且必须把 0x0E–0xFF 里除 0x80–0xAB 之外的一切（checksum 0x58/0x59、boot status 0x5C、
power bytes 0xB0）继续交给 OC 的 blacklist —— 自己实现等于撤掉这些保护，平白新开 005 面。

净行为差异只有一条：**谁回答 0x80–0xAB 的读**。

## 安全语义

- **没有原协议实例**（`AppleRtcRam=false` 且固件无）→ 驱动**不安装任何东西**，彻底惰性。
  自己装一份会绕过所有 firmware 阶段保护，风险大于收益。
- **NVRAM 里没有 blob**（从未写入休眠镜像）→ 休眠窗口也一起委托，行为与未安装完全等价。
- **两者都在** → 该窗口读 NVRAM、写 NVRAM，CMOS 零接触。

`IOHibernateRTCVariables` 由系统自带 `com.apple.driver.AppleRTC::setHibernateState()`
在真正写休眠镜像时同时写 CMOS 和 NVRAM `/options`，无需任何内核补丁。

⚠️ 因此 `hibernatemode 0` 时本驱动空转（NVRAM 里永远没有变量）。

## 构建

工具链是 edk2 的 `XCODE5`（clang → Mach-O `MH_PRELOAD` → `mtoc` → PE32+）。

依赖（本机已装，均编译自源码）：

| 工具 | 位置 | 用途 |
|---|---|---|
| `mtoc` | `/usr/local/bin/mtoc` | Mach-O → PE/COFF，`tools_def.template` 硬编码此路径 |
| `nasm` | `/usr/local/bin/nasm` | edk2 X64 汇编（BaseLib 必需） |
| edk2 | `~/src/edk2` | BaseTools 需含 `GenFw`/`GenFfs`/`GenSec`/`GenFv` |

```bash
./build-rtcram.sh RELEASE      # 产物 -> dist/RtcRamRedirect.efi
```

踩坑记录：

- edk2 master 的 `MdePkg.dec` 声明了未初始化的 submodule 路径
  `Library/MipiSysTLib/mipisyst/library/include`，`build` 会报 `000E File/directory not found`。
  本模块用不到它，直接 `mkdir -p` 出空目录即可过。
- `edksetup.sh` 与 `set -u` 冲突（`PYTHON_COMMAND: unbound variable`），脚本里用 `set -eo pipefail`。
- master 的 `UefiDriverEntryPoint` 现在还要求 `StackCheckLib` / `StackCheckFailureHookLib`，
  DSC 里补 `MdePkg/Library/StackCheckLibNull` 与 `MdePkg/Library/StackCheckFailureHookLibNull`。
- `mtoc` 只接受 `MH_PRELOAD`/`MH_DYLIB`/带 PIE 的 `MH_EXECUTE`，且要求 `-seg1addr` ≥ 0x200。
- 手工编 `ocmtoc` 时别用 `grep -L "main(\|diagnostics"` 过滤源文件：`libstuff/errors.c`
  含 "diagnostics" 字样会被误排除，导致 `Undefined _error`。四个文件都要留：
  `errors.c` `fatals.c` `fatal_arch.c` `diagnostics.c`。

## 产物校验

```
RtcRamRedirect.efi  15456 B
sha256 c57316513222157cc44d6329548ff05a509daa585b994e65ae587418dfe29252
PE32+ / x86-64 / subsystem 11 (EFI boot service driver)
sections: .text .data .reloc    entry RVA 0x2e4d
```

## 未解决

- 不解决恢复后 iGPU 花屏（独立问题）。
- 005 是否真消失未实测。当前推断是"固件看不到 CMOS 改动 → 不报 005"，
  但固件校验范围未知（<80%）。
- `hibernatemode 0` 时驱动空转，需先切到 25/3。
