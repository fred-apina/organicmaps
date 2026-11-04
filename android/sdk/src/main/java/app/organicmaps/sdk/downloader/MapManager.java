package app.organicmaps.sdk.downloader;

import androidx.annotation.Keep;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.UiThread;
import java.util.List;

@UiThread
public final class MapManager
{
  // Used by JNI.
  @Keep
  public static class StorageCallbackData
  {
    public final String countryId;
    public final int newStatus;
    public final int errorCode;
    public final boolean isLeafNode;

    public StorageCallbackData(String countryId, int newStatus, int errorCode, boolean isLeafNode)
    {
      this.countryId = countryId;
      this.newStatus = newStatus;
      this.errorCode = errorCode;
      this.isLeafNode = isLeafNode;
    }
  }

  public interface StorageCallback
  {
    // Called from JNI.
    @Keep
    void onStatusChanged(List<StorageCallbackData> data);

    // Called from JNI.
    @Keep
    void onProgress(String countryId, long localSize, long remoteSize);
  }

  public interface CurrentCountryChangedListener
  {
    // Called from JNI.
    @Keep
    @SuppressWarnings("unused")
    void onCurrentCountryChanged(String countryId);
  }

  private MapManager() {}

  /**
   * Enqueues failed items under given {@code root} node in downloader.
   */
  public static void retryDownload(@NonNull String countryId)
  {
    nativeRetry(countryId);
  }

  /**
   * Enqueues given {@code root} node with its children in downloader.
   */
  public static void startUpdate(@NonNull String root)
  {
    nativeUpdate(root);
  }

  /**
   * Enqueues the given list of nodes and its children in downloader.
   */
  public static void startDownload(String... countries)
  {
    for (var countryId : countries)
    {
      nativeDownload(countryId);
    }
  }

  /**
   * Enqueues given {@code root} node and its children in downloader.
   */
  public static void startDownload(@NonNull String countryId)
  {
    nativeDownload(countryId);
  }

  /**
   * Retrieves ID of root node.
   */
  public static native String nativeGetRoot();

  /**
   * Moves a file from one place to another.
   */
  public static native boolean nativeMoveFile(String oldFile, String newFile);

  /**
   * Returns {@code true} if there is enough storage space to download specified amount of data. Or {@code false}
   * otherwise.
   */
  public static native boolean nativeHasSpaceToDownloadAmount(long bytes);

  /**
   * Returns {@code true} if there is enough storage space to download maps with specified {@code root}. Or {@code
   * false} otherwise.
   */
  public static native boolean nativeHasSpaceToDownloadCountry(String root);

  /**
   * Returns {@code true} if there is enough storage space to update maps with specified {@code root}. Or {@code false}
   * otherwise.
   */
  public static native boolean nativeHasSpaceToUpdate(String root);

  /**
   * Return count of fully downloaded maps (excluding fake MWMs).
   */
  public static native int nativeGetDownloadedCount();

  /**
   * Returns info about updatable data under given {@code root} or null on error.
   */
  public static native @Nullable UpdateInfo nativeGetUpdateInfo(@Nullable String root);

  /**
   * Retrieves list of country items with its status info.
   * if {@code root} is {@code null}, list of downloaded countries is returned.
   */
  public static native void nativeListItems(@Nullable String root, double lat, double lon, boolean hasLocation,
                                            boolean myMapsMode, List<CountryItem> result);

  /**
   * Sets following attributes of the given {@code item}:
   * <pre>
   * <ul>
   *   <li>name;</li>
   *   <li>directParentId;</li>
   *   <li>topmostParentId;</li>
   *   <li>directParentName;</li>
   *   <li>topmostParentName;</li>
   *   <li>description;</li>
   *   <li>size;</li>
   *   <li>enqueuedSize;</li>
   *   <li>totalSize;</li>
   *   <li>childCount;</li>
   *   <li>totalChildCount;</li>
   *   <li>status;</li>
   *   <li>errorCode;</li>
   *   <li>present;</li>
   *   <li>progress</li>
   * </ul>
   * </pre>
   */
  public static native void nativeGetAttributes(CountryItem item);

  /**
   * Returns status for given {@code root} node.
   */
  public static native int nativeGetStatus(String root);

  /**
   * Returns downloading error for given {@code root} node.
   */
  public static native int nativeGetError(String root);

  /**
   * Returns localized name for given {@code root} node.
   */
  public static native String nativeGetName(String root);

  /**
   * Returns country ID corresponding to given coordinates or {@code null} on error.
   */
  public static native @Nullable String nativeFindCountry(double lat, double lon);

