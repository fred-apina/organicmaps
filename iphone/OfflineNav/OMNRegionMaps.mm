// Installs, lists and removes region maps: map files that are not part of the engine's country
// list, for example an extract of a single national park.
//
// Files live next to the engine's own maps, in `<writable dir>/<data version>/<id>.mwm`, and are
// registered with the running engine, so routing and rendering use them at once, with no restart.
//
// Threading: engine calls (register / deregister) run on the main thread; hashing and file copies
// run on a background queue. Completions are always called on the main thread.

#import <CommonCrypto/CommonDigest.h>

#import "OMNInternal.hpp"

#include "platform/local_country_file.hpp"
#include "platform/platform.hpp"

#include "storage/country_info_getter.hpp"
#include "storage/storage.hpp"

#include "base/file_name_utils.hpp"
#include "base/logging.hpp"

#include <set>
#include <string>
#include <vector>

@interface OMNRegionMap ()
- (instancetype)initWithId:(NSString *)mapId sizeBytes:(int64_t)sizeBytes;
@end

namespace
{
constexpr size_t kReadChunkBytes = 256 * 1024;

/// Extra free space required on top of the file size when copying.
constexpr int64_t kFreeSpaceMargin = 16LL * 1024 * 1024;

dispatch_queue_t IoQueue()
{
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ queue = dispatch_queue_create("offline_navigation-io", DISPATCH_QUEUE_SERIAL); });
  return queue;
}

NSRegularExpression * IdPattern()
{
  static NSRegularExpression * pattern;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    pattern = [NSRegularExpression regularExpressionWithPattern:@"^[A-Za-z0-9_-]{1,64}$" options:0 error:nil];
  });
  return pattern;
}

/// Base maps managed by the engine; a region map must never shadow them.
BOOL IsReservedId(NSString * mapId)
{
  NSString * lower = mapId.lowercaseString;
  return [lower isEqualToString:@"world"] || [lower isEqualToString:@"worldcoasts"];
}

BOOL MatchesIdPattern(NSString * mapId)
{
  return [IdPattern() numberOfMatchesInString:mapId options:0 range:NSMakeRange(0, mapId.length)] == 1;
}

BOOL IsValidId(NSString * mapId)
{
  return MatchesIdPattern(mapId) && !IsReservedId(mapId);
}

NSError * ValidateId(NSString * mapId)
{
  if (!MatchesIdPattern(mapId))
    return OMNError(@"invalid_id", @"A region map id must match [A-Za-z0-9_-]{1,64}");
  if (IsReservedId(mapId))
    return OMNError(@"reserved_name", [NSString stringWithFormat:@"'%@' is reserved for built-in base maps", mapId]);
  return nil;
}

int64_t DataVersion()
{
  return OMNFramework().GetCurrentDataVersion();
}

/// The engine's maps directory for its data version, created if missing.
NSString * MapsDirectory(NSError ** error)
{
  std::string const path = base::JoinPath(GetPlatform().WritableDir(), std::to_string(DataVersion()));
  NSString * dir = @(path.c_str());
  BOOL isDir = NO;
  NSFileManager * fm = NSFileManager.defaultManager;
  if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir)
  {
    NSError * createError = nil;
    if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&createError])
    {
      if (error)
        *error = OMNError(@"io_error", [NSString stringWithFormat:@"Cannot create the maps directory %@", dir]);
      return nil;
    }
    Platform::DisableBackupForFile(path);
  }
  return dir;
}

int64_t FreeSpaceAt(NSString * path)
{
  NSURL * url = [NSURL fileURLWithPath:path];
  NSNumber * value = nil;
  if ([url getResourceValue:&value forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:nil] && value)
    return value.longLongValue;
  NSDictionary * attributes = [NSFileManager.defaultManager attributesOfFileSystemForPath:path error:nil];
  return [attributes[NSFileSystemFreeSize] longLongValue];
}

int64_t FileSize(NSString * path)
{
  NSDictionary * attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
  return [attributes[NSFileSize] longLongValue];
}

