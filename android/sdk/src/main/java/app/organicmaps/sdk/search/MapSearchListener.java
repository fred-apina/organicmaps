package app.organicmaps.sdk.search;

import androidx.annotation.Keep;
import androidx.annotation.NonNull;

/**
 * Main-thread callbacks from {@link SearchEngine#searchMaps} for downloadable region names.
 */
public interface MapSearchListener
{
  /**
   * A region-name match: {@code countryId} is the native region identifier accepted by the downloader and
   * {@code matchedString} the matching localized name.
   *
   * <p>Called from JNI: the constructor signature must stay (String, String), see SearchEngine.cpp g_mapResultCtor.
   *
   * <p>NOTE: deliberately a plain class, not a Java record. Records in a published AAR require D8 "record desugaring"
   * with global synthetics, which crashes consumer builds using the default Java 11 compileOptions of
   * `flutter create` ("Attempt to create a global synthetic for 'Record desugaring' without a global-synthetics
   * consumer"). Do not convert back to a record.
   */
  @Keep
  @SuppressWarnings("unused")
  final class Result
  {
    private final String countryId;
    private final String matchedString;

    public Result(String countryId, String matchedString)
    {
      this.countryId = countryId;
      this.matchedString = matchedString;
    }

    public String countryId()
    {
      return countryId;
    }

    public String matchedString()
    {
      return matchedString;
    }
  }

  /**
   * Replaces the current matching-region snapshot.
   * @param results current region matches
   * @param timestamp identifier supplied to the request
   * @param isLast whether this is the final snapshot
   */
  @Keep
  @SuppressWarnings("unused")
  void onMapSearchResults(@NonNull Result[] results, long timestamp, boolean isLast);
}
