// hdmi-recolor-watch — 常驻监听外接屏，热插拔后自动重协商，消除 LSPCON 泛红
//
// 机制（全部实测口径，勿凭推断改动）：
//   · 泛红发生在 LSPCON（DP→HDMI 转换芯片）内部，macOS 侧属性红态/正常态完全一致。
//   · 消红的有效动作是**让 DP 链路真正重新训练**：切到不同像素时钟的模式再切回。
//     **只换刷新率、不动分辨率**（2026-11-24 用户定调）：
//       本机 1920x1080 下有 60/50/30/25/75Hz；1080p60=148.5MHz、1080p30=74.25MHz、
//       1080p50 也是 148.5MHz。⇒ 切 30Hz（或 25Hz）像素时钟减半 ⇒ 必重训链路；
//       切 50Hz 往往不重训 ⇒ 实测不可靠，只作兜底。分辨率不变 ⇒ 窗口不重排。
//   · 时序：修复要落在系统自己那次收尾 modeset 之后，否则等于白闪。
//     ICC 的 mtime 变化 = 系统刚重写过色彩配置，用它判断"是否已收尾"。
//
// 检测（11-24 14:45 返工，原因是实测到两次漏检）：
//   · 旧版只看"外接屏集合差异"。快速拔插（<1s）时集合快照始终是同一块屏，
//     集合前后一致 ⇒ 整条流程被静默跳过 ⇒ 屏幕保持红。日志里第二次插拔零记录即此。
//   · 现以 IOKit general-interest 通知为主通道：注册在 IOFramebuffer /
//     AppleIntelFramebuffer 上，驱动每次 setProperty 都会回调注册者。
//     实测（/tmp/ioklisten）：**别的进程**做 modeset，独立监听进程收到 2 个事件
//     ⇒ 与发起者无关（对比：CGDisplayRegisterReconfigurationCallback 跨进程 0 事件）。
//   · 收到事件即便集合没变化，也判定为 hotplug 并修复。
//   · 1 秒轮询保留作兜底（单次 183µs / 约 0.018% CPU，实测）。
#include <ApplicationServices/ApplicationServices.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/IOMessage.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <math.h>
#include <stdarg.h>
#include <sys/stat.h>

#define LOGPATH        "/Users/thinkway/automation-workspace/hdmi-recolor.log"
#define STATEFILE      "/Users/thinkway/automation-workspace/.hdmi-recolor-state"
#define LOGMAX         (512 * 1024)
#define ICCDIR         "/Library/ColorSync/Profiles/Displays"
#define MAXDISP        16
#define POLL_MS        1000
#define EVENT_DEBOUNCE 1.2        /* 事件成批到达，等这批落定再判断 */
#define MIN_SETTLE_SEC 8          /* 距判定 hotplug 至少等这么久才动手 */
#define QUIET_SEC      3          /* 显示配置连续无变化多少秒算稳定 */
#define MAX_SETTLE_SEC 20
#define SWITCH_HOLD_US 1500000
/* 修复后吸收自身尾随事件的窗口。实测（/tmp/iokidle + 一次 --deep）：
 * 一次自身修复会产生**两批**事件——切回完成瞬间一批(+~7s)，其后整 10 秒再来一批(+~17s)。
 * 窗口必须大于 10 秒，否则第二批会把刚修好的状态当成新 hotplug，陷入每 10 秒闪一次的循环。 */
#define SUPPRESS_AFTER_FIX 15.0
#define SLEEP_JUMP_SEC 6

/* IOGraphics 家族的显示模式变更通知（实测收到的值） */
#define kIOFBNotifyDisplayModeChanged 0xe0016007

static int            g_fixing = 0;
static int            g_allowResChange = 0;   /* 0 = 只换刷新率；env HDMI_RECOLOR_DEEP=1 才允许换分辨率 */
static CFAbsoluteTime g_lastFixEnd = 0;
static CFAbsoluteTime g_suppressUntil = 0;
static CFRunLoopTimerRef g_checkTimer = NULL;
static time_t         g_lastTick = 0;
static CGDirectDisplayID g_prev[MAXDISP];
static int            g_nprev = 0;
static unsigned long  g_evTotal = 0;      /* 累计事件数，用于诊断主通道是否活着 */

