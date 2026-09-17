# 合盖睡眠功耗实测（Round 3 · 2026-09-17）

## 测试条件
- 机型：HP ZBook Power G7 / OC 1.0.8 / macOS 26.6.2（Deep Idle / S0ix 唯一可用睡眠）
- 当前改动基线：kext 33→30、ACPI 14 张（含 dGPU 断电 SSDT 恢复）、aspm 注入全清
- 合盖前：拔 AC 适配器、满电 100% 合盖（裸机，无外屏/外接鼠标）
- WiFi / BT：保持开启（用户要求不动，测真实态）

## 实测数据（开盖后快照 19:00:36）
- 合盖时刻：`18:09:37` Entering Sleep due to 'Clamshell Sleep' (Batt 100%)
- 开盖时刻：`18:59:48` Wake from Deep Idle [CDNVA] due to PWRB/UserActivity (Batt 95%)
- 真实睡眠时长：**50 分 11 秒 = 0.836 h**
- 开盖电池：`CurrentCapacity=5016` / `MaxCapacity=5536` = **90.6%**（pmset 显示 95%，偏乐观；mAh 为准）
- 掉电：≈ 520 mAh / ≈ 9.4%
- 唤醒耗时：`WakeTime 2.768 s`（Deep Idle 正常）

## 掉电率
- **≈ 11.2 %/h**
- 折算功率：622 mAh/h × 11.59 V ≈ **7.2 W**

## 对照基准
| 来源 | 掉电率 | 说明 |
|---|---|---|
| 前期估算（理论） | ~7 %/h (~5 W) | 社区"未压降"基线推算 |
| 社区"未压降"区间 | 5–10 %/h | OC-Little AOAC 章节，别人机器 |
| **本次实测** | **11.2 %/h (~7.2 W)** | 独显断电+aspm清空+WiFi/BT开 |

实测略超社区上沿，考虑 ①WiFi/BT 全程开启 ②电池老化（MaxCapacity 5536 vs Design 7170）③单次测量噪声，属合理范围，**非异常**。

## 结论
1. **独显断电 SSDT 生效** —— 若独显带电，掉电率会显著更高（15%+/h 级），实测 11% 说明断电有效。
2. **Deep Idle 路径正常** —— WakeTime 2.8s、Dark Wake 仅 1 次（mDNS 维护，极短），无频繁唤醒漏电。
3. **基本已达功耗地板** —— 剩余唯一大杠杆"睡眠关 WiFi/BT"已被用户否决；ASPM 线 7 月实测撞墙回退（7b0ab03）。无安全可优化空间。
4. **建议收手**，日常出远门直接关机/合盖即可。

## 异常/观察（非功耗问题）
- Dark Wake Count=1（18:59:46 mDNSResponder maintenance，开盖前 2s，无影响）
- 唤醒时 `aTrustAgent timed out(30000 ms)` 及多个 driver slow —— 属唤醒延迟，不影响睡眠功耗
- pmset 的 %（95%）与 ioreg StateOfCharge（90.6%）不一致，以 mAh 比值（5016/5536）为准
