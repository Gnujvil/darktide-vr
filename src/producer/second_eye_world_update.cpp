#include "producer/second_eye_world_update.h"
#include "producer/guarded_copy.h"
#include <MinHook.h>
#include <array>
#include <atomic>
#include <cstring>

// Stereo renders one world twice a frame, and each Lua
// Application.render_world first calls RenderInterface::update_world in its
// "update if changed" mode (2). When anything changed the world between the
// two eyes (marker reprojection, for one), that update reaches the render
// thread between the eyes and ticks RenderParticleWorld::update, which frees
// every finished particle effect. The same tick re-arms the particle
// simulation only for a new frame number, so the second eye skips
// RenderParticleWorld::simulate and renders from the first eye's visibility
// lists: the TLAS update kernel and the particle render jobs then read the
// freed particle systems. Every stereo crash dump of 20 October (1.13.3)
// faults that way, and none occurs with a single submission per frame.
//
// Mode 1 applies the same world changes but leaves the particle world alone,
// so finished effects are freed by the next frame's forced update, which also
// re-arms the simulation for that frame's first eye.
namespace darktidevr::producer {
namespace second_eye_world_update {
using UpdateWorld = void (*)(void*, void*, float, float, int);
UpdateWorld original{};
std::atomic<bool> available{};
std::atomic<DWORD> armed_thread{};
std::atomic<int> armed_action{};
std::array<std::atomic<std::uint64_t>, 4> counts{};

void count(SecondEyeWorldUpdateCount kind) {
  counts[static_cast<std::size_t>(kind)].fetch_add(1, std::memory_order_relaxed);
}

// RenderInterface keeps its worlds at +0x170 (count at +0x168), 32 bytes
// each: the world, its render world and its state, whose +0x10 holds the
// change payload the main thread is filling. update_world swaps that payload
// exactly when it sends the world to the render thread.
void* pending_payload_slot(void* render_interface, void* world) {
  std::uint64_t worlds{};
  std::uint32_t world_count{};
  if (!safe_copy_bytes(&worlds, static_cast<std::byte*>(render_interface) + 0x170, sizeof(worlds)) ||
      !safe_copy_bytes(&world_count, static_cast<std::byte*>(render_interface) + 0x168, sizeof(world_count)) ||
      world_count > 4096)
    return nullptr;
  for (std::uint32_t i = 0; i < world_count; ++i) {
    std::array<std::uint64_t, 3> entry{};
    if (!safe_copy_bytes(entry.data(), reinterpret_cast<const void*>(worlds + i * 32ULL), sizeof(entry)))
      return nullptr;
    if (entry[0] == reinterpret_cast<std::uint64_t>(world))
      return entry[2] ? reinterpret_cast<std::byte*>(entry[2]) + 0x10 : nullptr;
  }
  return nullptr;
}

std::uint64_t read_payload(void* slot) {
  std::uint64_t payload{};
  return slot && safe_copy_bytes(&payload, slot, sizeof(payload)) ? payload : 0;
}

void update_world_hook(void* render_interface, void* world, float time, float delta, int mode) {
  if (mode != 2 || armed_thread.load(std::memory_order_relaxed) != GetCurrentThreadId()) {
    original(render_interface, world, time, delta, mode);
    return;
  }
  armed_thread.store(0, std::memory_order_relaxed);
  const auto action = static_cast<SecondEyeWorldUpdate>(armed_action.load(std::memory_order_relaxed));
  if (action == SecondEyeWorldUpdate::keep_particles) {
    mode = 1;
    count(SecondEyeWorldUpdateCount::kept_off_particles);
  }
  auto* slot = pending_payload_slot(render_interface, world);
  const auto before = read_payload(slot);
  original(render_interface, world, time, delta, mode);
  if (slot) {
    count(read_payload(slot) != before ? SecondEyeWorldUpdateCount::sent_changes
                                       : SecondEyeWorldUpdateCount::unchanged);
  }
}

// The game's weekly hotfixes move code, so both pieces are found by content
// and each must match exactly once. None of the matched bytes holds a
// relocated operand.
template <std::size_t N>
unsigned char* find_unique(const std::array<unsigned char, N>& signature) {
  auto* image = reinterpret_cast<unsigned char*>(GetModuleHandleW(nullptr));
  const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(image);
  const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS*>(image + dos->e_lfanew);
  const auto* section = IMAGE_FIRST_SECTION(nt);
  unsigned char* match{};
  int matches{};
  for (WORD i = 0; i < nt->FileHeader.NumberOfSections; ++i, ++section) {
    if (std::memcmp(section->Name, ".text", 6) != 0) continue;
    auto* begin = image + section->VirtualAddress;
    auto* end = begin + section->Misc.VirtualSize;
    for (auto* at = begin; at + N <= end; ++at) {
      if (*at == signature[0] && std::memcmp(at, signature.data(), N) == 0) {
        match = at;
        ++matches;
      }
    }
  }
  return matches == 1 ? match : nullptr;
}

template <std::size_t N>
bool matches_at(const unsigned char* base, std::size_t offset, const std::array<unsigned char, N>& bytes) {
  return std::memcmp(base + offset, bytes.data(), N) == 0;
}
}

bool install_second_eye_world_update_guard() {
  using namespace second_eye_world_update;
  // RenderInterface::update_world (1.13.3 RVA 0x2e1350). The prologue spills
  // both time arguments and records whether the mode argument at [rsp+0x80]
  // is 0 (forced); the later pieces are the world lookup the hook repeats,
  // the payload read and the mode 2 branch that sends a changed world.
  constexpr std::array<unsigned char, 53> kPrologue{
      0x48, 0x8b, 0xc4, 0x48, 0x89, 0x58, 0x08, 0x48, 0x89, 0x68, 0x10, 0x48,
      0x89, 0x70, 0x18, 0x57, 0x48, 0x83, 0xec, 0x50, 0x33, 0xf6, 0xf3, 0x0f,
      0x11, 0x50, 0xe0, 0x39, 0xb4, 0x24, 0x80, 0x00, 0x00, 0x00, 0x48, 0x8b,
      0xda, 0xf3, 0x0f, 0x11, 0x58, 0xe4, 0x48, 0x8b, 0xf9, 0x0f, 0x94, 0x40,
      0xe9, 0x48, 0x89, 0x70, 0xd0};
  constexpr std::array<unsigned char, 17> kWorldList{
      0x48, 0x8b, 0x8f, 0x70, 0x01, 0x00, 0x00, 0x8b, 0x87, 0x68, 0x01, 0x00,
      0x00, 0x48, 0xc1, 0xe0, 0x05};
  constexpr std::array<unsigned char, 3> kWorldKey{0x48, 0x39, 0x19};
  constexpr std::array<unsigned char, 4> kWorldState{0x48, 0x8b, 0x41, 0x10};
  constexpr std::array<unsigned char, 9> kPayload{
      0x48, 0x8b, 0x74, 0x24, 0x20, 0x48, 0x8b, 0x5e, 0x10};
  constexpr std::array<unsigned char, 19> kModeBranch{
      0x83, 0xbc, 0x24, 0x80, 0x00, 0x00, 0x00, 0x02, 0x75, 0x0b, 0x84, 0xc0,
      0x74, 0x07, 0xc6, 0x44, 0x24, 0x41, 0x01};
  // The render-thread side (1.13.3 RVA 0x2e18e9): the particle world at
  // RenderWorld+0x2088 is updated only when the sent world carries the
  // byte that modes 0 and 2 set and mode 1 leaves clear.
  constexpr std::array<unsigned char, 17> kParticleGate{
      0x48, 0x8b, 0x8f, 0x88, 0x20, 0x00, 0x00, 0x48, 0x85, 0xc9, 0x74, 0x42,
      0x45, 0x84, 0xf6, 0x74, 0x3d};
  auto* target = find_unique(kPrologue);
  if (!target || !matches_at(target, 0x66, kWorldList) || !matches_at(target, 0x80, kWorldKey) ||
      !matches_at(target, 0x99, kWorldState) || !matches_at(target, 0xcc, kPayload) ||
      !matches_at(target, 0x12b, kModeBranch) || !find_unique(kParticleGate))
    return true;
  if (MH_CreateHook(target, &update_world_hook, reinterpret_cast<void**>(&original)) != MH_OK)
    return false;
  available.store(true, std::memory_order_release);
  return true;
}

bool arm_second_eye_world_update(SecondEyeWorldUpdate action) {
  using namespace second_eye_world_update;
  if (!available.load(std::memory_order_acquire)) return false;
  if (action == SecondEyeWorldUpdate::off) {
    if (armed_thread.exchange(0, std::memory_order_relaxed) != 0)
      count(SecondEyeWorldUpdateCount::unconsumed);
    return true;
  }
  armed_action.store(static_cast<int>(action), std::memory_order_relaxed);
  armed_thread.store(GetCurrentThreadId(), std::memory_order_relaxed);
  return true;
}

std::uint64_t second_eye_world_update_count(SecondEyeWorldUpdateCount kind) {
  const auto index = static_cast<std::size_t>(kind);
  return index < second_eye_world_update::counts.size()
      ? second_eye_world_update::counts[index].load(std::memory_order_relaxed) : 0;
}
}
