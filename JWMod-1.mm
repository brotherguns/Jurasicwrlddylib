// JWMod.mm — Jurassic World: The Game Full Mod Dylib
// Compile:
//   clang++ -arch arm64 -shared -fno-objc-arc -ObjC++ \
//     -isysroot /path/to/iPhoneOS.sdk -miphoneos-version-min=14.0 \
//     -framework Foundation \
//     -o JWMod.dylib JWMod.mm
//   install_name_tool -id @executable_path/JWMod.dylib JWMod.dylib

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <pthread.h>
#include <sys/sysctl.h>
#include <sys/proc.h>
#include <libkern/OSCacheControl.h>

// ===================================================================
//  FEATURE TOGGLES
// ===================================================================
#define MOD_BYPASS_LAUNCH_CHECKS  1
#define MOD_BYPASS_SYSCTL         1
#define MOD_SPEND_FREEZE          1
#define MOD_ENABLE_VIP            1
#define MOD_FREE_PACKS            1
#define MOD_EVOLUTION_SUCCESS     1
#define MOD_FEED_MAX_LEVEL        1
#define MOD_FREE_SPEEDUP          1
#define MOD_INSTANT_HATCH         1
#define MOD_INSTANT_FUSION        1
#define MOD_INSTANT_BUILDINGS     1
#define MOD_BATTLE_ONE_HIT        1
#define MOD_BATTLE_NO_DAMAGE      1

// ===================================================================
//  ARM64 PATCHER
//  Only use on symbols inside the game binary itself — NEVER on
//  system library functions (sysctl, dyld, etc.) which live in the
//  shared cache and will corrupt the whole process if patched inline.
// ===================================================================
static void patch_branch(void* src, void* dst) {
    if (!src || !dst) return;
    vm_address_t page = (vm_address_t)src & ~0xFFFULL;
    kern_return_t kr = vm_protect(mach_task_self(), page, 0x4000, false,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) { printf("[JWMod] vm_protect failed %p: %d\n", src, kr); return; }
    uint32_t* p = (uint32_t*)src;
    p[0] = 0x58000050u; // LDR X16, #8
    p[1] = 0xD61F0200u; // BR  X16
    *((uint64_t*)(p + 2)) = (uint64_t)dst;
    vm_protect(mach_task_self(), page, 0x4000, false, VM_PROT_READ | VM_PROT_EXECUTE);
    sys_icache_invalidate(src, 16);
}

// Only patch symbols that live in the main game binary
// (slide > 0 and within the game's mapped region)
static bool is_game_symbol(void* addr) {
    if (!addr) return false;
    // Check that the symbol belongs to the main executable (image index 0)
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    uintptr_t a = (uintptr_t)addr;
    // Main binary symbols will have addresses in a reasonable range
    // (above slide, below slide+512MB for a typical game binary)
    return (a > (uintptr_t)slide) && (a < (uintptr_t)slide + 0x20000000ULL);
}

static void* resolve(const char* name) {
    void* addr = dlsym(RTLD_DEFAULT, name);
    if (!addr) { printf("[JWMod] NOT FOUND: %s\n", name); return nullptr; }
    if (!is_game_symbol(addr)) { printf("[JWMod] SKIP (not game binary): %s\n", name); return nullptr; }
    return addr;
}

template<typename T>
static bool install_hook(const char* symName, T* origOut, void* hookFn) {
    void* addr = resolve(symName);
    if (!addr) return false;
    *origOut = (T)addr;
    patch_branch(addr, hookFn);
    printf("[JWMod] OK: %s\n", symName);
    return true;
}

// ===================================================================
//  BYPASS 1: SYSCTL — safe interpose approach
//  We use DYLD_INTERPOSE which replaces the symbol at the dyld level
//  before any code runs, rather than patching the shared cache inline.
//  This is the correct way to hook system calls.
// ===================================================================
#if MOD_BYPASS_SYSCTL

// Store real sysctl pointer obtained at constructor time
static int (*real_sysctl)(int*, unsigned int, void*, size_t*, void*, size_t) = nullptr;

