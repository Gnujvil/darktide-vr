#include "../isolated_transports.h"
#include "bridge/shared_eye_surfaces.h"
#include "core/shared_head_pose.h"
#include "core/shared_object_name.h"
#include <Windows.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <wrl/client.h>
#include <array>
#include <cmath>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string_view>

using Microsoft::WRL::ComPtr;
namespace {
void require(bool value, const char* message) {
  if (!value) throw std::runtime_error(message);
}
void check(HRESULT result, const char* message) { require(SUCCEEDED(result), message); }
void finish(ID3D12CommandQueue* queue, ID3D12Fence* fence, UINT64 value) {
  check(queue->Signal(fence, value), "Queue signal failed");
  const auto event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  require(event != nullptr, "Fence event failed");
  const auto registered = fence->SetEventOnCompletion(value, event);
  const auto waited = SUCCEEDED(registered) ? WaitForSingleObject(event, 5000) : WAIT_FAILED;
  CloseHandle(event);
  require(waited == WAIT_OBJECT_0, "GPU fixture did not finish");
}
}

int wmain(int argc, wchar_t** argv) {
  try {
    const bool xr_smoke = argc == 3 && std::wstring_view(argv[2]) == L"--xr-menu-smoke";
    require(argc == 2 || xr_smoke, "Expected native DLL path [--xr-menu-smoke]");
    if (xr_smoke) {
      // This explicit live check uses the production viewer's transport names.
      // Never attach it to a user's running game or XR viewer.
      const auto existing = OpenFileMappingW(FILE_MAP_READ, FALSE,
          darktidevr::core::kSharedHeadPoseName);
      if (existing) CloseHandle(existing);
      require(!existing, "Stop the existing game/viewer before the live fixture");
    } else {
      darktidevr::tests::isolate_transports();
    }
    const auto module = LoadLibraryW(argv[1]);
    require(module != nullptr, "Native DLL did not load");
    const auto commit = reinterpret_cast<int (*)(unsigned long long)>(
        GetProcAddress(module, "dtvr_commit_gameplay_generation"));
    const auto reset = reinterpret_cast<int (*)()>(
        GetProcAddress(module, "dtvr_reset_eye_capture_tags"));
    const auto install = reinterpret_cast<int (*)(ID3D12Device*)>(
        GetProcAddress(module, "dtvr_install_for_device"));
    const auto prepare_exit = reinterpret_cast<int (*)()>(
        GetProcAddress(module, "dtvr_prepare_process_exit"));
    const auto viewer = reinterpret_cast<int (*)(int)>(
        GetProcAddress(module, "dtvr_viewer_control"));
    const auto present = reinterpret_cast<int (*)(unsigned int, unsigned long long,
        unsigned int, unsigned int, unsigned int, unsigned int, unsigned int,
        unsigned int, float, float)>(GetProcAddress(module, "dtvr_set_presentation_state"));
    require(commit && reset && install && present && prepare_exit && viewer, "Frame-delivery exports missing");
    auto writer = std::make_unique<darktidevr::core::SharedHeadPoseWriter>();
    require(commit(257) == 0 && writer->read_gameplay_generation() == 257,
        "Initial gameplay generation was not committed");
    writer.reset();
    writer = std::make_unique<darktidevr::core::SharedHeadPoseWriter>();
    require(writer->read_gameplay_generation() == 0, "New viewer retained old metadata");
    require(reset() == 0 && writer->read_gameplay_generation() == 257,
        "Viewer restart lost the producer's committed gameplay generation");
    if (xr_smoke) writer.reset();

    ComPtr<ID3D12Device> device;
    ComPtr<IDXGIFactory4> device_factory;
    ComPtr<IDXGIAdapter> adapter;
    check(CreateDXGIFactory1(IID_PPV_ARGS(&device_factory)), "Device factory failed");
    if (!xr_smoke) check(device_factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter)), "WARP adapter failed");
    check(D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_12_0, IID_PPV_ARGS(&device)), "Device failed");
    require(install(device.Get()) == 0, "Native hooks failed");
    D3D12_COMMAND_QUEUE_DESC queue_description{};
    ComPtr<ID3D12CommandQueue> queue;
    check(device->CreateCommandQueue(&queue_description, IID_PPV_ARGS(&queue)), "Queue failed");
    WNDCLASSW window_class{};
    window_class.lpfnWndProc = DefWindowProcW;
    window_class.hInstance = GetModuleHandleW(nullptr);
    window_class.lpszClassName = L"DarktideVRFrameDeliveryFixture";
    require(RegisterClassW(&window_class) != 0, "Window class failed");
    const auto window = CreateWindowExW(0, window_class.lpszClassName,
        xr_smoke ? L"Warhammer 40,000: Darktide" : L"DarktideVR frame delivery fixture",
        WS_OVERLAPPEDWINDOW | (xr_smoke ? WS_VISIBLE : 0),
        0, 0, 800, 600, nullptr, nullptr, window_class.hInstance, nullptr);
    require(window != nullptr, "Fixture window failed");
    ComPtr<IDXGIFactory4> factory;
    check(CreateDXGIFactory1(IID_PPV_ARGS(&factory)), "Factory failed");
    DXGI_SWAP_CHAIN_DESC1 description{};
    description.Width = 800; description.Height = 600;
    description.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    description.SampleDesc.Count = 1;
    description.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    description.BufferCount = 2;
    description.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    ComPtr<IDXGISwapChain1> initial;
    check(factory->CreateSwapChainForHwnd(queue.Get(), window, &description,
        nullptr, nullptr, &initial), "Swapchain failed");
    ComPtr<IDXGISwapChain3> swapchain;
    check(initial.As(&swapchain), "Swapchain3 failed");
    ComPtr<ID3D12CommandAllocator> allocator;
    ComPtr<ID3D12GraphicsCommandList> commands;
    check(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,
        IID_PPV_ARGS(&allocator)), "Allocator failed");
    check(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT,
        allocator.Get(), nullptr, IID_PPV_ARGS(&commands)), "Commands failed");
    check(commands->Close(), "Initial close failed");
    D3D12_DESCRIPTOR_HEAP_DESC heap_description{D3D12_DESCRIPTOR_HEAP_TYPE_RTV, 1,
        D3D12_DESCRIPTOR_HEAP_FLAG_NONE, 0};
    ComPtr<ID3D12DescriptorHeap> rtv;
    check(device->CreateDescriptorHeap(&heap_description, IID_PPV_ARGS(&rtv)), "RTV failed");
    ComPtr<ID3D12Fence> fence;
    check(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence)), "Fence failed");
    UINT64 completed{};
    const auto names = darktidevr::bridge::SharedTextureNames{
        darktidevr::core::shared_object_name(L"Local\\DarktideVR-menu-ui"),
        darktidevr::core::shared_object_name(L"Local\\DarktideVR-menu-ui-ready"),
        darktidevr::core::shared_object_name(L"Local\\DarktideVR-menu-ui-consumed")};
    const std::array<unsigned int, 3> modes{2, 5, 6};
    if (xr_smoke) require(viewer(1) == 0, "Live viewer did not start");
    for (unsigned iteration = 0; iteration < (xr_smoke ? 900U : 3U); ++iteration) {
      const auto phase = xr_smoke ? (iteration / 300U) % 3U : iteration;
      const auto output_width = phase == 2 ? 600U : 800U;
      const auto output_height = phase == 2 ? 800U : 600U;
      require(present(modes[phase], iteration + 1, output_width, output_height,
          0, 0, output_width, output_height, 2.0F, 2.0F) == 0, "Presentation failed");
      ComPtr<ID3D12Resource> buffer;
      check(swapchain->GetBuffer(swapchain->GetCurrentBackBufferIndex(), IID_PPV_ARGS(&buffer)), "Buffer failed");
      check(allocator->Reset(), "Allocator reset failed");
      check(commands->Reset(allocator.Get(), nullptr), "Commands reset failed");
      device->CreateRenderTargetView(buffer.Get(), nullptr, rtv->GetCPUDescriptorHandleForHeapStart());
      D3D12_RESOURCE_BARRIER barrier{};
      barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
      barrier.Transition = {buffer.Get(), D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
          D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_RENDER_TARGET};
      commands->ResourceBarrier(1, &barrier);
      const float color[]{0.2F + 0.2F * phase, 0.4F, 0.6F, 1.0F};
      commands->ClearRenderTargetView(rtv->GetCPUDescriptorHandleForHeapStart(), color, 0, nullptr);
      std::swap(barrier.Transition.StateBefore, barrier.Transition.StateAfter);
      commands->ResourceBarrier(1, &barrier);
      check(commands->Close(), "Draw close failed");
      ID3D12CommandList* lists[]{commands.Get()};
      queue->ExecuteCommandLists(1, lists);
      check(swapchain->Present(0, 0), "Present failed");
      finish(queue.Get(), fence.Get(), ++completed);
      auto menu = darktidevr::bridge::open_shared_texture(device.Get(), names,
          {{output_width, output_height}, DXGI_FORMAT_R8G8B8A8_UNORM});
      const auto ready = menu.ready_fence->GetCompletedValue();
      require(ready != 0 && ready != UINT64_MAX, "Menu was not published");
      if (xr_smoke) {
        MSG message{};
        while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
          TranslateMessage(&message);
          DispatchMessageW(&message);
        }
        Sleep(11);
        continue; // The real viewer owns the consumption acknowledgement.
      }
      // Read actual pixels so an empty or stale mailbox cannot pass.
      auto texture_description = menu.texture->GetDesc();
      D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};
      UINT64 bytes{};
      device->GetCopyableFootprints(&texture_description, 0, 1, 0, &footprint, nullptr, nullptr, &bytes);
      D3D12_HEAP_PROPERTIES read_heap{}; read_heap.Type = D3D12_HEAP_TYPE_READBACK;
      D3D12_RESOURCE_DESC read_description{};
      read_description.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
      read_description.Width = bytes; read_description.Height = 1;
      read_description.DepthOrArraySize = 1; read_description.MipLevels = 1;
      read_description.SampleDesc.Count = 1; read_description.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
      ComPtr<ID3D12Resource> readback;
      check(device->CreateCommittedResource(&read_heap, D3D12_HEAP_FLAG_NONE,
          &read_description, D3D12_RESOURCE_STATE_COPY_DEST, nullptr,
          IID_PPV_ARGS(&readback)), "Readback failed");
      check(allocator->Reset(), "Read allocator reset failed");
      check(commands->Reset(allocator.Get(), nullptr), "Read reset failed");
      barrier.Transition = {menu.texture.Get(), D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
          D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_COPY_SOURCE};
      commands->ResourceBarrier(1, &barrier);
      D3D12_TEXTURE_COPY_LOCATION from{}, to{};
      from.pResource = menu.texture.Get(); from.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
      to.pResource = readback.Get(); to.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
      to.PlacedFootprint = footprint;
      commands->CopyTextureRegion(&to, 0, 0, 0, &from, nullptr);
      std::swap(barrier.Transition.StateBefore, barrier.Transition.StateAfter);
      commands->ResourceBarrier(1, &barrier);
      check(commands->Close(), "Read close failed");
      queue->ExecuteCommandLists(1, lists);
      finish(queue.Get(), fence.Get(), ++completed);
      void* mapped{};
      check(readback->Map(0, nullptr, &mapped), "Map failed");
      const auto* pixel = static_cast<const unsigned char*>(mapped) + footprint.Offset +
          (output_height / 2) * footprint.Footprint.RowPitch + (output_width / 2) * 4;
      const bool pixels_match = std::abs(static_cast<int>(pixel[0]) - static_cast<int>(color[0] * 255)) <= 2 &&
          std::abs(static_cast<int>(pixel[1]) - 102) <= 2 && std::abs(static_cast<int>(pixel[2]) - 153) <= 2;
      readback->Unmap(0, nullptr);
      require(pixels_match, "Menu texture pixels were empty, stale or corrupted");
      check(menu.consumed_fence->Signal(ready), "Menu acknowledgement failed");
    }
    if (xr_smoke) require(viewer(0) == 0, "Live viewer did not stop cleanly");
    finish(queue.Get(), fence.Get(), ++completed);
    check(swapchain->ResizeBuffers(2, 800, 600, DXGI_FORMAT_R8G8B8A8_UNORM, 0),
        "Menu capture retained a DXGI buffer across resize");
    std::cout << "frame_delivery=pass restart_generation loading interactive aspect_change live_pixels"
              << std::endl;
    (void)prepare_exit();
    DestroyWindow(window);
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "frame_delivery=fail " << error.what() << '\n';
    return 1;
  }
}
