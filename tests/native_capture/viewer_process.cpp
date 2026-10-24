#include "producer/viewer_process.h"

#include <Windows.h>

#include <array>
#include <chrono>
#include <cwchar>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <thread>

namespace {
void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

void set(const wchar_t* name, const wchar_t* value) {
  require(SetEnvironmentVariableW(name, value) != FALSE, "SetEnvironmentVariableW failed");
}

std::wstring environment(const wchar_t* name) {
  const auto size = GetEnvironmentVariableW(name, nullptr, 0);
  if (size == 0) return {};
  std::wstring value(size, L'\0');
  const auto length = GetEnvironmentVariableW(name, value.data(), size);
  value.resize(length);
  return value;
}

std::string utf8(const wchar_t* value) {
  const auto size = WideCharToMultiByte(CP_UTF8, 0, value, -1, nullptr, 0, nullptr, nullptr);
  std::string result(static_cast<std::size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, value, -1, result.data(), size, nullptr, nullptr);
  result.pop_back();
  return result;
}

std::string run_probe(const std::filesystem::path& log) {
  require(darktidevr::producer::viewer::control(true) == 0, "Viewer did not start");
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
  std::array<int, 5> state{};
  do {
    require(darktidevr::producer::viewer::state(state.data(),
        static_cast<unsigned int>(state.size())) == 0, "Viewer state failed");
    if (state[0] == 0) break;
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  } while (std::chrono::steady_clock::now() < deadline);
  require(state[0] == 0 && state[1] == 0, "Environment probe failed or timed out");
  std::ifstream input(log);
  require(input.good(), "Viewer log was not created");
  return {std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
}

void expect(const std::string& report, const std::string& line) {
  require(report.find(line + '\n') != std::string::npos, line.c_str());
}
}  // namespace

int main() {
  const auto scratch = std::filesystem::temp_directory_path() /
      (L"darktidevr-viewer-test-" + std::to_wstring(GetCurrentProcessId()));
  const auto output = scratch / L"DarktideVR";
  const auto stem = L"viewer-" + std::to_wstring(GetCurrentProcessId());
  const auto log = output / (stem + L".log");
  bool owned = false;
  int result = 1;
  try {
    require(std::filesystem::create_directory(scratch), "Test scratch path already exists");
    owned = true;
    set(L"LOCALAPPDATA", scratch.c_str());
    set(L"sTeAmApPiD", L"1361210");
    set(L"SteamGameId", L"1361210");
    set(L"SteamOverlayGameId", L"1361210");
    set(L"STEAMVR_APPKEY", L"steam.app.1361210");
    set(L"XR_RUNTIME_JSON", L"C:\\VR runtime\\steamxr_win64.json");
    set(L"SteamAppIdExtra", L"keep-this");
    set(L"DTVR_TEST_UNICODE", L"\u0141\u00f3d\u017a");
    set(L"DTVR_TEST_EQUALS", L"value=a=b");

    const auto report = run_probe(log);
    expect(report, "SteamAppId=<unset>");
    expect(report, "SteamGameId=<unset>");
    expect(report, "SteamOverlayGameId=<unset>");
    expect(report, "STEAMVR_APPKEY=<unset>");
    expect(report, "XR_RUNTIME_JSON=C:\\VR runtime\\steamxr_win64.json");
    expect(report, "SteamAppIdExtra=keep-this");
    expect(report, "DTVR_TEST_UNICODE=" + utf8(L"\u0141\u00f3d\u017a"));
    expect(report, "DTVR_TEST_EQUALS=value=a=b");
    require(environment(L"SteamAppId") == L"1361210" &&
        environment(L"SteamGameId") == L"1361210" &&
        environment(L"SteamOverlayGameId") == L"1361210" &&
        environment(L"STEAMVR_APPKEY") == L"steam.app.1361210",
        "Viewer launch modified the parent game's Steam identity");

    const auto inherited = GetEnvironmentStringsW();
    require(inherited != nullptr, "Parent environment snapshot failed");
    for (auto* entry = inherited; *entry; entry += std::wcslen(entry) + 1) {
      if (*entry == L'=') expect(report, "drive:" + utf8(entry));
    }
    FreeEnvironmentStringsW(inherited);

    // A non-Steam launch and a viewer restart must preserve normal variables too.
    set(L"SteamAppId", nullptr);
    set(L"SteamGameId", nullptr);
    set(L"SteamOverlayGameId", nullptr);
    set(L"STEAMVR_APPKEY", nullptr);
    const auto restarted = run_probe(log);
    expect(restarted, "SteamAppId=<unset>");
    expect(restarted, "XR_RUNTIME_JSON=C:\\VR runtime\\steamxr_win64.json");
    expect(restarted, "DTVR_TEST_UNICODE=" + utf8(L"\u0141\u00f3d\u017a"));
    require(darktidevr::producer::viewer::control(false) == 0, "Stopped viewer was not reaped");
    std::cout << "viewer_process_identity=pass isolated_child parent_unchanged runtime unicode exact_names drive_entries restart\n";
    result = 0;
  } catch (const std::exception& error) {
    darktidevr::producer::viewer::control(false);
    std::cerr << "viewer_process_identity=fail " << error.what() << '\n';
  }
  if (owned) {
    // Remove only the files this fixture owns; never recurse over a computed path.
    std::error_code ignored;
    std::filesystem::remove(log, ignored);
    std::filesystem::remove(output / (stem + L"-1.log"), ignored);
    std::filesystem::remove(output, ignored);
    std::filesystem::remove(scratch, ignored);
  }
  return result;
}
