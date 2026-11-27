// hdmi-recolor — 修复 LSPCON（DP→HDMI）hotplug 后外接屏泛红
//
// 策略（2026-11-24 用户定调）：**只换刷新率，不动分辨率**。
//   · 本机 1920x1080 下有 60 / 50 / 30 / 25 / 75Hz 五档。
//     1080p60 = 148.5MHz，1080p30 = 74.25MHz，1080p50 也是 148.5MHz。
//     ⇒ 切 30Hz（或 25Hz）会真正改变像素时钟 ⇒ DP 链路重训 ⇒ 消红；
//       切 50Hz 往往不重训（像素时钟不变）⇒ 实测不可靠，故不作为首选。
//   · 分辨率不变 ⇒ 窗口布局不重排，观感只是短促一下暗闪。
//
// 机制（实测口径）：
//   · 泛红发生在 LSPCON 内部，macOS 侧红态/正常态 ioreg 属性完全一致；
//     帧缓冲与截屏像素都中性 ⇒ 软件层不偏色，偏色在链路后级。
//   · 时序：修复必须落在系统自己那次收尾 modeset 之后，否则等于白闪。
//     判据（可自证）：色彩配置文件的 mtime 在我们修复之后不再变新。
//
// 用法：
//   hdmi-recolor                 等系统稳定后修一次（约 3~10 秒后屏短促闪一下）
//   hdmi-recolor --now           不等待，立刻修
//   hdmi-recolor --gentle        强制只用刷新率（默认已是此行为，保留兼容）
//   hdmi-recolor --deep          应急：允许换分辨率（会重排窗口，正常别用）
//   hdmi-recolor --status        只看状态（会列出同分辨率的所有刷新率）
//   hdmi-recolor --restore       强制恢复到上次修之前的模式（自愈用）
//   hdmi-recolor --mode 1920x1080@60   强制切到指定模式
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <math.h>
#include <dirent.h>
#include <sys/stat.h>

#define WS_PLIST  "/Library/Preferences/com.apple.windowserver.plist"
#define ICCDIR    "/Library/ColorSync/Profiles/Displays"
#define STATEFILE "/Users/thinkway/automation-workspace/.hdmi-recolor-state"

/* 只换刷新率；--deep 才允许换分辨率 */
static int g_allowResChange = 0;

static CGDirectDisplayID findExternal(void)
{
    CGDirectDisplayID ds[16];
    uint32_t n = 0;
    CGGetActiveDisplayList(16, ds, &n);
    for (uint32_t i = 0; i < n; i++)
        if (!CGDisplayIsBuiltin(ds[i]) && CGDisplayIsOnline(ds[i])) return ds[i];
    return 0;
}

/* ---- 切走前的原模式存档：万一没切回来，下次启动能自愈 ---- */
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

/* ---- 显示配置活动时间戳（判"系统是否刚改过配置"）---- */
static double wsStamp(void)
{
    struct stat st;
    if (stat(WS_PLIST, &st) != 0) return 0;
    return (double)st.st_mtimespec.tv_sec + (double)st.st_mtimespec.tv_nsec / 1e9;
}

static double iccStamp(void)
{
    double newest = 0;
    struct stat st;
    DIR *d = opendir(ICCDIR);
    if (!d) return 0;
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
    return newest;
}

static double activityStamp(void)
{
    double a = wsStamp(), b = iccStamp();
    return a > b ? a : b;
}

static double waitStable(double stableSecs, double maxWait)
{
    double t0 = CFAbsoluteTimeGetCurrent();
    double last = activityStamp(), lastChange = t0;
    for (;;) {
        usleep(300000);
        double now = CFAbsoluteTimeGetCurrent();
        double st = activityStamp();
        if (st != last) { last = st; lastChange = now; }
        if (now - lastChange >= stableSecs) return now - t0;
        if (now - t0 >= maxWait) return now - t0;
    }
}