static int my_sysctl(int* name, unsigned int namelen, void* oldp,
                     size_t* oldlenp, void* newp, size_t newlen) {
    int ret = real_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
    if (ret == 0 && namelen >= 4 &&
        name[0] == CTL_KERN && name[1] == KERN_PROC &&
        name[2] == KERN_PROC_PID && oldp != nullptr) {
        struct kinfo_proc* proc = (struct kinfo_proc*)oldp;
        proc->kp_proc.p_flag &= ~P_TRACED; // clear debugger-detected flag
    }
    return ret;
}

// DYLD_INTERPOSE macro — patches the GOT entry in the game binary,
// NOT the shared cache implementation. Safe and correct.
#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { \
        const void* replacement; \
        const void* replacee; \
    } _interpose_##_replacee \
    __attribute__((section("__DATA,__interpose"))) = { \
        (const void*)_replacement, (const void*)_replacee \
    }

DYLD_INTERPOSE(my_sysctl, sysctl)

#endif // MOD_BYPASS_SYSCTL

// ===================================================================
//  BYPASS 2: LAUNCH CHECK SEQUENCE
//  Hook the game-internal security check pipeline functions.
//  These are in the game binary so our inline patcher is safe.
// ===================================================================

// buildLaunchCheckSequence() — queues all the checks to run.
// We no-op this so zero checks are ever queued.
typedef void (*fn_buildLaunchChecks)(void* self);
static fn_buildLaunchChecks orig_buildLaunchChecks = nullptr;
void hook_buildLaunchChecks(void* self) {
    printf("[JWMod] buildLaunchCheckSequence — blocked\n");
    // Don't call original — no checks queued
}

// doLaunchCheck(LAUNCH_CHECK type, std::function<void()> callback)
// Called for each queued check. Since we blocked buildLaunchChecks
// above, this should never be called. But if it is, call original
// safely rather than trying to invoke the callback via vtable tricks.
typedef void (*fn_doLaunchCheck)(void* self, int checkType, void* callback);
static fn_doLaunchCheck orig_doLaunchCheck = nullptr;
void hook_doLaunchCheck(void* self, int checkType, void* callback) {
    printf("[JWMod] doLaunchCheck type=%d — skipped\n", checkType);
    // Do NOT call original, do NOT try to invoke std::function via vtable.
    // Just return — the check is silently skipped.
}

// checkLaunchCheckInSequence(unsigned int idx) — runs check at index.
// No-op.
typedef void (*fn_checkLaunchSeq)(void* self, unsigned int idx);
static fn_checkLaunchSeq orig_checkLaunchSeq = nullptr;
void hook_checkLaunchSeq(void* self, unsigned int idx) {
    // Silent no-op
}

// setCheckFeatureFlag(LAUNCH_CHECK, bool) — enable/disable a check.
// Always force disabled.
typedef void (*fn_setCheckFlag)(void* self, int checkType, bool enabled);
static fn_setCheckFlag orig_setCheckFlag = nullptr;
void hook_setCheckFlag(void* self, int checkType, bool enabled) {
    if (orig_setCheckFlag) orig_setCheckFlag(self, checkType, false);
}

// validateSaveParkCtxData() — integrity check on save data. No-op.
typedef void (*fn_validateSave)(void* self);
static fn_validateSave orig_validateSave = nullptr;
void hook_validateSave(void* self) { /* silent no-op */ }

// ===================================================================
//  LOGIN STATE
// ===================================================================
static bool g_loginComplete  = false;
static bool g_isGuestAccount = false;

typedef void (*fn_onLoginCompleted)(void* self, bool success);
static fn_onLoginCompleted orig_onLoginCompleted = nullptr;
void hook_onLoginCompleted(void* self, bool success) {
    if (orig_onLoginCompleted) orig_onLoginCompleted(self, success);
    g_loginComplete  = true;
    g_isGuestAccount = !success;
    printf("[JWMod] Login complete success=%d guest=%d\n", success, (int)g_isGuestAccount);
}

static inline bool vip_safe(void* self) {
    return (self != nullptr) && g_loginComplete && !g_isGuestAccount;
}

// ===================================================================
//  GAME FEATURE HOOKS
// ===================================================================

// -- Spend to Freeze --
typedef void (*fn_resourceRemove)(void* self, int type, unsigned int amount, ...);
static fn_resourceRemove orig_resourceRemove = nullptr;
void hook_resourceRemove(void* self, int type, unsigned int amount, ...) { }