static io_connect_t          g_pmPort = 0;
static IONotificationPortRef g_pmPortRef = NULL;
static io_object_t           g_pmNotifier = 0;
static IONotificationPortRef g_fbPortRef = NULL;

static void logmsg(const char *fmt, ...)
{
    struct stat st;
    if (stat(LOGPATH, &st) == 0 && st.st_size > LOGMAX)
        truncate(LOGPATH, 0);
    FILE *f = fopen(LOGPATH, "a");
    if (!f) return;
    time_t t = time(NULL);
    struct tm tv;
    localtime_r(&t, &tv);
    fprintf(f, "[%04d-%02d-%02d %02d:%02d:%02d] ",
            tv.tm_year + 1900, tv.tm_mon + 1, tv.tm_mday,
            tv.tm_hour, tv.tm_min, tv.tm_sec);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fprintf(f, "\n");
    fclose(f);
}

static double fileStamp(const char *p)
{
    struct stat st;
    if (stat(p, &st) != 0) return 0;
    return (double)st.st_mtimespec.tv_sec + (double)st.st_mtimespec.tv_nsec / 1e9;
}

static double iccStamp(void)
{
    double newest = 0;
    struct stat st;
    DIR *d = opendir(ICCDIR);
    if (d) {
        struct dirent *e;
        char path[512];
        while ((e = readdir(d))) {
            if (e->d_name[0] == '.') continue;
            if (!strstr(e->d_name, ".icc")) continue;
            snprintf(path, sizeof(path), "%s/%s", ICCDIR, e->d_name);
            if (stat(path, &st) == 0) {
                double v = (double)st.st_mtimespec.tv_sec + (double)st.st_mtimespec.tv_nsec / 1e9;
                if (v > newest) newest = v;
            }
        }
        closedir(d);
    }
    return newest;
}

/* 是否已收尾：颜色配置目录连续 QUIET_SEC 秒没被重写 */
static double activityStamp(void) { return iccStamp(); }

static int listExternal(CGDirectDisplayID *out, int max)
{
    CGDirectDisplayID ds[MAXDISP];
    uint32_t n = 0;
    if (CGGetActiveDisplayList(MAXDISP, ds, &n) != kCGErrorSuccess) return 0;
    int k = 0;
    for (uint32_t i = 0; i < n && k < max; i++)
        if (!CGDisplayIsBuiltin(ds[i])) out[k++] = ds[i];
    return k;
}

static int contains(const CGDirectDisplayID *arr, int n, CGDirectDisplayID v)
{
    for (int i = 0; i < n; i++) if (arr[i] == v) return 1;
    return 0;
}

static void snapshotBaseline(void) { g_nprev = listExternal(g_prev, MAXDISP); }

/* ---- 切走前的原模式存档：万一没切回来，下次启动能自愈 ----
 * 11-24 14:58 / 14:59 两次事故：只按 IODisplayModeID 找原模式，切走后模式表
 * 重建期间查不到 ⇒ 返回 NULL ⇒ 直接放弃 ⇒ 屏幕被永久留在低分辨率。 */
static void saveState(size_t w, size_t h, double hz, int id)
{
    FILE *f = fopen(STATEFILE, "w");
    if (!f) return;
    fprintf(f, "%zu %zu %.4f %d\n", w, h, hz, id);
    fclose(f);
}

static int loadState(size_t *w, size_t *h, double *hz, int *id)
{
    FILE *f = fopen(STATEFILE, "r");
    if (!f) return 0;
    int n = fscanf(f, "%zu %zu %lf %d", w, h, hz, id);
    fclose(f);
    return n == 4;
}

static void clearState(void) { unlink(STATEFILE); }