/* ---- 估算像素时钟（MHz，含消隐的粗估，只用于相对比较）----
 * 消红的物理前提是**像素时钟改变**让 DP 链路重训；分辨率×刷新率决定它。
 * 所以选取逻辑按像素时钟算，不按刷新率数字，换任何显示器都自动适配。 */
static double estPclk(CGDisplayModeRef m)
{
    double hz = CGDisplayModeGetRefreshRate(m);
    if (hz <= 0) hz = 60.0;
    double w = (double)CGDisplayModeGetPixelWidth(m);
    double h = (double)CGDisplayModeGetPixelHeight(m);
    if (w <= 0 || h <= 0) { w = (double)CGDisplayModeGetWidth(m); h = (double)CGDisplayModeGetHeight(m); }
    return w * h * hz * 1.25 / 1e6;
}

/* ---- 选同分辨率的另一个刷新率 ----
 * 1) 优先 30Hz：正好半频、标准 CEA 格式，本机实测最稳（要求像素时钟变化 ≥10%）；
 * 2) 否则取**像素时钟相对变化最大**的那档 ⇒ 换屏幕也自动适配，没有写死的数字；
 * 3) 若最大变化 <3%（例如只有 60 与 59.94），说明这些刷新率像素时钟基本相同
 *    ⇒ 返回 NULL，上层明确放弃，绝不擅自动分辨率。 */
static CGDisplayModeRef pickAltSameRes(CGDisplayModeRef cur, CFArrayRef modes, double *outHz)
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
            *outHz = hz;
            return (CGDisplayModeRef)CFRetain(m);
        }
    }

    CGDisplayModeRef best = NULL;
    double bestRel = 0, bestHz = 0;
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
        if (rel > bestRel) { bestRel = rel; best = m; bestHz = hz; }
    }
    if (!best || bestRel < 0.03) return NULL;     /* 像素时钟改不动 ⇒ 不硬来 */
    *outHz = bestHz;
    return (CGDisplayModeRef)CFRetain(best);
}

/* 应急：换分辨率（--deep 才走这里） */
static CGDisplayModeRef pickAltDeep(CGDisplayModeRef cur, CFArrayRef modes)
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
            best = m; break;
        }
    }
    if (best) return (CGDisplayModeRef)CFRetain(best);
    (void)cid;
    return NULL;
}

/* ---- 找回原模式：ID → (w,h,hz) → (w,h) 最近刷新率 → 原对象 ----
 * 旧版只按 ID 找，切走后模式表在重建期间查不到 ID ⇒ 返回 NULL ⇒ 直接放弃
 * ⇒ 屏幕被永久留在低分辨率（11-24 14:58 / 14:59 两次事故）。这里必须多重兜底。 */
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
        usleep(500000);      /* 模式表可能正在重建，等一下再找 */
    }
    if (origObj) return (CGDisplayModeRef)CFRetain(origObj);
    return NULL;
}

/* 切到指定模式；返回 0 成功 */
static int switchTo(CGDirectDisplayID d, CGDisplayModeRef m)
{
    CGError e = CGDisplaySetDisplayMode(d, m, NULL);
    return e == kCGErrorSuccess ? 0 : (int)e;
}

