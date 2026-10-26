#include "core/output_layout.h"

#include <algorithm>
#include <cmath>
#include <stdexcept>

namespace darktidevr::core {
namespace {

void require_valid(PixelExtent extent, const char* label) {
  if (extent.width == 0 || extent.height == 0) {
    throw std::invalid_argument(std::string(label) +
                                " dimensions must be non-zero");
  }
}

// Both sides scaled alike and rounded down to a multiple of 8, so the
// product stays within the cap and the aspect within a few pixels.
PixelExtent capped(PixelExtent extent, std::optional<std::uint64_t> cap) {
  const auto area = std::uint64_t{extent.width} * extent.height;
  if (!cap || *cap == 0 || area <= *cap) {
    return extent;
  }
  const auto scale =
      std::sqrt(static_cast<double>(*cap) / static_cast<double>(area));
  const auto shrink = [scale](std::uint32_t value) {
    const auto scaled =
        static_cast<std::uint32_t>(std::floor(static_cast<double>(value) * scale));
    return std::max<std::uint32_t>(8, scaled / 8 * 8);
  };
  return {shrink(extent.width), shrink(extent.height)};
}

}  // namespace

OutputLayout choose_output_layout(const OutputLayoutRequest& request) {
  require_valid(request.runtime_recommended_eye, "runtime eye");
  const auto eye_extent = request.eye_override.value_or(
      capped(request.runtime_recommended_eye, request.eye_pixel_cap));
  require_valid(eye_extent, "eye override");

  PixelExtent mirror_extent{};
  if (request.mirror_mode != MirrorMode::disabled) {
    require_valid(request.mirror_extent, "mirror");
    mirror_extent = request.mirror_extent;
  }

  return {
      eye_extent,
      request.mirror_mode,
      mirror_extent,
      2,
  };
}

}  // namespace darktidevr::core
