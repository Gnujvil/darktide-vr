#include "../isolated_transports.h"
#include <d3d12.h>
#include <d3d11on12.h>
#include <dxgi1_4.h>
#include <wrl/client.h>

#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <string>

void check_interop() {
  using Microsoft::WRL::ComPtr;
  // The system interop DLL imports internal D3D12/PIX exports from the app's
  // proxy. Missing any of them reproduces SteamVR's error 127 / InvalidTexture.
  const auto interop = LoadLibraryExW(L"d3d11on12.dll", nullptr,
                                     LOAD_LIBRARY_SEARCH_SYSTEM32);
  if (!interop) throw std::runtime_error("System D3D11On12 DLL failed to load");
  ComPtr<IDXGIFactory4> factory;
  ComPtr<IDXGIAdapter> warp;
  ComPtr<ID3D12Device> device;
  if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory))) ||
      FAILED(factory->EnumWarpAdapter(IID_PPV_ARGS(&warp))) ||
      FAILED(D3D12CreateDevice(warp.Get(), D3D_FEATURE_LEVEL_12_0,
                              IID_PPV_ARGS(&device))))
    throw std::runtime_error("WARP D3D12 device creation failed");
  D3D12_COMMAND_QUEUE_DESC queue_description{};
  queue_description.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
  ComPtr<ID3D12CommandQueue> queue;
  if (FAILED(device->CreateCommandQueue(&queue_description, IID_PPV_ARGS(&queue))))
    throw std::runtime_error("Interop command queue creation failed");
  IUnknown* queues[]{queue.Get()};
  ComPtr<ID3D11Device> eleven;
  ComPtr<ID3D11DeviceContext> context;
  if (FAILED(D3D11On12CreateDevice(device.Get(), D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                                  nullptr, 0, queues, 1, 0, &eleven, &context, nullptr)))
    throw std::runtime_error("D3D11On12CreateDevice failed through bootstrap");
  ComPtr<ID3D11On12Device> bridge;
  if (FAILED(eleven.As(&bridge))) throw std::runtime_error("D3D11On12 interface missing");
  D3D12_HEAP_PROPERTIES heap{};
  heap.Type = D3D12_HEAP_TYPE_DEFAULT;
  D3D12_RESOURCE_DESC description{};
  description.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
  description.Width = description.Height = 64;
  description.DepthOrArraySize = description.MipLevels = 1;
  description.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
  description.SampleDesc.Count = 1;
  description.Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
  ComPtr<ID3D12Resource> texture;
  if (FAILED(device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE,
        &description, D3D12_RESOURCE_STATE_RENDER_TARGET, nullptr, IID_PPV_ARGS(&texture))))
    throw std::runtime_error("Interop texture creation failed");
  D3D11_RESOURCE_FLAGS flags{};
  flags.BindFlags = D3D11_BIND_RENDER_TARGET;
  ComPtr<ID3D11Resource> wrapped;
  if (FAILED(bridge->CreateWrappedResource(texture.Get(), &flags,
        D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_COMMON, IID_PPV_ARGS(&wrapped))))
    throw std::runtime_error("Interop texture wrapping failed");
  ComPtr<ID3D11RenderTargetView> target;
  if (FAILED(eleven->CreateRenderTargetView(wrapped.Get(), nullptr, &target)))
    throw std::runtime_error("Interop render target creation failed");
  ID3D11Resource* resources[]{wrapped.Get()};
  bridge->AcquireWrappedResources(resources, 1);
  const float color[]{0.25F, 0.5F, 0.75F, 1.0F};
  context->ClearRenderTargetView(target.Get(), color);
  bridge->ReleaseWrappedResources(resources, 1);
  context->Flush();
  ComPtr<ID3D12Fence> fence;
  if (FAILED(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence))) ||
      FAILED(queue->Signal(fence.Get(), 1)))
    throw std::runtime_error("Interop completion signal failed");
  const auto completed = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  if (!completed) throw std::runtime_error("Interop completion event failed");
  const auto armed = fence->SetEventOnCompletion(1, completed);
  const auto waited = SUCCEEDED(armed) ? WaitForSingleObject(completed, 5000) : WAIT_FAILED;
  CloseHandle(completed);
  if (waited != WAIT_OBJECT_0 || FAILED(device->GetDeviceRemovedReason()))
    throw std::runtime_error("Interop GPU operation failed");
  target.Reset();
  wrapped.Reset();
  bridge.Reset();
  context.Reset();
  eleven.Reset();
  FreeLibrary(interop);
  std::cout << "bootstrap_d3d11on12=pass wrapped_texture=rendered adapter=WARP\n";
}

int wmain(int argc, wchar_t** argv) {
  try {
    if (argc != 6 && argc != 3) throw std::runtime_error("Expected fixture root and selections or --interop");
    darktidevr::tests::isolate_transports();
    const auto root = std::filesystem::path(argv[1]);
    if (!GetModuleHandleW((root / L"binaries/d3d12.dll").c_str())) {
      throw std::runtime_error("Test executable did not import the fixture bootstrap");
    }
    if (argc == 3 && std::wstring(argv[2]) == L"--interop") {
      check_interop();
      return 0;
    }
    if (argc != 6) throw std::runtime_error("Unknown bootstrap test mode");
    Microsoft::WRL::ComPtr<ID3D12Device> device;
    if (FAILED(D3D12CreateDevice(nullptr, D3D_FEATURE_LEVEL_12_0, IID_PPV_ARGS(&device)))) {
      throw std::runtime_error("Bootstrap device creation failed");
    }
    const auto native = GetModuleHandleW(
        (root / L"mods/darktidevr/bin/darktidevr_native_capture.dll").c_str());
    if (!native) throw std::runtime_error("Bootstrap did not load the fixture native module");
    const char* exports[] = {"dtvr_set_diagnostic_render_hooks", "dtvr_set_vertex_shader_dump",
        "dtvr_set_billboard_shader_substitution", "dtvr_set_billboard_pixel_shader_probe"};
    for (int i = 0; i < 4; ++i) {
      const int selected = std::stoi(argv[i + 2]);
      const auto select = reinterpret_cast<int (*)(int)>(GetProcAddress(native, exports[i]));
      if (!select || select(selected) != 0 || select(1 - selected) != 1) {
        throw std::runtime_error(std::string("Immutable startup selection disagrees: ") + exports[i]);
      }
    }
    std::cout << "bootstrap_selection=pass\n";
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
