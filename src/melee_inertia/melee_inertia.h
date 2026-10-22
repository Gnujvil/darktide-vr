#pragma once

#ifdef DTVR_MELEE_BUILD
#define DTVR_MELEE_API extern "C" __declspec(dllexport)
#else
#define DTVR_MELEE_API extern "C" __declspec(dllimport)
#endif

// Arrays use body/tracking-local metres and xyzw quaternions. +Z is up;
// the weapon's shaft extends along its local +Z from the dominant grip.
// Output: pose[0..6], linear velocity[7..9], angular velocity[10..12],
// steel mass[13], position lag[14], angular lag[15], recovery[16],
// support engaged[17], reset reason[18], simulation timestamp[19].
// Return: 0 invalid/suspended, 1 stepped, 2 reset, 3 duplicate timestamp.
DTVR_MELEE_API int dtvr_melee_abi();
DTVR_MELEE_API void* dtvr_melee_create(int profile);
// Explicit tuning, independent of native action speed or collision geometry.
DTVR_MELEE_API void* dtvr_melee_create_config(int profile, double mass,
    double length, double head_fraction);
DTVR_MELEE_API void dtvr_melee_destroy(void* state);
DTVR_MELEE_API int dtvr_melee_step(void* state, const double* dominant7,
    const double* support7, double time, double recovery, int support_held,
    int tracking_valid, unsigned int reference_generation, double* output20);
// Retention 0 stalls virtual motion, 1 leaves it unchanged; controller poses
// remain unrestricted. Haptics and native combat events are owned by Lua.
DTVR_MELEE_API int dtvr_melee_contact(void* state, double retention);
DTVR_MELEE_API int dtvr_melee_support_pose(void* state, double* output7);
// Contact constraint only; no extra simulation integration or raw pose writes.
DTVR_MELEE_API int dtvr_melee_pin(void* state, const double* pose7, double* output20);
