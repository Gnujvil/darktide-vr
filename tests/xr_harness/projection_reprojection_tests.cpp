#include "projection_reprojection.h"
#include "core/xr_math.h"
#include <d3d12sdklayers.h>
#include <dxgi1_4.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <vector>
using Microsoft::WRL::ComPtr;
using namespace darktidevr;
namespace {
void check(HRESULT hr) { if (FAILED(hr)) throw std::runtime_error("D3D12 reprojection operation failed"); }
void require(bool value, const char* why) { if (!value) throw std::runtime_error(why); }
ComPtr<ID3D12Resource> resource(ID3D12Device* device, D3D12_HEAP_TYPE type,
    D3D12_RESOURCE_DESC description, D3D12_RESOURCE_STATES state) {
  D3D12_HEAP_PROPERTIES heap{}; heap.Type=type;
  ComPtr<ID3D12Resource> result;
  check(device->CreateCommittedResource(&heap,D3D12_HEAP_FLAG_NONE,&description,
      state,nullptr,IID_PPV_ARGS(&result))); return result;
}
XrPosef xr_pose(math::Quaternion q, math::Vec3 p) {
  return {{q.x,q.y,q.z,q.w},{p.x,p.y,p.z}};
}
int channel(float coordinate) {
  return static_cast<int>(std::lround(std::clamp(.5F+coordinate*.2F,0.0F,1.0F)*255));
}
}
int main() {
  try {
    constexpr UINT size=256;
    ComPtr<ID3D12Debug> debug; check(D3D12GetDebugInterface(IID_PPV_ARGS(&debug)));
    debug->EnableDebugLayer();
    ComPtr<IDXGIFactory4> factory; check(CreateDXGIFactory1(IID_PPV_ARGS(&factory)));
    ComPtr<IDXGIAdapter> warp; check(factory->EnumWarpAdapter(IID_PPV_ARGS(&warp)));
    ComPtr<ID3D12Device> device; check(D3D12CreateDevice(warp.Get(),D3D_FEATURE_LEVEL_12_0,IID_PPV_ARGS(&device)));
    ComPtr<ID3D12InfoQueue> messages; check(device.As(&messages));
    D3D12_COMMAND_QUEUE_DESC queue_info{};
    ComPtr<ID3D12CommandQueue> queue; check(device->CreateCommandQueue(&queue_info,IID_PPV_ARGS(&queue)));
    ComPtr<ID3D12CommandAllocator> allocator; check(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,IID_PPV_ARGS(&allocator)));
    ComPtr<ID3D12GraphicsCommandList> commands; check(device->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_DIRECT,allocator.Get(),nullptr,IID_PPV_ARGS(&commands)));
    D3D12_RESOURCE_DESC description{};
    description.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;description.Width=description.Height=size;
    description.DepthOrArraySize=description.MipLevels=1;description.SampleDesc.Count=1;
    description.Format=DXGI_FORMAT_R8G8B8A8_UNORM;description.Flags=D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    std::array<ComPtr<ID3D12Resource>,2> images;
    std::array<ID3D12Resource*,2> pointers{};
    D3D12_DESCRIPTOR_HEAP_DESC rtv_info{};rtv_info.Type=D3D12_DESCRIPTOR_HEAP_TYPE_RTV;rtv_info.NumDescriptors=2;
    ComPtr<ID3D12DescriptorHeap> rtv;check(device->CreateDescriptorHeap(&rtv_info,IID_PPV_ARGS(&rtv)));
    std::array<D3D12_CPU_DESCRIPTOR_HANDLE,2> targets{};
    for(UINT eye=0;eye<2;++eye){
      images[eye]=resource(device.Get(),D3D12_HEAP_TYPE_DEFAULT,description,D3D12_RESOURCE_STATE_COMMON);
      pointers[eye]=images[eye].Get();targets[eye]=rtv->GetCPUDescriptorHandleForHeapStart();
      targets[eye].ptr+=eye*device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
      device->CreateRenderTargetView(images[eye].Get(),nullptr,targets[eye]);
    }
    harness::ProjectionReprojector reprojector(device.Get(),description.Format,description);
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};UINT64 bytes{};
    device->GetCopyableFootprints(&description,0,1,0,&footprint,nullptr,nullptr,&bytes);
    D3D12_RESOURCE_DESC buffer{};buffer.Dimension=D3D12_RESOURCE_DIMENSION_BUFFER;buffer.Width=bytes;
    buffer.Height=buffer.DepthOrArraySize=buffer.MipLevels=1;buffer.SampleDesc.Count=1;buffer.Layout=D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    std::array<ComPtr<ID3D12Resource>,2> uploads,readbacks;
    for(UINT eye=0;eye<2;++eye){
      uploads[eye]=resource(device.Get(),D3D12_HEAP_TYPE_UPLOAD,buffer,D3D12_RESOURCE_STATE_GENERIC_READ);
      readbacks[eye]=resource(device.Get(),D3D12_HEAP_TYPE_READBACK,buffer,D3D12_RESOURCE_STATE_COPY_DEST);
    }
    ComPtr<ID3D12Fence> fence;check(device->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&fence)));
    const std::array<XrFovf,2> native{{{-.942478F,.698132F,.767945F,-.959931F},
                                     {-.698132F,.942478F,.767945F,-.959931F}}};
    for(UINT frame=0;frame<2;++frame){
      if(frame){check(allocator->Reset());check(commands->Reset(allocator.Get(),nullptr));}
      const auto head=math::multiply(math::from_axis_angle({0,1,0},frame*.3F),math::from_axis_angle({0,0,1},frame*.2F));
      std::array<XrPosef,2> source_pose{},native_pose{};
      std::array<XrFovf,2> source_fov{};
      for(UINT eye=0;eye<2;++eye){
        const float yaw=(eye==0 ? .122173F : -.122173F)*(frame ? 1.3F : 1.0F);
        const auto optical=math::multiply(math::from_axis_angle({0,1,0},yaw),math::from_axis_angle({1,0,0},-.095993F));
        const auto position=math::Vec3{eye==0 ? -.031F : .031F,1.6F,-.4F};
        source_pose[eye]=xr_pose(math::multiply(head,optical),position);
        native_pose[eye]=xr_pose(head,position);
        source_fov[eye]={-.88F,.88F,.864F,-.864F};
        std::uint8_t* pixels{};check(uploads[eye]->Map(0,nullptr,reinterpret_cast<void**>(&pixels)));
        for(UINT y=0;y<size;++y) for(UINT x=0;x<size;++x){
          const auto ray=math::rotate(optical,{(2*(x+.5F)/size-1)*std::tan(.88F),
                                                (1-2*(y+.5F)/size)*std::tan(.864F),-1});
          auto* pixel=pixels+y*footprint.Footprint.RowPitch+x*4;
          pixel[0]=static_cast<std::uint8_t>(channel(ray.x/-ray.z));
          pixel[1]=static_cast<std::uint8_t>(channel(ray.y/-ray.z));
          pixel[2]=static_cast<std::uint8_t>(eye==0 ? 64+frame*32 : 192-frame*32);
          pixel[3]=0; // Game RGB is opaque even when its unused alpha is zero.
        }
        uploads[eye]->Unmap(0,nullptr);
        D3D12_RESOURCE_BARRIER barrier{};barrier.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        barrier.Transition={images[eye].Get(),D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,D3D12_RESOURCE_STATE_COMMON,D3D12_RESOURCE_STATE_COPY_DEST};
        commands->ResourceBarrier(1,&barrier);
        D3D12_TEXTURE_COPY_LOCATION src{};src.pResource=uploads[eye].Get();src.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;src.PlacedFootprint=footprint;
        D3D12_TEXTURE_COPY_LOCATION dst{};dst.pResource=images[eye].Get();dst.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        commands->CopyTextureRegion(&dst,0,0,0,&src,nullptr);
        std::swap(barrier.Transition.StateBefore,barrier.Transition.StateAfter);commands->ResourceBarrier(1,&barrier);
      }
      reprojector.record(commands.Get(),pointers,targets,source_pose,source_fov,native_pose,native,D3D12_RESOURCE_STATE_COMMON);
      for(UINT eye=0;eye<2;++eye){
        D3D12_RESOURCE_BARRIER barrier{};barrier.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        barrier.Transition={images[eye].Get(),D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,D3D12_RESOURCE_STATE_COMMON,D3D12_RESOURCE_STATE_COPY_SOURCE};commands->ResourceBarrier(1,&barrier);
        D3D12_TEXTURE_COPY_LOCATION src{};src.pResource=images[eye].Get();src.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        D3D12_TEXTURE_COPY_LOCATION dst{};dst.pResource=readbacks[eye].Get();dst.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;dst.PlacedFootprint=footprint;
        commands->CopyTextureRegion(&dst,0,0,0,&src,nullptr);
        std::swap(barrier.Transition.StateBefore,barrier.Transition.StateAfter);commands->ResourceBarrier(1,&barrier);
      }
      check(commands->Close());ID3D12CommandList* lists[]{commands.Get()};queue->ExecuteCommandLists(1,lists);
      check(queue->Signal(fence.Get(),frame+1));const auto completed=CreateEventW(nullptr,FALSE,FALSE,nullptr);
      require(completed!=nullptr,"Missing completion event");check(fence->SetEventOnCompletion(frame+1,completed));
      const auto waited=WaitForSingleObject(completed,10000);CloseHandle(completed);require(waited==WAIT_OBJECT_0,"GPU timeout");
      for(UINT eye=0;eye<2;++eye){
        const std::uint8_t* pixels{};check(readbacks[eye]->Map(0,nullptr,reinterpret_cast<void**>(const_cast<std::uint8_t**>(&pixels))));
        for(const auto ray:std::array<math::Vec3,3>{{{0,0,-1},{.2F,.1F,-1},{-.2F,-.1F,-1}}}){
          const auto& f=native[eye];const float left=std::tan(f.angleLeft),right=std::tan(f.angleRight),up=std::tan(f.angleUp),down=std::tan(f.angleDown);
          const UINT x=static_cast<UINT>((ray.x-left)/(right-left)*size),y=static_cast<UINT>((up-ray.y)/(up-down)*size);
          const auto* pixel=pixels+y*footprint.Footprint.RowPitch+x*4;
          const float expected_x=left+(right-left)*(x+.5F)/size,expected_y=up+(down-up)*(y+.5F)/size;
          require(std::abs(static_cast<int>(pixel[0])-channel(expected_x))<=3,"Horizontal stereo ray is misaligned");
          require(std::abs(static_cast<int>(pixel[1])-channel(expected_y))<=3,"Vertical stereo ray is misaligned");
          require(std::abs(static_cast<int>(pixel[2])-static_cast<int>(eye==0 ? 64+frame*32 : 192-frame*32))<=1,"Eyes or cached frames were mixed");
          require(pixel[3]==255,"Opaque game pixels were lost to alpha blending");
        }
        D3D12_RANGE no_write{0,0};readbacks[eye]->Unmap(0,&no_write);
      }
    }
    for(UINT64 index=0;index<messages->GetNumStoredMessages();++index){
      SIZE_T bytes_message{};check(messages->GetMessage(index,nullptr,&bytes_message));std::vector<std::byte> data(bytes_message);
      auto* message=reinterpret_cast<D3D12_MESSAGE*>(data.data());check(messages->GetMessage(index,message,&bytes_message));
      if(message->Severity==D3D12_MESSAGE_SEVERITY_ERROR || message->Severity==D3D12_MESSAGE_SEVERITY_CORRUPTION)
        throw std::runtime_error(message->pDescription);
    }
    std::cout<<"projection_reprojection=pass stereo_rays=12 alpha_zero=opaque repeated_frames=2 debug_errors=0\n";
  } catch(const std::exception& error){std::cerr<<error.what()<<'\n';return 1;}
}