/* 找回原模式：ID → (w,h,hz) → (w,h) 最近刷新率 → 原对象，带重试 */
static CGDisplayModeRef resolveMode(CGDirectDisplayID d, int wantId,
                                    size_t w, size_t h, double hz,
                                    CGDisplayModeRef origObj)
{
    for (int attempt = 0; attempt < 8; attempt++) {
        CFArrayRef modes = CGDisplayCopyAllDisplayModes(d, NULL);
        if (modes) {
            CGDisplayModeRef byId = NULL, byTriple = NULL, bySize = NULL;
            double bestD = 1e9;
            for (CFIndex j = 0; j < CFArrayGetCount(modes); j++) {
                CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, j);
                if (!byId && (int)CGDisplayModeGetIODisplayModeID(m) == wantId) byId = m;
                size_t mw = CGDisplayModeGetWidth(m), mh = CGDisplayModeGetHeight(m);
                if (mw != w || mh != h) continue;
                double mhz = CGDisplayModeGetRefreshRate(m);
                if (!byTriple && fabs(mhz - hz) < 0.6) byTriple = m;
                double dd = fabs(mhz - hz);
                if (dd < bestD) { bestD = dd; bySize = m; }
            }
            CGDisplayModeRef pick = byId ? byId : (byTriple ? byTriple : bySize);
            CGDisplayModeRef r = pick ? (CGDisplayModeRef)CFRetain(pick) : NULL;
            CFRelease(modes);
            if (r) return r;
        }
        usleep(500000);
    }
    if (origObj) return (CGDisplayModeRef)CFRetain(origObj);
    return NULL;
}

/* 估算像素时钟（MHz，含消隐粗估，只用于相对比较）。
 * 消红的物理前提是**像素时钟改变**让 DP 链路重训 ⇒ 按它选，不按刷新率数字。 */
static double estPclk(CGDisplayModeRef m)
{
    double hz = CGDisplayModeGetRefreshRate(m);
    if (hz <= 0) hz = 60.0;
    double w = (double)CGDisplayModeGetPixelWidth(m);
    double h = (double)CGDisplayModeGetPixelHeight(m);
    if (w <= 0 || h <= 0) { w = (double)CGDisplayModeGetWidth(m); h = (double)CGDisplayModeGetHeight(m); }
    return w * h * hz * 1.25 / 1e6;
}

/* 同分辨率换刷新率：1) 优先 30Hz（半频、标准 CEA、本机实测最稳）；
 * 2) 否则取像素时钟相对变化最大那档 ⇒ 换屏幕自动适配，无写死数字；
 * 3) 最大变化 <3% ⇒ 返回 NULL，上层明确放弃，绝不擅自动分辨率。 */
static CGDisplayModeRef pickAltSameRes(CGDisplayModeRef cur, CFArrayRef modes, int *isDeep)
{
    size_t cw = CGDisplayModeGetWidth(cur), ch = CGDisplayModeGetHeight(cur);
    int    cid = (int)CGDisplayModeGetIODisplayModeID(cur);
    double chz = CGDisplayModeGetRefreshRate(cur);
    double curPclk = estPclk(cur);

    for (CFIndex j = 0; j < CFArrayGetCount(modes); j++) {
        CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, j);
        if ((int)CGDisplayModeGetIODisplayModeID(m) == cid) continue;
        if (CGDisplayModeGetWidth(m) != cw || CGDisplayModeGetHeight(m) != ch) continue;
        double hz = CGDisplayModeGetRefreshRate(m);
        if (fabs(hz - 30.0) >= 0.6 || fabs(hz - chz) < 1.0) continue;
        double p = estPclk(m);
        double hzRel = chz > 0 ? fabs(hz - chz) / chz : 1.0;
        if (curPclk > 0 && fabs(p - curPclk) / curPclk >= 0.10 && hzRel >= 0.20) {
            *isDeep = 0;
            return (CGDisplayModeRef)CFRetain(m);
        }
    }

    CGDisplayModeRef best = NULL;
    double bestRel = 0;
    for (CFIndex j = 0; j < CFArrayGetCount(modes); j++) {
        CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, j);
        if ((int)CGDisplayModeGetIODisplayModeID(m) == cid) continue;
        if (CGDisplayModeGetWidth(m) != cw || CGDisplayModeGetHeight(m) != ch) continue;
        double hz = CGDisplayModeGetRefreshRate(m);
        if (hz < 23.0) continue;
        double hzRel = chz > 0 ? fabs(hz - chz) / chz : 0;
        if (hzRel < 0.20) continue;     /* 1080p50 与 60 像素时钟相同，光靠刷新率差区分不了 */
        double p = estPclk(m);
        double rel = curPclk > 0 ? fabs(p - curPclk) / curPclk : 0;
        if (rel > bestRel) { bestRel = rel; best = m; }
    }
    if (!best || bestRel < 0.03) return NULL;
    *isDeep = 0;
    return (CGDisplayModeRef)CFRetain(best);
}

