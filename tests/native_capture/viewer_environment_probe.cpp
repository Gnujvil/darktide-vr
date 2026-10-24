#include <Windows.h>

#include <array>
#include <cwchar>
#include <iostream>
#include <string>

namespace {
std::string utf8(const std::wstring& value) {
  if (value.empty()) return {};
  const auto size = WideCharToMultiByte(CP_UTF8, 0, value.data(),
      static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  std::string result(static_cast<std::size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
      result.data(), size, nullptr, nullptr);
  return result;
}

std::wstring environment(const wchar_t* name) {
  const auto size = GetEnvironmentVariableW(name, nullptr, 0);
  if (size == 0) return L"<unset>";
  std::wstring value(size, L'\0');
  const auto length = GetEnvironmentVariableW(name, value.data(), size);
  value.resize(length);
  return value;
}
}  // namespace

int main() {
  constexpr std::array names{L"SteamAppId", L"SteamGameId",
      L"SteamOverlayGameId", L"STEAMVR_APPKEY", L"XR_RUNTIME_JSON",
      L"SteamAppIdExtra", L"DTVR_TEST_UNICODE", L"DTVR_TEST_EQUALS"};
  for (const auto* name : names) {
    std::cout << utf8(name) << '=' << utf8(environment(name)) << '\n';
  }
  // Windows also carries hidden drive-current-directory entries such as =C:.
  const auto inherited = GetEnvironmentStringsW();
  if (!inherited) return 1;
  for (auto* entry = inherited; *entry; entry += std::wcslen(entry) + 1) {
    if (*entry == L'=') std::cout << "drive:" << utf8(entry) << '\n';
  }
  FreeEnvironmentStringsW(inherited);
  std::cout.flush();
  return std::cout.good() ? 0 : 1;
}
