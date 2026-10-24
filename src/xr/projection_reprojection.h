#pragma once
#include "panel_renderer.h"
#include <memory>

namespace darktidevr::harness {
// The plane encodes the rays of an existing eye image. With a shared optical
// origin, drawing it through another projection is an exact rotational warp,
// independent of scene depth; it introduces no artificial stereo separation.
PanelQuad projection_image_quad(const XrPosef& pose, const XrFovf& fov,
                                XrExtent2Di extent);

class ProjectionReprojector {
 public:
  ProjectionReprojector(ID3D12Device* device, DXGI_FORMAT format,
                        D3D12_RESOURCE_DESC description);
  // Inputs are the final opaque eye images, including any in-image overlays.
  // Copies and reprojects both eyes independently, then leaves them COMMON.
  void record(ID3D12GraphicsCommandList* commands,
              const std::array<ID3D12Resource*, 2>& images,
              const std::array<D3D12_CPU_DESCRIPTOR_HANDLE, 2>& targets,
              const std::array<XrPosef, 2>& source_poses,
              const std::array<XrFovf, 2>& source_fovs,
              const std::array<XrPosef, 2>& destination_poses,
              const std::array<XrFovf, 2>& destination_fovs,
              D3D12_RESOURCE_STATES before);
 private:
  XrExtent2Di extent_{};
  std::array<std::unique_ptr<PanelRenderer>, 2> renderers_;
};
}
