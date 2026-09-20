# 脱敏台账（公开仓库入库前）

> 远端 = `https://github.com/MYunFeiYang/zbookpowerg7.git` —— **公开仓库**（2026-09-20 实测 HTTP 200，可匿名克隆）。
> 本文件累积记录每次「入库前脱敏」动作，供审计；流程/判据见技能 **`public-repo-pii-redaction-audit`**。
> 铁律：**脱敏 ≠ 删行**（换占位符、保留结构，让结论可复算）。

---

## 2026-09-20 · ① win-side 跨 OS 取证产物

- 对象：`docs/backups/firmware-ledger-2026-09-20/win-side/`（9 个回传文件）
- 遮蔽 **10 处** → `<REDACTED-…>`：

| 字段 | 占位符 | 出现位置 |
|---|---|---|
| HP 序列号 | `<REDACTED-SERIAL>` | `HPBIOS-all.csv`、`SUMMARY.md` |
| 主板 CT 号 | `<REDACTED-BOARD-CT>` | 同上 |
| SMBIOS 系统 UUID（两种字节序写法） | `<REDACTED-UUID>` | 同上 |
| 引导路径 NVMe EUI64 | `<REDACTED-NVME-EUI>` | `HPBIOS-all.csv` |
| 引导路径 GPT 分区 GUID | `<REDACTED-GPT-GUID>` | `HPBIOS-all.csv` |

- **未删行**：`Name` / `DisplayInUI` / `IsReadOnly` / `RequiresPhysicalPresence` 全保留 ⇒ 台账 §8.1 结论仍可复算。
- 明细另见 `win-side/REDACTION.md`。

## 2026-09-20 · ② 本机 macOS 账号名（push 前审计发现）

- 对象：`docs/system-overhead-audit.md`
- 遮蔽 **8 处** → `<REDACTED-USER>`：
  - §10 CleanMyMac 残留表「**属主**」列（`ls -l` 输出被粘进文档）**7 行**
  - §14.2 `export PATH=$PATH:/Users/<REDACTED-USER>/.costrict/bin` **1 处**
- **并重写历史**：该串由 `56d11c7` / `d476a90` 引入，**均在本轮待推范围**（未公开）⇒ 用
  `git filter-branch --index-filter`（单文件精确替换，脚本幂等）重写 `origin/main..HEAD` 全部 **105** 个 commit。
- 验证：`git log main -S "/Users/<user>"` = **0**、`git grep "/Users/<user>" main` = **0**。
- 坑：filter-branch 在 100+ commit / 含 kext 二进制的仓库上要 **≈14 分钟**；前台默认超时会被 **SIGTERM(137)** 掐
  （被掐**无副作用**：refs 未更新、只需 `rm -rf .git-rewrite`）⇒ 必须 `run_in_background`。

---

## 保留项（经判据确认「不算 PII」或「不能动」）

| 项 | 位置 | 理由 |
|---|---|---|
| `SystemSerialNumber` / `MLB` / `SystemUUID` / `ROM=333333` | `EFI/OC/config.plist` `PlatformInfo` | 为 MacBookPro16,4 **生成的伪装值**，非本机 HP 标识（黑苹果常态） |
| `Acidanthera\thinkway` | `EFI/OC/config.plist` `Misc/Boot/PickerVariant` | OpenCore **主题变体目录名**（`Resources/Image/Acidanthera/thinkway/` 实际存在，删了会坏引导主题）；且自 `init` commit 起**已公开** ⇒ 改动=功能风险 > 隐私收益 |
| `/Users/runner`（135 处）、`/Users/zxystd`（85 处）、`/Users/dhinak` | kext 二进制 / 头文件 / CI 产物 | **上游作者 / GitHub Actions** 的路径，**非本机** |

## ⚠️ 既成事实（已在公开历史中存在；本次 push **不新增**其暴露面）

| 项 | 现状 |
|---|---|
| 引导路径 NVMe EUI64 + GPT 分区 GUID | 曾出现在旧 `config.plist` 的 `KaihongOS` 引导项里，由 `39dedce`（2026-08-04「清理冗余配置项」）删除；但 **`39dedce` 及更早已公开** ⇒ 该串在公开**历史**里可查。当前 `origin/main` **树**中已无（`git grep` = 0）。 |
| commit author 姓名 + 邮箱 | 所有 commit 的 author 元数据（自 `init` 起已公开） |

> 本次 push：`ac95467..6abf2d2`（`main`，**105 commit**，快进、无 `--force`）。
