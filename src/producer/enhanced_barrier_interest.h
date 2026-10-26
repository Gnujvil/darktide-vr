#pragma once
#include <d3d12.h>

namespace darktidevr::producer {
// The protected bookkeeping logs textures, records PRESENT targets and
// matches eye finals leaving RENDER_TARGET. PRESENT aliases COMMON, so
// COMMON must conservatively take this path too.
inline bool enhanced_barriers_need_capture_lock(
    UINT32 count, const D3D12_BARRIER_GROUP* groups, bool log_resources) noexcept {
  if (!groups) return false;
  for (UINT32 group_index = 0; group_index < count; ++group_index) {
    const auto& group = groups[group_index];
    if (group.Type != D3D12_BARRIER_TYPE_TEXTURE || !group.pTextureBarriers)
      continue;
    for (UINT32 index = 0; index < group.NumBarriers; ++index) {
      const auto& barrier = group.pTextureBarriers[index];
      if (log_resources || barrier.LayoutAfter == D3D12_BARRIER_LAYOUT_PRESENT ||
          barrier.LayoutBefore == D3D12_BARRIER_LAYOUT_RENDER_TARGET)
        return true;
    }
  }
  return false;
}
}
