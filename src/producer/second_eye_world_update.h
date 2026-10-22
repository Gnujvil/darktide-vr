#pragma once
#include <Windows.h>
#include <cstdint>

namespace darktidevr::producer {
enum class SecondEyeWorldUpdate : int { off = 0, keep_particles = 1, observe = 2 };
enum class SecondEyeWorldUpdateCount : int {
  kept_off_particles = 0,  // updates demoted to leave the particle world alone
  unconsumed = 1,          // arms the bracketed render never reached
  sent_changes = 2,        // armed updates that handed the render thread a world change
  unchanged = 3            // armed updates with nothing to send
};

// Creates the RenderInterface::update_world hook; MH_EnableHook(MH_ALL_HOOKS)
// enables it with the others. An unrecognised game build leaves the guard
// unavailable and still returns true: only a MinHook failure is an error.
bool install_second_eye_world_update_guard();
// Arms the next "update if changed" world update on the calling thread, or
// disarms with off. Returns whether the guard is available.
bool arm_second_eye_world_update(SecondEyeWorldUpdate action);
std::uint64_t second_eye_world_update_count(SecondEyeWorldUpdateCount kind);
}