  /** Result codes of {@link #nativeRegisterLocalMap(String, long, String)}. Keep in sync with MapManager.cpp. */
  public static final int LOCAL_MAP_REGISTERED = 0;
  public static final int LOCAL_MAP_ALREADY_REGISTERED = 1;
  public static final int LOCAL_MAP_VERSION_TOO_OLD = 2;
  public static final int LOCAL_MAP_UNSUPPORTED_FORMAT = 3;
  public static final int LOCAL_MAP_BAD_FILE = 4;
  public static final int LOCAL_MAP_FILE_NOT_FOUND = 5;
  public static final int LOCAL_MAP_RESERVED_NAME = 6;

  /**
   * Registers, at runtime, a map file that is not a part of the countries tree (for example a custom regional extract).
   * The file {@code <directory>/<mapName>.mwm} must already exist; {@code directory} is the data directory of the
   * current data version, {@code version} is that data version. Routing, search and rendering pick the map up
   * immediately. Must be called on the main thread after the framework is initialized.
   *
   * @return one of the {@code LOCAL_MAP_*} codes.
   */
  public static native int nativeRegisterLocalMap(@NonNull String directory, long version, @NonNull String mapName);

  /**
   * Deregisters a map registered with {@link #nativeRegisterLocalMap(String, long, String)}. The file is deleted from
   * disk once nothing uses it any more. Maps of the countries tree are never touched by this method.
   *
   * @return true if the map was deregistered immediately, false if it is still in use or unknown.
   */
  public static native boolean nativeDeregisterLocalMap(@NonNull String mapName);

  /** Returns true if a map with the given name is registered (and not marked for removal). */
  public static native boolean nativeIsLocalMapRegistered(@NonNull String mapName);

  /** Names of all registered maps that are not a part of the countries tree. */
  public static native @NonNull String[] nativeGetLocalMaps();

  /**
   * Directory in which map files of the given data version live ({@code <writable dir>/<version>}). The directory is
   * not created by this method.
   */
  public static native @NonNull String nativeGetLocalMapsDirectory(long version);

  /**
   * Determines whether something is downloading now.
   */
  public static native boolean nativeIsDownloading();

  /**
   * Enqueues given {@code root} node and its children in downloader.
   */
  private static native void nativeDownload(String root);

  /**
   * Enqueues failed items under given {@code root} node in downloader.
   */
  private static native void nativeRetry(String root);

  /**
   * Enqueues given {@code root} node with its children in downloader.
   */
  private static native void nativeUpdate(String root);

  /**
   * Removes given currently downloading {@code root} node and its children from downloader.
   */
  public static native void nativeCancel(String root);

  /**
   * Deletes given installed {@code root} node with its children.
   */
  public static native void nativeDelete(String root);

  /**
   * Registers {@code callback} of storage status changed. Returns slot ID which should be used to unsubscribe in {@link
   * #nativeUnsubscribe(int)}.
   */
  public static native int nativeSubscribe(StorageCallback callback);

  /**
   * Unregisters storage status changed callback.
   * @param slot Slot ID returned from {@link #nativeSubscribe(StorageCallback)} while registering.
   */
  public static native void nativeUnsubscribe(int slot);

  /**
   * Sets callback about current country change. Single subscriber only.
   */
  public static native void nativeSubscribeOnCountryChanged(CurrentCountryChangedListener listener);

  /**
   * Removes callback about current country change.
   */
  public static native void nativeUnsubscribeOnCountryChanged();

  /**
   * Determines if there are unsaved editor changes present for given {@code root}.
   */
  public static native boolean nativeHasUnsavedEditorChanges(String root);

  /**
   * Fills given {@code result} list with intermediate nodes from the root node (including) to the given {@code root}
   * (excluding). For instance, for {@code root == "Florida"} the resulting list is filled with values: {@code { "United
   * States of America", "Countries" }}.
   */
  public static native void nativeGetPathTo(String root, List<String> result);

  /**
   * Calculates joint progress of downloading countries specified by {@code countries} array.
   * @return 0 to 100 percent.
   */
  public static native int nativeGetOverallProgress(String[] countries);

  /**
   * Returns {@code true} if the core will NOT do attempts to download failed maps anymore.
   */
  public static native boolean nativeIsAutoretryFailed();

  /**
   * Returns {@code true} if the core is allowed to download maps while on 3g network. {@code false} otherwise.
   */
  public static native boolean nativeIsDownloadOn3gEnabled();

  /**
   * Sets flag which allows to download maps on 3G.
   */
  public static native void nativeEnableDownloadOn3g();

  /**
   * Returns country ID which the current PP object points to, or {@code null}.
   */
  public static native @Nullable String nativeGetSelectedCountry();
}