NSError * VerifyChecksum(NSString * path, NSString * expectedHex)
{
  NSInputStream * input = [NSInputStream inputStreamWithFileAtPath:path];
  [input open];
  CC_SHA256_CTX context;
  CC_SHA256_Init(&context);
  std::vector<uint8_t> buffer(kReadChunkBytes);
  while (true)
  {
    NSInteger const read = [input read:buffer.data() maxLength:buffer.size()];
    if (read < 0)
    {
      [input close];
      return OMNError(@"io_error", @"Cannot read the map file");
    }
    if (read == 0)
      break;
    CC_SHA256_Update(&context, buffer.data(), static_cast<CC_LONG>(read));
  }
  [input close];

  uint8_t digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256_Final(digest, &context);
  NSMutableString * actual = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
  for (uint8_t byte : digest)
    [actual appendFormat:@"%02x", byte];

  NSString * expected = [expectedHex stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if ([actual caseInsensitiveCompare:expected] != NSOrderedSame)
    return OMNError(@"checksum_mismatch", [NSString stringWithFormat:@"SHA-256 mismatch for %@", path.lastPathComponent]);
  return nil;
}

/// Puts `source` at `target` atomically: copy to `<target>.tmp`, then rename.
NSError * Place(NSString * source, NSString * dir, NSString * target, BOOL moveFile)
{
  NSFileManager * fm = NSFileManager.defaultManager;
  // A stale file of an unregistered map (for example from an interrupted install).
  if ([fm fileExistsAtPath:target] && ![fm removeItemAtPath:target error:nil])
    return OMNError(@"io_error", [NSString stringWithFormat:@"Cannot replace %@", target]);

  if (moveFile && [fm moveItemAtPath:source toPath:target error:nil])
    return nil;  // same volume: atomic and free

  if (FreeSpaceAt(dir) < FileSize(source) + kFreeSpaceMargin)
    return OMNError(@"not_enough_space", @"Not enough free storage space");

  NSString * temp = [target stringByAppendingString:@".tmp"];
  [fm removeItemAtPath:temp error:nil];
  NSError * copyError = nil;
  if (![fm copyItemAtPath:source toPath:temp error:&copyError] || ![fm moveItemAtPath:temp toPath:target error:&copyError])
  {
    [fm removeItemAtPath:temp error:nil];
    return OMNError(@"io_error", copyError.localizedDescription ?: @"Cannot copy the map file");
  }
  if (moveFile)
    [fm removeItemAtPath:source error:nil];
  return nil;
}

/// Registers the placed file with the engine. Main thread.
void RegisterPlaced(NSString * mapId, NSString * dir, NSString * target, OMNRegionMapCompletion completion)
{
  enum class Result
  {
    Registered,
    AlreadyRegistered,
    VersionTooOld,
    UnsupportedFormat,
    BadFile,
    FileNotFound,
    ReservedName
  };

  Result result = Result::BadFile;
  std::string const name = mapId.UTF8String;
  auto & f = OMNFramework();

  // A custom map must not shadow a map of the countries tree: those are managed by the downloader.
  if (f.GetStorage().IsNode(name))
  {
    result = Result::ReservedName;
  }
  else
  {
    platform::LocalCountryFile file(dir.UTF8String, platform::CountryFile(name), DataVersion());
    file.SyncWithDisk();
    if (!file.OnDisk(MapFileType::Map))
    {
      result = Result::FileNotFound;
    }
    else
    {
      try
      {
        switch (f.RegisterCustomMap(file).second)
        {
        case MwmSet::RegResult::Success: result = Result::Registered; break;
        case MwmSet::RegResult::VersionAlreadyExists: result = Result::AlreadyRegistered; break;
        case MwmSet::RegResult::VersionTooOld: result = Result::VersionTooOld; break;
        case MwmSet::RegResult::UnsupportedFileFormat: result = Result::UnsupportedFormat; break;
        case MwmSet::RegResult::BadFile: result = Result::BadFile; break;
        }
      }
      catch (RootException const & ex)
      {
        LOG(LWARNING, ("Can't register custom map", name, ex.Msg()));
      }
      catch (std::exception const & ex)
      {
        LOG(LWARNING, ("Can't register custom map", name, ex.what()));
      }
    }
  }

  if (result == Result::Registered)
  {
    completion([[OMNRegionMap alloc] initWithId:mapId sizeBytes:FileSize(target)], nil);
    return;
  }

  [NSFileManager.defaultManager removeItemAtPath:target error:nil];
  switch (result)
  {
  case Result::AlreadyRegistered:
    completion(nil, OMNError(@"already_installed", [NSString stringWithFormat:@"Region map '%@' is already installed", mapId]));
    break;
  case Result::VersionTooOld:
    completion(nil, OMNError(@"version_too_old", @"The map file is older than the installed one"));
    break;
  case Result::UnsupportedFormat:
    completion(nil, OMNError(@"unsupported_format",
                             @"The map file was built with a different engine version. Rebuild it with a generator "
                             @"that matches the engine."));
    break;
  case Result::FileNotFound: completion(nil, OMNError(@"file_not_found", @"The map file disappeared")); break;
  case Result::ReservedName:
    completion(nil, OMNError(@"reserved_name", @"The id is the id of a built-in map region"));
    break;
  default: completion(nil, OMNError(@"bad_file", @"The engine could not read the map file")); break;
  }
}
}  // namespace

@implementation OMNRegionMap
- (instancetype)initWithId:(NSString *)mapId sizeBytes:(int64_t)sizeBytes
{
  if ((self = [super init]))
  {
    _mapId = [mapId copy];
    _sizeBytes = sizeBytes;
  }
  return self;
}
@end

@implementation OMNEngine (RegionMaps)

