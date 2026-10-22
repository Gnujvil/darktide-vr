#include "producer/buffer_copy_address.h"
#include <array>
#include <cstddef>
#include <cstdint>
#include <iostream>
#include <limits>

using darktidevr::producer::upload_flush_contains;
int main() {
  constexpr auto max = (std::numeric_limits<std::uint64_t>::max)();
  static_assert(upload_flush_contains(100, 184, 100, 84));
  static_assert(!upload_flush_contains(100, 184, 99, 84));
  static_assert(!upload_flush_contains(100, 184, 101, 84));
  static_assert(!upload_flush_contains(184, 100, 100, 84));
  static_assert(!upload_flush_contains(100, 184, max - 40, 84));
  static_assert(!upload_flush_contains(100, 184, 100, max));
  static_assert(!upload_flush_contains(184, 184, 184, 4));
  static_assert(upload_flush_contains(max - 84, max, max - 84, 84));
  // A retained pending patch below the current ring interval used to pass
  // the upper-bound-only check and overwrite an older allocation.
  std::array<std::byte, 256> staging{};
  for (std::uint64_t offset : {0ULL, 64ULL, 128ULL, 200ULL}) {
    if (upload_flush_contains(128, 212, offset, 84))
      staging[static_cast<std::size_t>(offset + 72)] = std::byte{1};
  }
  for (std::size_t i = 0; i < staging.size(); ++i)
    if (staging[i] != (i == 200 ? std::byte{1} : std::byte{0})) return 1;
  std::cout << "PASS upload flush lower/upper bounds, stale ring offsets and overflow\n";
}
