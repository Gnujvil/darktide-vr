#pragma once

#include <cstdint>
#include <optional>

namespace darktidevr::core {

struct PixelExtent {
  std::uint32_t width{};
  std::uint32_t height{};

  friend bool operator==(PixelExtent, PixelExtent) = default;
};

enum class MirrorMode {
  disabled,
  left_eye,
  right_eye,
  side_by_side,
};

struct OutputLayoutRequest {
  PixelExtent runtime_recommended_eye{};
  std::optional<PixelExtent> eye_override;
  // The most pixels per eye the runtime's recommendation may keep. The
  // launcher sizes it to the graphics card: SteamVR asks a Quest 3 for
  // 2528x2704, which a 12 GB card cannot hold alongside the game. The aspect
  // is kept; an explicit override is never capped.
  std::optional<std::uint64_t> eye_pixel_cap;
  MirrorMode mirror_mode{MirrorMode::left_eye};
  PixelExtent mirror_extent{1280, 720};
};

struct OutputLayout {
  PixelExtent eye_extent{};
  MirrorMode mirror_mode{MirrorMode::disabled};
  PixelExtent mirror_extent{};
  std::uint32_t eye_surface_count{2};
};

// Defines the production bridge contract: two independent, full-resolution eye
// surfaces are authoritative. The desktop mirror is a separate consumer and
// may be smaller or disabled without changing headset resolution.
OutputLayout choose_output_layout(const OutputLayoutRequest& request);

}  // namespace darktidevr::core
