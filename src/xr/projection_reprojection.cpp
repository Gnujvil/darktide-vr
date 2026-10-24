#include "projection_reprojection.h"
#include "core/xr_math.h"
#include <cmath>
#include <stdexcept>

namespace darktidevr::harness {
PanelQuad projection_image_quad(const XrPosef& pose, const XrFovf& fov,
                                XrExtent2Di extent) {
  const math::Fov angles{fov.angleLeft, fov.angleRight, fov.angleUp, fov.angleDown};
  if (!math::fov_usable(angles) || extent.width <= 0 || extent.height <= 0)
    throw std::invalid_argument("Invalid source projection for eye reprojection");
  const float left = std::tan(fov.angleLeft), right = std::tan(fov.angleRight);
  const float up = std::tan(fov.angleUp), down = std::tan(fov.angleDown);
  const math::Pose source{{pose.orientation.x, pose.orientation.y,
                           pose.orientation.z, pose.orientation.w},
                          {pose.position.x, pose.position.y, pose.position.z}};
  const auto centre = math::transform_point(source,
      {(left + right) * 0.5F, (up + down) * 0.5F, -1.0F});
  PanelQuad quad{};
  quad.pose = pose;
  quad.pose.position = {centre.x, centre.y, centre.z};
  quad.size = {right - left, up - down};
  quad.texels = {{0, 0}, extent};
  return quad;
}

ProjectionReprojector::ProjectionReprojector(ID3D12Device* device,
    DXGI_FORMAT format, D3D12_RESOURCE_DESC description)
    : extent_{static_cast<std::int32_t>(description.Width),
              static_cast<std::int32_t>(description.Height)} {
  auto swatch = description;
  swatch.Width = swatch.Height = 1;
  for (auto& renderer : renderers_)
    renderer = std::make_unique<PanelRenderer>(device, format, description, swatch);
}

void ProjectionReprojector::record(ID3D12GraphicsCommandList* commands,
    const std::array<ID3D12Resource*, 2>& images,
    const std::array<D3D12_CPU_DESCRIPTOR_HANDLE, 2>& targets,
    const std::array<XrPosef, 2>& source_poses,
    const std::array<XrFovf, 2>& source_fovs,
    const std::array<XrPosef, 2>& destination_poses,
    const std::array<XrFovf, 2>& destination_fovs,
    D3D12_RESOURCE_STATES before) {
  for (std::size_t eye = 0; eye < images.size(); ++eye) {
    D3D12_RESOURCE_BARRIER barrier{};
    barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Transition = {images[eye], D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
                          before, D3D12_RESOURCE_STATE_COPY_SOURCE};
    commands->ResourceBarrier(1, &barrier);
    commands->CopyResource(renderers_[eye]->board_texture(), images[eye]);
    barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_COPY_SOURCE;
    barrier.Transition.StateAfter = D3D12_RESOURCE_STATE_RENDER_TARGET;
    commands->ResourceBarrier(1, &barrier);
    renderers_[eye]->begin(commands);
    const auto quad = projection_image_quad(source_poses[eye], source_fovs[eye], extent_);
    renderers_[eye]->record(commands, targets[eye], {{0, 0}, extent_}, eye,
        destination_poses[eye], destination_fovs[eye], &quad, 1, true, true);
    renderers_[eye]->end(commands);
    barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_RENDER_TARGET;
    barrier.Transition.StateAfter = D3D12_RESOURCE_STATE_COMMON;
    commands->ResourceBarrier(1, &barrier);
  }
}
}