static CGDisplayModeRef pickAltDeep(CGDisplayModeRef cur, CFArrayRef modes, int *isDeep)
{
    size_t cw = CGDisplayModeGetWidth(cur), ch = CGDisplayModeGetHeight(cur);
    int    cid = (int)CGDisplayModeGetIODisplayModeID(cur);
    CGDisplayModeRef best = NULL;

    static const size_t deeps[][2] = { {1280,720}, {1024,768}, {1600,900}, {1280,800} };
    for (size_t k = 0; k < sizeof(deeps)/sizeof(deeps[0]) && !best; k++) {
        for (CFIndex j = 0; j < CFArrayGetCount(modes); j++) {
            CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, j);
            if (CGDisplayModeGetWidth(m) != deeps[k][0]) continue;
            if (CGDisplayModeGetHeight(m) != deeps[k][1]) continue;
            if (CGDisplayModeGetWidth(m) == cw && CGDisplayModeGetHeight(m) == ch) continue;
            best = m;
            break;
        }
    }

    if (!best) {
        double bestPix = 1e18;
        for (CFIndex j = 0; j < CFArrayGetCount(modes); j++) {
            CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, j);
            if ((int)CGDisplayModeGetIODisplayModeID(m) == cid) continue;
            size_t w = CGDisplayModeGetWidth(m), h = CGDisplayModeGetHeight(m);
            if (w * h >= cw * ch / 2) continue;
            if ((double)(w * h) < bestPix) { bestPix = (double)(w * h); best = m; }
        }
    }
    if (!best) return NULL;
    *isDeep = 1;
    return (CGDisplayModeRef)CFRetain(best);
}

static CGDisplayModeRef pickAlt(CGDirectDisplayID d, CGDisplayModeRef cur, int *isDeep)
{
    (void)d;
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(d, NULL);
    if (!modes) return NULL;
    CGDisplayModeRef r = pickAltSameRes(cur, modes, isDeep);
    if (!r && g_allowResChange) r = pickAltDeep(cur, modes, isDeep);
    CFRelease(modes);
    return r;
}

static int doFix(CGDirectDisplayID d, const char *why)
{
    CGDisplayModeRef cur = CGDisplayCopyDisplayMode(d);
    if (!cur) { logmsg("fix: 读不到当前模式，放弃"); return -1; }

    int    origId = (int)CGDisplayModeGetIODisplayModeID(cur);
    size_t ow = CGDisplayModeGetWidth(cur), oh = CGDisplayModeGetHeight(cur);
    double ohz = CGDisplayModeGetRefreshRate(cur);

    int isDeep = 0;
    CGDisplayModeRef alt = pickAlt(d, cur, &isDeep);
    if (!alt) {
        logmsg("fix: 同分辨率下没有别的刷新率（单一模式屏），不改分辨率 ⇒ 放弃");
        CFRelease(cur);
        return -1;
    }

    g_fixing = 1;
    logmsg("fix 开始（%s）：%zux%zu@%.0fHz -> %zux%zu@%.0fHz -> 切回",
           why,
           ow, oh, ohz,
           CGDisplayModeGetWidth(alt), CGDisplayModeGetHeight(alt),
           CGDisplayModeGetRefreshRate(alt));

    saveState(ow, oh, ohz, origId);

    CGError e1 = CGDisplaySetDisplayMode(d, alt, NULL);
    usleep(SWITCH_HOLD_US);
    CGDisplayModeRef back = resolveMode(d, origId, ow, oh, ohz, cur);
    CGError e2 = back ? CGDisplaySetDisplayMode(d, back, NULL) : -1;
    if (back) CFRelease(back);

    int ok = (e1 == kCGErrorSuccess && e2 == kCGErrorSuccess);
    logmsg("fix 结束：err=%d/%d %s", (int)e1, (int)e2, ok ? "成功" : "失败（原模式已存档，下次启动自愈）");
    if (ok) clearState();

    CFRelease(alt);
    CFRelease(cur);
    g_lastFixEnd = CFAbsoluteTimeGetCurrent();
    g_fixing = 0;
    return ok ? 0 : -1;
}