typedef void (*fn_netRemove)(void* self, unsigned int crc, long long amount, ...);
static fn_netRemove orig_netRemove = nullptr;
void hook_netRemove(void* self, unsigned int crc, long long amount, ...) { }

typedef void (*fn_clampRemove)(void* self, unsigned int crc, long long amount);
static fn_clampRemove orig_clampRemove = nullptr;
void hook_clampRemove(void* self, unsigned int crc, long long amount) { }

typedef void (*fn_trackSpent)(void* self, int type, long long amount);
static fn_trackSpent orig_trackSpent = nullptr;
void hook_trackSpent(void* self, int type, long long amount) { }

// -- VIP --
typedef void (*fn_setSubscribed)(void* self, bool subscribed);
static fn_setSubscribed orig_setSubscribed = nullptr;
void hook_setSubscribed(void* self, bool subscribed) {
    if (!self) { if (orig_setSubscribed) orig_setSubscribed(self, subscribed); return; }
    if (orig_setSubscribed) orig_setSubscribed(self, vip_safe(self) ? true : subscribed);
}

typedef bool (*fn_isVipExclusive)(void* self);
static fn_isVipExclusive orig_isVipExclusive = nullptr;
bool hook_isVipExclusive(void* self) { return false; }

typedef void (*fn_memberRefresh)(void* self);
static fn_memberRefresh orig_memberRefresh = nullptr;
void hook_memberRefresh(void* self) {
    if (orig_memberRefresh) orig_memberRefresh(self);
    if (vip_safe(self) && orig_setSubscribed) orig_setSubscribed(self, true);
}

// -- Unlimited Packs --
typedef void (*fn_consumeFreeCompleted)(void* self, unsigned int idx);
static fn_consumeFreeCompleted orig_consumeFreeCompleted = nullptr;
void hook_consumeFreeCompleted(void* self, unsigned int idx) { }

typedef void (*fn_consumeFreeIncomplete)(void* self, unsigned int idx);
static fn_consumeFreeIncomplete orig_consumeFreeIncomplete = nullptr;
void hook_consumeFreeIncomplete(void* self, unsigned int idx) { }

// -- Evolution --
typedef void (*fn_tryEvolve)(void* self, unsigned int targetLevel, unsigned int dinoId);
static fn_tryEvolve orig_tryEvolve = nullptr;
void hook_tryEvolve(void* self, unsigned int targetLevel, unsigned int dinoId) {
    if (orig_tryEvolve) orig_tryEvolve(self, 40, dinoId);
}

// -- Feed Max Level --
typedef void (*fn_spendFoodLevel)(void* self, unsigned int level, void* dino1, void* dino2);
static fn_spendFoodLevel orig_spendFoodLevel = nullptr;
void hook_spendFoodLevel(void* self, unsigned int level, void* dino1, void* dino2) {
    if (orig_spendFoodLevel) orig_spendFoodLevel(self, 40, dino1, dino2);
}

// -- Free Speedup --
typedef float (*fn_getSpeedUpCost)(float remainingSec, float baseRate);
static fn_getSpeedUpCost orig_getSpeedUpCost = nullptr;
float hook_getSpeedUpCost(float remainingSec, float baseRate) { return 0.0f; }

typedef bool (*fn_payCost)(void* self, void* cost, void* reason, bool flag);
static fn_payCost orig_payCost = nullptr;
bool hook_payCost(void* self, void* cost, void* reason, bool flag) { return true; }

// -- Instant Hatch --
typedef void (*fn_hatchSpeedUp)(void* self, unsigned int sec);
static fn_hatchSpeedUp orig_hatchPodSpeedUp = nullptr;
void hook_hatchPodSpeedUp(void* self, unsigned int sec) {
    if (orig_hatchPodSpeedUp) orig_hatchPodSpeedUp(self, 0x7FFFFFFFu);
}

typedef void (*fn_mgrHatchSpeedUp)(void* self, unsigned int slot, unsigned int sec);
static fn_mgrHatchSpeedUp orig_mgrHatchSpeedUp = nullptr;
void hook_mgrHatchSpeedUp(void* self, unsigned int slot, unsigned int sec) {
    if (orig_mgrHatchSpeedUp) orig_mgrHatchSpeedUp(self, slot, 0x7FFFFFFFu);
}

