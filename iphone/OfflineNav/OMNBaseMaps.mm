// Downloads the base world maps (World.mwm / WorldCoasts.mwm). They are not part of the framework;
// without them the map is blank outside downloaded countries and region maps. This is the same
// headless sequence the Android SDK drives: query the missing bytes, then download file after file
// until none is left. Progress goes out on the shared download event stream under "__base__".

#import "OMNInternal.hpp"

#include "storage/downloader.hpp"
#include "storage/map_files_downloader.hpp"
#include "storage/storage.hpp"

#include "platform/downloader_defines.hpp"
#include "platform/http_request.hpp"
#include "platform/platform.hpp"

#include "base/logging.hpp"

#include <algorithm>
#include <functional>
#include <memory>
#include <vector>

namespace
{
// Special codes, the same values the Android SDK uses.
constexpr int kErrDiskError = -1;
constexpr int kErrNotEnoughFreeSpace = -2;
constexpr int kErrStorageDisconnected = -3;
constexpr int kErrDownloadError = -4;
constexpr int kErrNoMoreFiles = -5;
constexpr int kErrFileInProgress = -6;

NSString * const kBaseId = @"__base__";

std::vector<platform::CountryFile> g_filesToDownload;
uint64_t g_totalDownloadedBytes = 0;
uint64_t g_totalBytesToDownload = 0;
std::shared_ptr<downloader::HttpRequest> g_currentRequest;
OMNCompletion g_pending = nil;
int64_t g_totalBytes = 1;

/// Makes the engine pick up the freshly downloaded world maps.
void ReloadWorldMaps()
{
  auto & f = OMNFramework();
  f.DeregisterAllMaps();
  f.RegisterAllMaps();
  f.GetSearchAPI().InitAfterWorldLoaded();
}

int BytesToDownload()
{
  g_filesToDownload.clear();
  g_totalBytesToDownload = 0;
  g_totalDownloadedBytes = 0;

  auto const & storage = OMNFramework().GetStorage();
  auto const status = storage.GetForceDownloadWorlds(g_filesToDownload);

  for (auto const & file : g_filesToDownload)
    g_totalBytesToDownload += file.GetRemoteSize();

  // Only World and WorldCoasts are downloaded here, so the total always fits into an int.
  int result;
  using enum storage::Storage::WorldStatus;
  if (status == ERROR_CREATE_FOLDER || status == ERROR_MOVE_FILE)
  {
    result = kErrDiskError;
  }
  else
  {
    switch (GetPlatform().GetWritableStorageStatus(g_totalBytesToDownload))
    {
    case Platform::STORAGE_DISCONNECTED: result = kErrStorageDisconnected; break;
    case Platform::NOT_ENOUGH_SPACE: result = kErrNotEnoughFreeSpace; break;
    default: result = static_cast<int>(g_totalBytesToDownload); break;
    }
  }

  g_currentRequest.reset();

  if (status == WAS_MOVED)
  {
    ReloadWorldMaps();
    result = 0;  // reset a possible storage error if files were moved
  }
  return result;
}

NSString * Describe(int errorCode)
{
  switch (errorCode)
  {
  case kErrNotEnoughFreeSpace: return @"Not enough free storage space";
  case kErrStorageDisconnected: return @"Storage is not available";
  case kErrDiskError: return @"Storage error";
  default: return @"Could not download the base world map (check your connection)";
  }
}

void Complete(int errorCode)
{
  OMNCompletion pending = g_pending;
  if (pending == nil)
    return;  // cancelled, or a late callback
  g_pending = nil;

  if (errorCode == 0)
  {
    ReloadWorldMaps();
    OMNSendDownloadEvent(@{@"countryId": kBaseId, @"status": @6, @"progress": @100});
    pending(nil);
    return;
  }

  NSLog(@"offline_navigation: base map download failed: %d", errorCode);
  OMNSendDownloadEvent(@{@"countryId": kBaseId, @"status": @4, @"progress": @(-1)});
  NSError * error = [NSError errorWithDomain:OMNErrorDomain
                                        code:1
                                    userInfo:@{
                                      OMNErrorCodeKey: @"base_map_download_failed",
                                      NSLocalizedDescriptionKey: Describe(errorCode),
                                      OMNErrorDetailsKey: @(errorCode),
                                    }];
  pending(error);
}

int StartNextFile();

void OnFileFinished(downloader::HttpRequest const & request)
{
  auto const status = request.GetStatus();
  int errorCode = kErrDownloadError;
  if (status == downloader::DownloadStatus::Completed)
    errorCode = 0;

  g_currentRequest.reset();

  if (errorCode == 0)
  {
    auto const & file = g_filesToDownload.back();
    g_totalDownloadedBytes += file.GetRemoteSize();
    g_filesToDownload.pop_back();
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    if (g_pending == nil)
      return;
    if (errorCode == 0)
    {
      // The next file started: wait for its callbacks. None left: done.
      if (StartNextFile() == kErrNoMoreFiles)
        Complete(0);
    }
    else
    {
      Complete(errorCode);
    }
  });
}

void OnFileProgress(downloader::HttpRequest const & request)
{
  // CUMULATIVE bytes downloaded over all files so far, not a percentage.
  int64_t const bytes = static_cast<int64_t>(g_totalDownloadedBytes) + request.GetProgress().m_bytesDownloaded;
  int const percent = static_cast<int>(std::clamp<int64_t>(bytes * 100 / std::max<int64_t>(g_totalBytes, 1), 0, 100));
  OMNSendDownloadEvent(@{@"countryId": kBaseId, @"status": @1, @"progress": @(percent)});
}

int StartNextFile()
{
  if (g_filesToDownload.empty())
    return kErrNoMoreFiles;

  // One downloader instance with cached servers.
  static auto downloader = storage::GetDownloader();
  auto const & storage = OMNFramework().GetStorage();
  downloader->SetDataVersion(storage.GetCurrentDataVersion());

  downloader->EnsureMetaConfigReady([&storage]()
  {
    auto const & file = g_filesToDownload.back();
    auto const fileName = file.GetFileName(MapFileType::Map);
    NSLog(@"offline_navigation: downloading %s", fileName.c_str());

    g_currentRequest.reset(downloader::HttpRequest::GetFile(
        downloader->MakeUrlListLegacy(fileName), storage.GetFilePath(file.GetName(), MapFileType::Map),
        file.GetRemoteSize(), &OnFileFinished, &OnFileProgress, false /* doCleanProgressFiles */));
  });

  return kErrFileInProgress;
}
}  // namespace

@implementation OMNEngine (BaseMaps)

+ (int64_t)baseMapBytesToDownload
{
  if (![self requireReady:nil])
    return kErrDiskError;
  return BytesToDownload();
}

+ (void)downloadBaseMapsWithCompletion:(OMNCompletion)completion
{
  NSError * error = nil;
  if (![self requireReady:&error])
  {
    completion(error);
    return;
  }
  if (g_pending != nil)
  {
    completion(OMNError(@"in_progress", @"Base map download already in progress"));
    return;
  }
  g_pending = [completion copy];
  g_totalBytes = std::max<int64_t>(BytesToDownload(), 1);

  if (StartNextFile() == kErrNoMoreFiles)
    Complete(0);
}

+ (void)cancelBaseMapDownload
{
  if (g_pending == nil)
    return;
  g_currentRequest.reset();
  OMNCompletion pending = g_pending;
  g_pending = nil;
  pending(OMNError(@"cancelled", @"Base map download cancelled"));
}

@end