/* 冷启动自愈：上一次切走没切回来（例如被杀 / 切回时模式表还在重建）就补恢复 */
static void recoverIfNeeded(void)
{
    size_t w, h; double hz; int id;
    if (!loadState(&w, &h, &hz, &id)) return;

    CGDirectDisplayID ds[MAXDISP];
    int n = listExternal(ds, MAXDISP);
    if (n <= 0) return;

    for (int i = 0; i < n; i++) {
        CGDisplayModeRef cur = CGDisplayCopyDisplayMode(ds[i]);
        if (!cur) continue;
        int same = (CGDisplayModeGetWidth(cur) == w && CGDisplayModeGetHeight(cur) == h &&
                    fabs(CGDisplayModeGetRefreshRate(cur) - hz) < 0.6);
        CFRelease(cur);
        if (same) { clearState(); return; }
    }
    logmsg("发现上次未切回的模式存档 ⇒ 尝试恢复到 %zux%zu@%.0fHz", w, h, hz);
    for (int i = 0; i < n; i++) {
        CGDisplayModeRef back = resolveMode(ds[i], id, w, h, hz, NULL);
        if (!back) continue;
        CGError e = CGDisplaySetDisplayMode(ds[i], back, NULL);
        CFRelease(back);
        logmsg("  恢复 display %u：err=%d", ds[i], (int)e);
        if (e == kCGErrorSuccess) { clearState(); return; }
    }
}

/* 等系统收尾：ICC 连续 QUIET_SEC 秒不再变，且距判定 hotplug 已过 MIN_SETTLE_SEC。 */
static double waitForSettle(void)
{
    struct timespec t0, now;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    double last = activityStamp();
    double lastChange = 0;

    logmsg("  等待系统收尾（色彩配置需连续 %d 秒无变化，至少等 %d 秒）",
           QUIET_SEC, MIN_SETTLE_SEC);

    for (;;) {
        usleep(500000);
        clock_gettime(CLOCK_MONOTONIC, &now);
        double elapsed = (now.tv_sec - t0.tv_sec) + (now.tv_nsec - t0.tv_nsec) / 1e9;
        double st = activityStamp();
        if (st != last) {
            last = st;
            lastChange = elapsed;
            logmsg("  色彩配置仍在重写（%.1fs），继续等", elapsed);
        }
        if (elapsed >= MIN_SETTLE_SEC && elapsed - lastChange >= QUIET_SEC) {
            logmsg("  已稳定（等了 %.1f 秒），开始修复", elapsed);
            return elapsed;
        }
        if (elapsed >= MAX_SETTLE_SEC) {
            logmsg("  等待到上限 %d 秒，直接修复", MAX_SETTLE_SEC);
            return elapsed;
        }
    }
}

static void handleHotplug(CGDirectDisplayID d, const char *trigger)
{
    logmsg("外接屏 display %u 判定为 hotplug（%s）", d, trigger);
    double waited = waitForSettle();

    CGDirectDisplayID chk[MAXDISP];
    int nchk = listExternal(chk, MAXDISP);
    if (!contains(chk, nchk, d)) {
        logmsg("  等待期间该屏已消失，取消");
        snapshotBaseline();
        return;
    }

    logmsg("  共等 %.1f 秒后开始修复", waited);
    doFix(d, trigger);
    snapshotBaseline();
}

/* byEvent = 1 表示由 framebuffer 属性变化通知驱动：
 * 此时集合可能丝毫未变（快速拔插），仍要按 hotplug 处理。 */