// -- Instant Fusion --
typedef void (*fn_fusionSpeedUp)(void* self, unsigned int sec);
static fn_fusionSpeedUp orig_fusionSpeedUp = nullptr;
void hook_fusionSpeedUp(void* self, unsigned int sec) {
    if (orig_fusionSpeedUp) orig_fusionSpeedUp(self, 0x7FFFFFFFu);
}

// -- Instant Buildings --
typedef void (*fn_buildingSpeedUp)(void* self);
static fn_buildingSpeedUp orig_buildingSpeedUp = nullptr;
void hook_buildingSpeedUp(void* self) {
    if (orig_buildingSpeedUp) orig_buildingSpeedUp(self);
}

// -- Battle --
typedef unsigned int (*fn_calcDmg)(void* self, void* atk, void* def, unsigned int base);
static fn_calcDmg orig_calcDmg = nullptr;
unsigned int hook_calcDmg(void* self, void* atk, void* def, unsigned int base) {
    return 999999u;
}

typedef void (*fn_applyDmg)(void* self, int atkParty, int defParty, unsigned int dmg,
                             void* battleDmg, bool flag, int extra);
static fn_applyDmg orig_applyDmg = nullptr;
void hook_applyDmg(void* self, int atkParty, int defParty, unsigned int dmg,
                   void* battleDmg, bool flag, int extra) {
    if (atkParty == 1 && defParty == 0) dmg = 0;
    if (orig_applyDmg) orig_applyDmg(self, atkParty, defParty, dmg, battleDmg, flag, extra);
}

