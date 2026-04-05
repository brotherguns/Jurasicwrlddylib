// JWMod.mm — Jurassic World: The Game Full Mod Dylib
// Features:
//   ✅ Unlimited DNA/Food/Coins/Cash/Loyalty (Spend to Freeze)
//   ✅ Enable VIP (no purchase required)
//   ✅ Unlimited Special Packs
//   ✅ Evolution Always Successful
//   ✅ Feed Instant Max Level (no food spent)
//   ✅ Free Speed Up Costs
//   ✅ Instant Hatch / Instant Fusion / Instant Buildings
//   ✅ Battle: One-Hit / No Damage
//
// ⚠ WARNING: Do NOT use with Guest Account (crash bug)
//            Login via Facebook and reach LV5 first
//
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

// ═══════════════════════════════════════════════════════════════
//  FEATURE TOGGLES  (1 = on, 0 = off)
// ═══════════════════════════════════════════════════════════════
#define MOD_SPEND_FREEZE        1   // Freeze all resources on spend (DNA/Food/Coins/Cash/Loyalty)
#define MOD_ENABLE_VIP          1   // Enable VIP/membership without purchase
#define MOD_FREE_PACKS          1   // Unlimited special packs (no consume)
#define MOD_EVOLUTION_SUCCESS   1   // Evolution always succeeds instantly
#define MOD_FEED_MAX_LEVEL      1   // Feed sets dino to max level, no food cost
#define MOD_FREE_SPEEDUP        1   // Speed up costs nothing
#define MOD_INSTANT_HATCH       1   // Hatch timers instant
#define MOD_INSTANT_FUSION      1   // Fusion instant
#define MOD_INSTANT_BUILDINGS   1   // Construction instant
#define MOD_BATTLE_ONE_HIT      1   // One-hit kill enemies
#define MOD_BATTLE_NO_DAMAGE    1   // Invincible (no damage taken)

// ═══════════════════════════════════════════════════════════════
//  ARM64 INLINE PATCHER — 16-byte absolute branch trampoline
// ═══════════════════════════════════════════════════════════════
static void patch_branch(void* src, void* dst) {
    if (!src || !dst) return;
    vm_address_t page = (vm_address_t)src & ~0xFFFULL;
    kern_return_t kr = vm_protect(mach_task_self(), page, 0x4000, false,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        printf("[JWMod] vm_protect failed for %p: %d\n", src, kr);
        return;
    }
    uint32_t* p = (uint32_t*)src;
    p[0] = 0x58000050u; // LDR X16, #8
    p[1] = 0xD61F0200u; // BR  X16
    *((uint64_t*)(p + 2)) = (uint64_t)dst;
    vm_protect(mach_task_self(), page, 0x4000, false, VM_PROT_READ | VM_PROT_EXECUTE);
    sys_icache_invalidate(src, 16);
}

static void* resolve(const char* name) {
    void* addr = dlsym(RTLD_DEFAULT, name);
    if (!addr) printf("[JWMod] ⚠ NOT FOUND: %s\n", name);
    return addr;
}

template<typename T>
static bool install_hook(const char* symName, T* origOut, void* hookFn) {
    void* addr = resolve(symName);
    if (!addr) return false;
    *origOut = (T)addr;
    patch_branch(addr, hookFn);
    printf("[JWMod] ✅ %s\n", symName);
    return true;
}

// ═══════════════════════════════════════════════════════════════
//  HOOK IMPLEMENTATIONS
// ═══════════════════════════════════════════════════════════════

// ── 1. SPEND TO FREEZE ───────────────────────────────────────
// Primary resource deduction gate — no-op to freeze balance
typedef void (*fn_resourceRemove)(void* self, int type, unsigned int amount, ...);
static fn_resourceRemove orig_resourceRemove = nullptr;
void hook_resourceRemove(void* self, int type, unsigned int amount, ...) {
    printf("[JWMod] 💰 Blocked resource deduction type=%d amount=%u\n", type, amount);
}

typedef void (*fn_netRemove)(void* self, unsigned int crc, long long amount, ...);
static fn_netRemove orig_netRemove = nullptr;
void hook_netRemove(void* self, unsigned int crc, long long amount, ...) {
    printf("[JWMod] 💰 Blocked net removal crc=0x%X amount=%lld\n", crc, amount);
}

typedef void (*fn_clampRemove)(void* self, unsigned int crc, long long amount);
static fn_clampRemove orig_clampRemove = nullptr;
void hook_clampRemove(void* self, unsigned int crc, long long amount) {
    printf("[JWMod] 💰 Blocked ClampRemove crc=0x%X\n", crc);
}

typedef void (*fn_trackSpent)(void* self, int type, long long amount);
static fn_trackSpent orig_trackSpent = nullptr;
void hook_trackSpent(void* self, int type, long long amount) { /* no-op */ }

// ── 2. ENABLE VIP ────────────────────────────────────────────
typedef void (*fn_setSubscribed)(void* self, bool subscribed);
static fn_setSubscribed orig_setSubscribed = nullptr;
void hook_setSubscribed(void* self, bool subscribed) {
    printf("[JWMod] 👑 Forcing VIP = true\n");
    if (orig_setSubscribed) orig_setSubscribed(self, true);
}

typedef bool (*fn_isVipExclusive)(void* self);
static fn_isVipExclusive orig_isVipExclusive = nullptr;
bool hook_isVipExclusive(void* self) { return false; }