/* 执行一轮修复：原模式 → 同分辨率异刷新率 → 切回。返回 0 成功。 */
static int doFix(int round)
{
    CGDirectDisplayID d = findExternal();
    if (!d) { printf("没有在线外接屏，跳过\n"); return 1; }
    CGDisplayModeRef cur = CGDisplayCopyDisplayMode(d);
    if (!cur) { printf("读取当前模式失败\n"); return 1; }

    int    origId = (int)CGDisplayModeGetIODisplayModeID(cur);
    size_t ow = CGDisplayModeGetWidth(cur), oh = CGDisplayModeGetHeight(cur);
    double ohz = CGDisplayModeGetRefreshRate(cur);

    CFArrayRef modes = CGDisplayCopyAllDisplayModes(d, NULL);
    if (!modes) { CFRelease(cur); return 1; }

    double altHz = 0;
    CGDisplayModeRef alt = pickAltSameRes(cur, modes, &altHz);
    if (!alt && g_allowResChange) alt = pickAltDeep(cur, modes);
    CFRelease(modes);
    if (!alt) {
        printf("同分辨率下没有别的刷新率可选，放弃（不改分辨率）\n");
        CFRelease(cur);
        return 2;
    }

    printf("[第 %d 轮] %zux%zu@%.0fHz → %zux%zu@%.0fHz → 切回\n", round,
           ow, oh, ohz,
           CGDisplayModeGetWidth(alt), CGDisplayModeGetHeight(alt),
           CGDisplayModeGetRefreshRate(alt));
    fflush(stdout);

    saveState(ow, oh, ohz, origId);

    int e1 = switchTo(d, alt);
    usleep(700000);   /* 30Hz 停留时间，与 watcher 的 SWITCH_HOLD_US 一致 */

    CGDisplayModeRef back = resolveMode(d, origId, ow, oh, ohz, cur);
    int e2 = back ? switchTo(d, back) : -1;
    if (back) CFRelease(back);
    CFRelease(alt);

    if (e1 == 0 && e2 == 0) {
        clearState();
        printf("      切换完成 (err=0/0)\n");
        CFRelease(cur);
        return 0;
    }
    printf("      切换失败 (err=%d/%d)，原模式已存档，下次启动会自动恢复\n", e1, e2);
    CFRelease(cur);
    return 3;
}

/* 自愈：上次切走没切回，就补恢复到存档的模式 */
static int recoverIfNeeded(void)
{
    size_t w, h; double hz; int id;
    if (!loadState(&w, &h, &hz, &id)) return 0;

    CGDirectDisplayID d = findExternal();
    if (!d) return 0;
    CGDisplayModeRef cur = CGDisplayCopyDisplayMode(d);
    if (!cur) return 0;

    int same = (CGDisplayModeGetWidth(cur) == w && CGDisplayModeGetHeight(cur) == h &&
                fabs(CGDisplayModeGetRefreshRate(cur) - hz) < 0.6);
    if (same) { clearState(); CFRelease(cur); return 0; }

    printf("发现上次未切回的模式存档，恢复到 %zux%zu@%.0fHz ...\n", w, h, hz);
    CGDisplayModeRef back = resolveMode(d, id, w, h, hz, NULL);
    CFRelease(cur);
    if (!back) return 0;
    int e = switchTo(d, back);
    CFRelease(back);
    if (e == 0) { clearState(); printf("      已恢复 (err=0)\n"); return 1; }
    printf("      恢复失败 (err=%d)\n", e);
    return 0;
}

/* 强制切到 "WxH@Hz" 指定模式 */
static int forceMode(const char *spec)
{
    unsigned w = 0, h = 0; double hz = 0;
    if (sscanf(spec, "%ux%u@%lf", &w, &h, &hz) != 3) {
        fprintf(stderr, "格式应为 WxH@Hz，例如 1920x1080@60\n");
        return 2;
    }
    CGDirectDisplayID d = findExternal();
    if (!d) { fprintf(stderr, "没有在线外接屏\n"); return 1; }
    CGDisplayModeRef m = resolveMode(d, 0, w, h, hz, NULL);
    if (!m) { fprintf(stderr, "找不到 %ux%u@%.0f 这个模式\n", w, h, hz); return 2; }
    int e = switchTo(d, m);
    printf("切到 %ux%u@%.0fHz：err=%d\n", w, h, hz, e);
    CFRelease(m);
    if (e == 0) clearState();
    return e == 0 ? 0 : 3;
}