// ===================================================================
//  INIT
// ===================================================================
__attribute__((constructor))
static void jw_mod_init() {
    printf("[JWMod] ==============================\n");
    printf("[JWMod] Jurassic World Mod Loading\n");
    printf("[JWMod] ==============================\n");

    // Init the real sysctl pointer for our interpose wrapper
#if MOD_BYPASS_SYSCTL
    real_sysctl = (decltype(real_sysctl))dlsym(RTLD_NEXT, "sysctl");
    printf("[JWMod] sysctl interpose ready\n");
#endif

    // Launch check bypasses (game binary — safe to inline patch)
#if MOD_BYPASS_LAUNCH_CHECKS
    install_hook(
        "_ZN13JurassicWorld11ctxMainGame24buildLaunchCheckSequenceEv",
        &orig_buildLaunchChecks, (void*)hook_buildLaunchChecks);
    install_hook(
        "_ZN13JurassicWorld11ctxMainGame13doLaunchCheckERKNS0_12LAUNCH_CHECKENSt3__18functionIFvvEEE",
        &orig_doLaunchCheck, (void*)hook_doLaunchCheck);
    install_hook(
        "_ZN13JurassicWorld11ctxMainGame26checkLaunchCheckInSequenceEj",
        &orig_checkLaunchSeq, (void*)hook_checkLaunchSeq);
    install_hook(
        "_ZN13JurassicWorld11ctxMainGame19setCheckFeatureFlagENS0_12LAUNCH_CHECKEb",
        &orig_setCheckFlag, (void*)hook_setCheckFlag);
    install_hook(
        "_ZN13JurassicWorld11ctxMainGame23validateSaveParkCtxDataEv",
        &orig_validateSave, (void*)hook_validateSave);
#endif

    // Login tracker
    install_hook(
        "_ZN13JurassicWorld18managerLoadingCore16onLoginCompletedEb",
        &orig_onLoginCompleted, (void*)hook_onLoginCompleted);

    // Game hooks
#if MOD_SPEND_FREEZE
    install_hook(
        "_ZN13JurassicWorld15managerResource6removeENS_12ResourceType13RESOURCE_TYPEEjNS_13JWTransaction16TRANSACTION_TYPEENS3_20TRANSACTION_CATEGORYENS3_19TRANSACTION_TRIGGERERKNSt3__112basic_stringIcNS7_11char_traitsIcEENS7_9allocatorIcEEEEjSD_N13FreemiumWorld18FW_TRACKING_ACTIONE",
        &orig_resourceRemove, (void*)hook_resourceRemove);
    install_hook(
        "_ZN13JurassicWorld22managerNetworkResource14RemoveResourceEjxRKNSt3__112basic_stringIcNS1_11char_traitsIcEENS1_9allocatorIcEEEE",
        &orig_netRemove, (void*)hook_netRemove);
    install_hook(
        "_ZN13JurassicWorld22managerNetworkResource19ClampRemoveResourceEjx",
        &orig_clampRemove, (void*)hook_clampRemove);
    install_hook(
        "_ZN13JurassicWorld11sessionData19trackSpentResourcesENS_12ResourceType13RESOURCE_TYPEEx",
        &orig_trackSpent, (void*)hook_trackSpent);
#endif

#if MOD_ENABLE_VIP
    install_hook(
        "_ZN13JurassicWorld17managerMembership15setIsSubscribedEb",
        &orig_setSubscribed, (void*)hook_setSubscribed);
    install_hook(
        "_ZNK13JurassicWorld21ProcessActivationRule14isVipExclusiveEv",
        &orig_isVipExclusive, (void*)hook_isVipExclusive);
    install_hook(
        "_ZN13JurassicWorld17managerMembership17onRefreshFinishedEv",
        &orig_memberRefresh, (void*)hook_memberRefresh);
#endif

#if MOD_FREE_PACKS
    install_hook(
        "_ZN13JurassicWorld13managerMarket24consumeFreeCompletedItemEj",
        &orig_consumeFreeCompleted, (void*)hook_consumeFreeCompleted);
    install_hook(
        "_ZN13JurassicWorld13managerMarket25consumeFreeIncompleteItemEj",
        &orig_consumeFreeIncomplete, (void*)hook_consumeFreeIncomplete);
#endif

#if MOD_EVOLUTION_SUCCESS
    install_hook(
        "_ZN13JurassicWorld19FusionHubFusionView21trySpendFoodAndEvolveEjj",
        &orig_tryEvolve, (void*)hook_tryEvolve);
#endif

#if MOD_FEED_MAX_LEVEL
    install_hook(
        "_ZN13JurassicWorld19FusionHubFusionView23spendFoodToSetDinoLevelEj14AGIntrusivePtrINS_8DinoInfoEES3_",
        &orig_spendFoodLevel, (void*)hook_spendFoodLevel);
#endif

#if MOD_FREE_SPEEDUP
    install_hook("_ZN13JurassicWorld14getSpeedUpCostEff",
        &orig_getSpeedUpCost, (void*)hook_getSpeedUpCost);
    install_hook(
        "_ZN13JurassicWorld13HatcheryUtils7payCostERKNS_21ProcessActivationRule4CostERKNSt3__112basic_stringIcNS5_11char_traitsIcEENS5_9allocatorIcEEEEb",
        &orig_payCost, (void*)hook_payCost);
#endif

#if MOD_INSTANT_HATCH
    install_hook("_ZN13JurassicWorld8HatchPod7speedUpEj",
        &orig_hatchPodSpeedUp, (void*)hook_hatchPodSpeedUp);
    install_hook("_ZN13JurassicWorld15managerHatchery12speedUpHatchEjj",
        &orig_mgrHatchSpeedUp, (void*)hook_mgrHatchSpeedUp);
#endif

#if MOD_INSTANT_FUSION
    install_hook("_ZN13JurassicWorld16managerFusionLab7speedUpEj",
        &orig_fusionSpeedUp, (void*)hook_fusionSpeedUp);
#endif

#if MOD_INSTANT_BUILDINGS
    install_hook("_ZN13JurassicWorld22objectTimeConstruction7speedUpEv",
        &orig_buildingSpeedUp, (void*)hook_buildingSpeedUp);
#endif

#if MOD_BATTLE_ONE_HIT
    install_hook(
        "_ZN13JurassicWorld10BattleMode15calculateDamageE14AGIntrusivePtrINS_21BattleDinoStatWrapperEES3_j",
        &orig_calcDmg, (void*)hook_calcDmg);
#endif

#if MOD_BATTLE_NO_DAMAGE
    install_hook(
        "_ZN13JurassicWorld10BattleMode11applyDamageENS_6Battle12BATTLE_PARTYES2_j14AGIntrusivePtrINS_12BattleDamageEEbi",
        &orig_applyDmg, (void*)hook_applyDmg);
#endif

    printf("[JWMod] All hooks installed\n");
    printf("[JWMod] ==============================\n");
}
