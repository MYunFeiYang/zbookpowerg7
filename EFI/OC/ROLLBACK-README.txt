========================================================
 雷电配置 —— macOS 起不来时的复位说明（急救卡）
 更新: 2026-09-14 20:52  |  当前档位: off（藏 RP01）
========================================================

【当前是什么档位】
  off 档（git commit 0fcd63b）= 藏掉 RP01 根端口，完全不加载雷电栈。
  这是 2026-08-24 ~ 09-14 用了三周的配置 —— 已验证稳定，
  重启起不来的概率接近零。
  意图：彻底关闭雷电（USB-C 的 DP / 雷雳功能），换取零 panic 风险。

【什么情况下才用这张卡】
  只在一种情况：重启后 macOS 起不来
  （卡苹果标 / 卡在 OpenCore 加载 / 无限重启 / 反复回菜单）。
  其他任何情况都不要动这里的东西。

【原理一句话】
  把 config.plist 换回 2026-09-14 20:23 那版（雷电 on 档，当天实测可正常启动）
  = 等于 off 档切换没发生过。

【做法：Windows 侧，约 2 分钟，纯手工，不需要任何工具或智能助手】

 第 1 步  开机时在 OpenCore 菜单选 "Windows" 启动。
          （若 OpenCore 菜单都出不来，按 F9 进 BIOS 启动菜单，选 Windows Boot Manager）

 第 2 步  开始菜单搜 cmd → 右键「以管理员身份运行」

 第 3 步  给 EFI 分区分配盘符，输入这一行后回车：
             mountvol S: /S
          若报错，改用下面这组：
             diskpart
             list disk
             select disk 0
             list partition
             select partition 1
             assign letter=S
             exit

 第 4 步  打开资源管理器，地址栏输入：  S:\EFI\OC\    回车
          ① 把文件 config.plist 改名成 config.BAD.plist（留着，别删）
          ② 把 config-ROLLBACK-2ae4799.plist 复制一份、改名成 config.plist
          （注意：只改这一个文件，别动 Kexts / ACPI 里其他东西）

 第 5 步  重启，进 macOS。复位完成。

【如果 S:\EFI\OC\ 里找不到 config-ROLLBACK-2ae4799.plist】
  说明主机的自动同步任务还没跑过。换一个来源取：
    资源管理器里找卷标是 "Common" 的盘（Windows 下可能是 D: 或 E:）
    进入  \workplace\zbookpowerg7\EFI\OC\
    同样把 config-ROLLBACK-2ae4799.plist 复制到 S:\EFI\OC\ 并改名覆盖 config.plist

【复位后是什么状态】
  = 雷电 on 档（git commit 2ae4799）
  = RP01 回来、USB-C 的 USB 数据通道可用；DP / 雷电设备不可用
    （这一档 2026-09-14 当天已实测可正常开机）
  ⚠️ on 档带 3 个已知 panic 风险：
       ① 点菜单栏 ExpressCard「关闭卡」= 必炸
       ② 睡眠时带着 USB-C 设备
       ③ 热插拔
     复位只是为了"先进得去系统"，进去后请重新决定要哪个档。

【复位成功后，回到 macOS 要多做一步（重要）】
  复位回的是 on 档，与当前工作区的 off 档不一致。选一个方向让两边对齐：

   (A) 想留在 on 档：
         cd /Volumes/Common/workplace/zbookpowerg7/EFI
         git checkout 2ae4799 -- OC/config.plist
         git commit -m "rollback: 回 on 档"

   (B) 想重新回到 off 档（推荐，除非你需要 USB-C 的高速）：
         cd /Volumes/Common/workplace/zbookpowerg7/EFI
         bash scripts/tb-thunderbolt-profile.sh off
         # 再把 ACPI-Add 里 #11 SSDT-TB3NHI-ZBook 的 Enabled 手动设成 false
         git commit -m "re-apply: off 档"

  为什么必须做：工作区是源头，不处理的话下次自动同步会把 ESP 又改回去。

【最坏情况兜底】
  这台机器有完整可用的 Windows（卷标 TZBOOK）。
  即使 macOS 一直起不来，电脑也不是砖头，办公照常。
  macOS 部分之后再慢慢修。

========================================================
 小抄：两个档位的 SSDT 开关对照

   current  off :  #10 TB3HP   = off
                  #11 TB3NHI  = off
                  #12 lite    = off
                  #13 disable = ON    <<< 藏 RP01
                  Kernel:Patch[1] AppleThunderboltNHI bypass = off

   rollback on :  #10 TB3HP   = ON    <<< force-power
                  #11 TB3NHI  = off
                  #12 lite    = off
                  #13 disable = off
                  Kernel:Patch[1] AppleThunderboltNHI bypass = ON
========================================================