static void evaluate(const char *trigger, int byEvent)
{
    if (g_fixing) return;

    CGDirectDisplayID cur[MAXDISP];
    int ncur = listExternal(cur, MAXDISP);

    CGDirectDisplayID appeared = 0;
    for (int i = 0; i < ncur; i++)
        if (!contains(g_prev, g_nprev, cur[i])) { appeared = cur[i]; break; }

    int disconnected = 0;
    for (int i = 0; i < g_nprev; i++)
        if (!contains(cur, ncur, g_prev[i])) {
            logmsg("外接屏 display %u 已断开", g_prev[i]);
            disconnected = 1;
        }

    /* 看到真实断开就解除"修复后抑制"：自身修复绝不会让集合变空，
     * 所以断开一定是用户拔线。否则刚修完 15 秒内拔插会被窗口吞掉。 */
    if (disconnected) g_lastFixEnd = 0;

    CGDirectDisplayID target = appeared;
    if (!target && byEvent && ncur > 0) {
        target = cur[ncur - 1];
        logmsg("收到显示配置变化且集合未变 ⇒ 判定为快速拔插（旧版会在此漏检）");
    }

    if (!target) { snapshotBaseline(); return; }

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now < g_suppressUntil) {
        logmsg("处于睡眠唤醒抑制窗口内，不动作（距窗口结束 %.0f 秒）",
               g_suppressUntil - now);
        snapshotBaseline();
        return;
    }
    if (now - g_lastFixEnd < SUPPRESS_AFTER_FIX) {
        logmsg("距上次修复不足 %.0f 秒，判定为自身尾随事件，忽略",
               SUPPRESS_AFTER_FIX);
        snapshotBaseline();
        return;
    }

    g_fixing = 1;
    handleHotplug(target, trigger);
    g_fixing = 0;
    g_lastTick = time(NULL);            /* 抹掉本轮长时间阻塞，避免误判成睡眠 */
    g_lastFixEnd = CFAbsoluteTimeGetCurrent();
}

static void checkTimerFired(CFRunLoopTimerRef timer, void *info)
{
    (void)info;
    CFRunLoopTimerInvalidate(timer);
    if (g_checkTimer == timer) { CFRelease(g_checkTimer); g_checkTimer = NULL; }
    evaluate("事件通知", 1);
}

static void scheduleCheck(CFTimeInterval delay)
{
    if (g_checkTimer) return;
    g_checkTimer = CFRunLoopTimerCreate(NULL,
                                        CFAbsoluteTimeGetCurrent() + delay,
                                        0, 0, 0, checkTimerFired, NULL);
    if (g_checkTimer) CFRunLoopAddTimer(CFRunLoopGetCurrent(), g_checkTimer, kCFRunLoopDefaultMode);
}

/* 主检测通道：framebuffer 属性变化由驱动 setProperty 逐回调注册者，
 * 与"谁发起的改动"无关，故拔插（系统发起）同样能收到。 */
static void fbInterestCb(void *refcon, io_service_t svc, natural_t msgType, void *msgArg)
{
    (void)refcon; (void)svc; (void)msgArg;
    if (msgType != kIOFBNotifyDisplayModeChanged &&
        msgType != kIOMessageServicePropertyChange &&
        msgType != kIOMessageServiceIsTerminated)
        return;

    g_evTotal++;
    if (g_fixing) return;
    if (CFAbsoluteTimeGetCurrent() - g_lastFixEnd < SUPPRESS_AFTER_FIX) {
        /* 自身修复的尾随事件（实测第二批落在 +10s），吸收掉，否则会陷入每 10 秒闪一次的循环 */
        logmsg("（事件落在修复后 %.0f 秒抑制窗口内，吸收）",
               CFAbsoluteTimeGetCurrent() - g_lastFixEnd);
        return;
    }
    scheduleCheck(EVENT_DEBOUNCE);
}

static void registerFramebufferNotifications(CFRunLoopRef rl)
{
    g_fbPortRef = IONotificationPortCreate(kIOMainPortDefault);
    if (!g_fbPortRef) { logmsg("⚠ IOKit 通知端口创建失败，只能靠轮询"); return; }
    CFRunLoopAddSource(rl, IONotificationPortGetRunLoopSource(g_fbPortRef),
                       kCFRunLoopDefaultMode);

    const char *cls[] = { "IOFramebuffer", "AppleIntelFramebuffer" };
    int n = 0;
    for (int c = 0; c < 2; c++) {
        io_iterator_t it = 0;
        CFMutableDictionaryRef m = IOServiceMatching(cls[c]);
        if (!m) continue;
        if (IOServiceGetMatchingServices(kIOMainPortDefault, m, &it) != KERN_SUCCESS) continue;
        io_object_t s;
        while ((s = IOIteratorNext(it))) {
            io_object_t notif = 0;
            if (IOServiceAddInterestNotification(g_fbPortRef, s, kIOGeneralInterest,
                                                 fbInterestCb, NULL, &notif) == KERN_SUCCESS) {
                IOObjectRetain(s);
                n++;
            }
            IOObjectRelease(s);
        }
        IOObjectRelease(it);
    }
    logmsg("已注册 %d 个 framebuffer 通知（主检测通道），1s 轮询作兜底", n);
}