+ (NSString *)regionMapsDirectory:(NSError **)error
{
  if (![self requireReady:error])
    return nil;
  return MapsDirectory(error);
}

+ (int64_t)freeSpaceBytes
{
  NSString * dir = [self regionMapsDirectory:nil];
  return dir ? FreeSpaceAt(dir) : 0;
}

+ (BOOL)isRegionMapInstalled:(NSString *)mapId
{
  if (![self requireReady:nil])
    return NO;
  return IsValidId(mapId) && OMNFramework().GetDataSource().IsLoaded(platform::CountryFile(mapId.UTF8String));
}

+ (NSArray<OMNRegionMap *> *)listRegionMaps
{
  if (![self requireReady:nil])
    return @[];
  NSString * dir = [self regionMapsDirectory:nil];
  if (!dir)
    return @[];

  std::set<std::string> names;
  OMNFramework().GetCountryInfoGetter().ForEachCustomRegion([&names](storage::CountryId const & id, m2::RectD const &)
  { names.insert(id); });

  NSMutableArray<OMNRegionMap *> * maps = [NSMutableArray array];
  for (std::string const & name : names)
  {
    NSString * mapId = @(name.c_str());
    NSString * file = [dir stringByAppendingPathComponent:[mapId stringByAppendingString:@".mwm"]];
    [maps addObject:[[OMNRegionMap alloc] initWithId:mapId sizeBytes:FileSize(file)]];
  }
  return maps;
}

+ (void)installRegionMapWithId:(NSString *)mapId
                          path:(NSString *)path
                        sha256:(NSString *)sha256
                      moveFile:(BOOL)moveFile
                       replace:(BOOL)replace
                    completion:(OMNRegionMapCompletion)completion
{
  // Validates the request and frees the id for a replacement. Main thread.
  NSError * error = nil;
  if (![self requireReady:&error] || (error = ValidateId(mapId)) != nil)
  {
    completion(nil, error);
    return;
  }
  NSString * dir = MapsDirectory(&error);
  if (!dir)
  {
    completion(nil, error);
    return;
  }
  BOOL isFile = NO;
  if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isFile] || isFile)
  {
    completion(nil, OMNError(@"file_not_found", [NSString stringWithFormat:@"No such file: %@", path]));
    return;
  }

  auto & f = OMNFramework();
  platform::CountryFile const countryFile(mapId.UTF8String);
  if (f.GetDataSource().IsLoaded(countryFile))
  {
    if (!replace)
    {
      completion(nil, OMNError(@"already_installed", [NSString stringWithFormat:@"Region map '%@' is already installed", mapId]));
      return;
    }
    // The engine deletes the old file when it deregisters the map. That is only safe to wait for
    // when nothing uses the map right now; otherwise the delayed deletion would hit the new file
    // that takes its place.
    if (!f.DeregisterCustomMap(countryFile))
    {
      completion(nil, OMNError(@"in_use", @"Region map is in use right now; close navigation and retry"));
      return;
    }
  }

  NSString * target = [dir stringByAppendingPathComponent:[mapId stringByAppendingString:@".mwm"]];
  dispatch_async(IoQueue(), ^{
    NSError * placeError = nil;
    if (sha256)
      placeError = VerifyChecksum(path, sha256);
    if (!placeError)
      placeError = Place(path, dir, target, moveFile);
    dispatch_async(dispatch_get_main_queue(), ^{
      if (placeError)
        completion(nil, placeError);
      else
        RegisterPlaced(mapId, dir, target, completion);
    });
  });
}

+ (void)removeRegionMapWithId:(NSString *)mapId completion:(OMNCompletion)completion
{
  NSError * error = nil;
  if (![self requireReady:&error] || (error = ValidateId(mapId)) != nil)
  {
    completion(error);
    return;
  }
  NSString * dir = MapsDirectory(&error);
  if (!dir)
  {
    completion(error);
    return;
  }

  // When the map is in use the engine keeps it until the user is done and deletes the file then;
  // for the caller the map is gone either way.
  auto & f = OMNFramework();
  platform::CountryFile const countryFile(mapId.UTF8String);
  if (!f.GetStorage().IsNode(countryFile.GetName()))
    f.DeregisterCustomMap(countryFile);

  if (!f.GetDataSource().IsLoaded(countryFile))
  {
    // Leftovers of an unregistered or partially installed map.
    NSString * target = [dir stringByAppendingPathComponent:[mapId stringByAppendingString:@".mwm"]];
    for (NSString * leftover in @[target, [target stringByAppendingString:@".tmp"]])
    {
      NSFileManager * fm = NSFileManager.defaultManager;
      if ([fm fileExistsAtPath:leftover] && ![fm removeItemAtPath:leftover error:nil])
        NSLog(@"offline_navigation: could not delete %@", leftover);
    }
  }
  completion(nil);
}

@end
