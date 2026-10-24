; Transparent Windows x64 forwarding for exports without public SDK signatures.
; The slow path preserves all four register arguments (integer and floating
; point) and leaves stack arguments in place before tail-calling Windows.
option casemap:none
EXTERN dtvr_resolve_d3d12_export:PROC

FORWARD_EXPORT MACRO symbol:req, export_name:req
.const
symbol&_name BYTE export_name, 0
.data
ALIGN 8
symbol&_target QWORD symbol&_resolve
.code
PUBLIC symbol
symbol PROC
    jmp QWORD PTR [symbol&_target]
symbol ENDP

symbol&_resolve PROC FRAME
    sub rsp, 088h
    .allocstack 088h
    .endprolog
    mov [rsp+020h], rcx
    mov [rsp+028h], rdx
    mov [rsp+030h], r8
    mov [rsp+038h], r9
    movdqu [rsp+040h], xmm0
    movdqu [rsp+050h], xmm1
    movdqu [rsp+060h], xmm2
    movdqu [rsp+070h], xmm3
    lea rcx, symbol&_name
    call dtvr_resolve_d3d12_export
    ; An aligned pointer store is atomic on x64. Concurrent first callers
    ; resolve the same immutable system export and may safely publish it.
    mov QWORD PTR [symbol&_target], rax
    mov rcx, [rsp+020h]
    mov rdx, [rsp+028h]
    mov r8, [rsp+030h]
    mov r9, [rsp+038h]
    movdqu xmm0, [rsp+040h]
    movdqu xmm1, [rsp+050h]
    movdqu xmm2, [rsp+060h]
    movdqu xmm3, [rsp+070h]
    add rsp, 088h
    jmp rax
symbol&_resolve ENDP
ENDM

FORWARD_EXPORT dtvr_forward_core_create, "D3D12CoreCreateLayeredDevice"
FORWARD_EXPORT dtvr_forward_core_size, "D3D12CoreGetLayeredDeviceSize"
FORWARD_EXPORT dtvr_forward_core_register, "D3D12CoreRegisterLayers"
FORWARD_EXPORT dtvr_forward_removed, "D3D12DeviceRemovedExtendedData"
FORWARD_EXPORT dtvr_forward_pix_replace, "D3D12PIXEventsReplaceBlock"
FORWARD_EXPORT dtvr_forward_pix_thread, "D3D12PIXGetThreadInfo"
FORWARD_EXPORT dtvr_forward_pix_wake, "D3D12PIXNotifyWakeFromFenceSignal"
FORWARD_EXPORT dtvr_forward_pix_counter, "D3D12PIXReportCounter"
FORWARD_EXPORT dtvr_forward_behavior, "GetBehaviorValue"
FORWARD_EXPORT dtvr_forward_appcompat, "SetAppCompatStringPointer"
END