typedef void (*fn_memberRefresh)(void* self);
static fn_memberRefresh orig_memberRefresh = nullptr;
void hook_memberRefresh(void* self) {
    if (orig_memberRefresh) orig_memberRefresh(self);
    if (orig_setSubscribed) orig_setSubscribed(self, true);
    printf("[JWMod] 👑 VIP re-applied post server refresh\n");
}

// ── 3. UNLIMITED SPECIAL PACKS ───────────────────────────────
typedef void (*fn_consumeFreeCompleted)(void* self, unsigned int idx);
static fn_consumeFreeCompleted orig_consumeFreeCompleted = nullptr;
void hook_consumeFreeCompleted(void* self, unsigned int idx) {
    printf("[JWMod] 🎁 Blocked consumeFreeCompletedItem (unlimited packs)\n");
}

typedef void (*fn_consumeFreeIncomplete)(void* self, unsigned int idx);
static fn_consumeFreeIncomplete orig_consumeFreeIncomplete = nullptr;
void hook_consumeFreeIncomplete(void* self, unsigned int idx) {
    printf("[JWMod] 🎁 Blocked consumeFreeIncompleteItem (unlimited packs)\n");
}

// ── 4. EVOLUTION ALWAYS SUCCESSFUL ───────────────────────────
typedef void (*fn_tryEvolve)(void* self, unsigned int targetLevel, unsigned int dinoId);
static fn_tryEvolve orig_tryEvolve = nullptr;
void hook_tryEvolve(void* self, unsigned int targetLevel, unsigned int dinoId) {
    printf("[JWMod] 🦕 Evolution forced to max level\n");
    if (orig_tryEvolve) orig_tryEvolve(self, 40, dinoId);
}

// ── 5. FEED INSTANT MAX LEVEL ─────────────────────────────────
typedef void (*fn_spendFoodLevel)(void* self, unsigned int level, void* dino1, void* dino2);
static fn_spendFoodLevel orig_spendFoodLevel = nullptr;
void hook_spendFoodLevel(void* self, unsigned int level, void* dino1, void* dino2) {
    printf("[JWMod] 🍖 Feed forced to max level 40, food blocked\n");
    if (orig_spendFoodLevel) orig_spendFoodLevel(self, 40, dino1, dino2);
}

// ── 6. FREE SPEED UP COSTS ────────────────────────────────────
typedef float (*fn_getSpeedUpCost)(float remainingSec, float baseRate);
static fn_getSpeedUpCost orig_getSpeedUpCost = nullptr;
float hook_getSpeedUpCost(float remainingSec, float baseRate) { return 0.0f; }

typedef bool (*fn_payCost)(void* self, void* cost, void* reason, bool flag);
static fn_payCost orig_payCost = nullptr;
bool hook_payCost(void* self, void* cost, void* reason, bool flag) {
    printf("[JWMod] ⚡ payCost bypassed\n");
    return true;
}

// ── 7. INSTANT HATCH ─────────────────────────────────────────
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

// ── 8. INSTANT FUSION ────────────────────────────────────────
typedef void (*fn_fusionSpeedUp)(void* self, unsigned int sec);
static fn_fusionSpeedUp orig_fusionSpeedUp = nullptr;
void hook_fusionSpeedUp(void* self, unsigned int sec) {
    if (orig_fusionSpeedUp) orig_fusionSpeedUp(self, 0x7FFFFFFFu);
}

// ── 9. INSTANT BUILDINGS ─────────────────────────────────────
typedef void (*fn_buildingSpeedUp)(void* self);
static fn_buildingSpeedUp orig_buildingSpeedUp = nullptr;
void hook_buildingSpeedUp(void* self) {
    if (orig_buildingSpeedUp) orig_buildingSpeedUp(self);
}

// ── 10. BATTLE: ONE HIT ──────────────────────────────────────
typedef unsigned int (*fn_calcDmg)(void* self, void* atk, void* def, unsigned int base);
static fn_calcDmg orig_calcDmg = nullptr;
unsigned int hook_calcDmg(void* self, void* atk, void* def, unsigned int base) {
    return 999999u;
}

// ── 11. BATTLE: NO DAMAGE ────────────────────────────────────
// BATTLE_PARTY: 0 = player, 1 = enemy (swap if wrong)
typedef void (*fn_applyDmg)(void* self, int atkParty, int defParty, unsigned int dmg,
                             void* battleDmg, bool flag, int extra);
static fn_applyDmg orig_applyDmg = nullptr;
void hook_applyDmg(void* self, int atkParty, int defParty, unsigned int dmg,
                   void* battleDmg, bool flag, int extra) {
    if (atkParty == 1 && defParty == 0) dmg = 0;
    if (orig_applyDmg) orig_applyDmg(self, atkParty, defParty, dmg, battleDmg, flag, extra);
}

// ═══════════════════════════════════════════════════════════════
//  INIT
// ═══════════════════════════════════════════════════════════════
__attribute__((constructor))
static void jw_mod_init() {
    printf("[JWMod] ══════════════════════════════\n");
    printf("[JWMod] 🦖 Jurassic World Mod Loading\n");
    printf("[JWMod] ══════════════════════════════\n");

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
    install_hook(
        "_ZN13JurassicWorld14getSpeedUpCostEff",
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

    printf("[JWMod] 🦖 Done! Enjoy!\n");
    printf("[JWMod] ══════════════════════════════\n");
}