/* 只读预演：它会挑哪一档、像素时钟变多少（不切换，换屏幕时先用它验证） */
static void printPlan(CGDirectDisplayID d)
{
    CGDisplayModeRef cur = CGDisplayCopyDisplayMode(d);
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(d, NULL);
    double curPclk = estPclk(cur);
    printf("当前：%zux%zu @%.2fHz，像素时钟约 %.1fMHz\n",
           CGDisplayModeGetWidth(cur), CGDisplayModeGetHeight(cur),
           CGDisplayModeGetRefreshRate(cur), curPclk);

    double altHz = 0;
    CGDisplayModeRef alt = modes ? pickAltSameRes(cur, modes, &altHz) : NULL;
    if (alt) {
        double p = estPclk(alt);
        printf("将切到：%zux%zu @%.2fHz，像素时钟约 %.1fMHz（变化 %+.0f%%）\n",
               CGDisplayModeGetWidth(alt), CGDisplayModeGetHeight(alt),
               CGDisplayModeGetRefreshRate(alt), p,
               curPclk > 0 ? (p / curPclk - 1.0) * 100.0 : 0.0);
        printf("=> 分辨率不变，只换刷新率；像素时钟变化足够触发链路重训\n");
        CFRelease(alt);
    } else {
        printf("该屏在当前分辨率下没有能改变像素时钟的刷新率\n");
        printf("=> 不改分辨率就无手段（可用 --deep 应急，但那会重排窗口）\n");
    }
    if (modes) CFRelease(modes);
    CFRelease(cur);
}

static void printStatus(CGDirectDisplayID d)
{
    CGDisplayModeRef cur = CGDisplayCopyDisplayMode(d);
    printf("外接屏 id=%u 当前 %zux%zu @%.2fHz modeId=%d\n",
           d, CGDisplayModeGetWidth(cur), CGDisplayModeGetHeight(cur),
           CGDisplayModeGetRefreshRate(cur), (int)CGDisplayModeGetIODisplayModeID(cur));
    size_t cw = CGDisplayModeGetWidth(cur), ch = CGDisplayModeGetHeight(cur);
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(d, NULL);
    printf("同分辨率（%zux%zu）可用的其它刷新率：", cw, ch);
    if (modes) {
        for (CFIndex j = 0; j < CFArrayGetCount(modes); j++) {
            CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, j);
            if (CGDisplayModeGetWidth(m) != cw || CGDisplayModeGetHeight(m) != ch) continue;
            double hz = CGDisplayModeGetRefreshRate(m);
            if (fabs(hz - CGDisplayModeGetRefreshRate(cur)) < 0.6) continue;
            printf("%.0fHz ", hz);
        }
        CFRelease(modes);
    }
    printf("\n");
    CFRelease(cur);
}

int main(int argc, char **argv)
{
    int statusOnly = 0, noWait = 0, restore = 0, planOnly = 0;
    const char *modeSpec = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--status")) statusOnly = 1;
        else if (!strcmp(argv[i], "--plan")) planOnly = 1;
        else if (!strcmp(argv[i], "--now")) noWait = 1;
        else if (!strcmp(argv[i], "--deep")) g_allowResChange = 1;
        else if (!strcmp(argv[i], "--gentle")) g_allowResChange = 0;
        else if (!strcmp(argv[i], "--restore")) restore = 1;
        else if (!strcmp(argv[i], "--mode") && i + 1 < argc) modeSpec = argv[++i];
    }

    CGDirectDisplayID d = findExternal();
    if (!d) { fprintf(stderr, "没有在线外接屏，无需修复\n"); return 0; }

    if (statusOnly) { printStatus(d); return 0; }
    if (planOnly)   { printPlan(d); return 0; }
    if (modeSpec)   return forceMode(modeSpec);
    if (restore)    return recoverIfNeeded() ? 0 : 1;

    /* 冷启动先自愈（上一次没切回来的情况） */
    recoverIfNeeded();

    if (!noWait) {
        double waited = waitStable(2.5, 20.0);
        printf("已等显示配置稳定 %.1fs（连续 2.5s 无变化）\n", waited);
        fflush(stdout);
    }

    int rc = doFix(1);
    if (rc != 0) return rc;
    printf("完成。若几秒后又变红，说明系统还在收尾，稍等 5 秒再运行一次本工具。\n");
    return 0;
}