static void pollFired(CFRunLoopTimerRef timer, void *info)
{
    (void)timer; (void)info;
    time_t now = time(NULL);
    long jump = (long)(now - g_lastTick);
    g_lastTick = now;
    if (jump > SLEEP_JUMP_SEC) {
        logmsg("检测到睡眠/挂起（时间跳跃 %lds），唤醒后 30 秒内不动作", jump);
        g_suppressUntil = CFAbsoluteTimeGetCurrent() + 30.0;
        snapshotBaseline();
        return;
    }
    evaluate("轮询兜底", 0);
}

static void reconfigCb(CGDirectDisplayID display,
                       CGDisplayChangeSummaryFlags flags, void *ctx)
{
    (void)display; (void)ctx;
    if (flags & kCGDisplayBeginConfigurationFlag) return;
    if (g_fixing) return;
    scheduleCheck(EVENT_DEBOUNCE);
}

static void pmCallback(void *refcon, io_service_t svc, natural_t msgType, void *msgArg)
{
    (void)refcon; (void)svc;
    switch (msgType) {
    case kIOMessageCanSystemSleep:
    case kIOMessageSystemWillSleep:
        IOAllowPowerChange(g_pmPort, (long)(intptr_t)msgArg);
        break;
    case kIOMessageSystemHasPoweredOn:
        g_suppressUntil = CFAbsoluteTimeGetCurrent() + 30.0;
        g_lastTick = time(NULL);
        logmsg("系统已唤醒：30 秒内不动作");
        snapshotBaseline();
        break;
    default:
        break;
    }
}

int main(void)
{
    CFRunLoopRef rl = CFRunLoopGetCurrent();

    snapshotBaseline();
    g_lastTick = time(NULL);
    logmsg("====== watcher 启动（pid %d，framebuffer 事件为主 + 1s 轮询兜底）", (int)getpid());
    logmsg("  基线外接屏 %d 台%s", g_nprev, g_nprev ? "，启动不动作" : "");
    for (int i = 0; i < g_nprev; i++) {
        CGDisplayModeRef m = CGDisplayCopyDisplayMode(g_prev[i]);
        if (m) {
            logmsg("  基线 display %u  %zux%zu@%.0fHz", g_prev[i],
                   CGDisplayModeGetWidth(m), CGDisplayModeGetHeight(m),
                   CGDisplayModeGetRefreshRate(m));
            CFRelease(m);
        }
    }

    const char *deep = getenv("HDMI_RECOLOR_DEEP");
    if (deep && deep[0] == '1') {
        g_allowResChange = 1;
        logmsg("⚠ HDMI_RECOLOR_DEEP=1：允许换分辨率（应急模式）");
    }

    recoverIfNeeded();

    registerFramebufferNotifications(rl);
    CGDisplayRegisterReconfigurationCallback(reconfigCb, NULL);

    g_pmPort = IORegisterForSystemPower(NULL, &g_pmPortRef, pmCallback, &g_pmNotifier);
    if (g_pmPort && g_pmPortRef)
        CFRunLoopAddSource(rl, IONotificationPortGetRunLoopSource(g_pmPortRef),
                           kCFRunLoopDefaultMode);

    CFRunLoopTimerRef timer = CFRunLoopTimerCreate(
        NULL, CFAbsoluteTimeGetCurrent() + POLL_MS / 1000.0, POLL_MS / 1000.0,
        0, 0, pollFired, NULL);
    if (timer) {
        CFRunLoopTimerSetTolerance(timer, 0.2);
        CFRunLoopAddTimer(rl, timer, kCFRunLoopDefaultMode);
    }

    const char *st = getenv("HDMI_RECOLOR_SELFTEST");
    if (st && st[0] == '1') {
        logmsg("自检模式：基线置空并立即走完整流程");
        g_nprev = 0;
        evaluate("自检", 0);
    }

    CFRunLoopRun();
    return 0;
}
