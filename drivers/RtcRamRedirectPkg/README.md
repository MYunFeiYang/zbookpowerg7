# RtcRamRedirect

一个 UEFI DXE 驱动，替换 Apple RTC RAM 协议，把 macOS 休眠变量窗口（CMOS 0x80–0xAB）
改成从 NVRAM 变量 `IOHibernateRTCVariables` 提供服务。用于 HP 笔记本黑苹果上消除
S4 休眠后开机报 **POST 005 (Real-Time Clock Power Loss)** 的成因之一。

设计/部署/回滚见 `docs/rtc-nvram-redirect-deploy-2026-11-20.md`。

## 安全语义（重要）

驱动**按需武装**：只有当 NVRAM 里确实存在 `IOHibernateRTCVariables` 时，才接管 0x80–0xAB；
否则全部透传真实硬件，行为与没装这个驱动完全等价。

`IOHibernateRTCVariables` 由系统自带的 `com.apple.driver.AppleRTC`
（`setHibernateState`）在真正写休眠镜像时写入 NVRAM `/options`，无需任何内核补丁。

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

## 产物校验

```
RtcRamRedirect.efi  14944 B
PE32+ / x86-64 / subsystem 11 (EFI boot service driver)
3 sections: .text .data .reloc   1 base relocation (gEfiCallerBaseName)
```

## 未解决

- 不解决恢复后 iGPU 花屏（独立问题）。
- 005 是否真消失未验证：AppleRTC 睡眠时仍直写 CMOS，驱动管不到那一步。
