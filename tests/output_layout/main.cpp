#include "core/output_layout.h"

#include <iostream>
#include <stdexcept>

namespace {

void expect(bool condition, const char* message) {
  if (!condition) {
    throw std::runtime_error(message);
  }
}

}  // namespace

int main() {
  try {
    using namespace darktidevr::core;

    const auto defaults = choose_output_layout({{2688, 2880}});
    expect(defaults.eye_extent == PixelExtent{2688, 2880},
           "Runtime recommendation must determine default eye resolution");
    expect(defaults.eye_surface_count == 2,
           "Stereo output must keep two independent eye surfaces");
    expect(defaults.mirror_mode == MirrorMode::left_eye &&
               defaults.mirror_extent == PixelExtent{1280, 720},
           "Default mirror must be a low-resolution left-eye copy");

    OutputLayoutRequest diagnostic{{2688, 2880}};
    diagnostic.eye_override = PixelExtent{1920, 2160};
    diagnostic.mirror_mode = MirrorMode::side_by_side;
    diagnostic.mirror_extent = {1920, 540};
    const auto overridden = choose_output_layout(diagnostic);
    expect(overridden.eye_extent == PixelExtent{1920, 2160},
           "Explicit eye resolution must be honored");
    expect(overridden.mirror_mode == MirrorMode::side_by_side &&
               overridden.mirror_extent == PixelExtent{1920, 540},
           "Diagnostic SBS mirror must not affect eye resolution");

    OutputLayoutRequest headless{{2688, 2880}};
    headless.mirror_mode = MirrorMode::disabled;
    headless.mirror_extent = {};
    const auto without_mirror = choose_output_layout(headless);
    expect(without_mirror.eye_extent == defaults.eye_extent &&
               without_mirror.mirror_extent == PixelExtent{},
           "Disabling the mirror must preserve headset resolution");

    // SteamVR's Quest 3 recommendation on a 12 GB card: scaled to the cap,
    // aspect kept, both sides a multiple of 8.
    OutputLayoutRequest steamvr{{2528, 2704}};
    steamvr.eye_pixel_cap = 2112ULL * 2304ULL;
    const auto capped = choose_output_layout(steamvr);
    expect(capped.eye_extent == PixelExtent{2128, 2280},
           "An eye pixel cap must scale the recommendation to fit");
    expect(std::uint64_t{capped.eye_extent.width} * capped.eye_extent.height <=
               *steamvr.eye_pixel_cap,
           "A capped extent must not exceed the cap");

    OutputLayoutRequest within{{2112, 2304}};
    within.eye_pixel_cap = 2112ULL * 2304ULL;
    expect(choose_output_layout(within).eye_extent == PixelExtent{2112, 2304},
           "A recommendation within the cap must be kept exactly");

    OutputLayoutRequest pinned{{2528, 2704}};
    pinned.eye_pixel_cap = 1000ULL * 1000ULL;
    pinned.eye_override = PixelExtent{2528, 2704};
    expect(choose_output_layout(pinned).eye_extent == PixelExtent{2528, 2704},
           "An explicit eye resolution must not be capped");

    bool rejected{};
    try {
      (void)choose_output_layout({{0, 2880}});
    } catch (const std::invalid_argument&) {
      rejected = true;
    }
    expect(rejected, "Zero-sized eye surfaces must be rejected");

    std::cout << "output_layout.result=pass\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "output_layout: " << error.what() << '\n';
    return 1;
  }
}
