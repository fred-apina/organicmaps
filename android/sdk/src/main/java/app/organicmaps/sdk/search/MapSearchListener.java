package app.organicmaps.sdk.search;

import androidx.annotation.Keep;
import androidx.annotation.NonNull;

public interface MapSearchListener
{
  // Called from JNI (constructor signature must stay (String, String) — see
  // SearchEngine.cpp g_mapResultCtor).
  //
  // NOTE: deliberately a plain class, not a Java record. Records in a published
  // AAR require D8 "record desugaring" with global synthetics, which crashes
  // consumer builds using the default Java 11 compileOptions of `flutter create`
  // ("Attempt to create a global synthetic for 'Record desugaring' without a
  // global-synthetics consumer"). Do not convert back to a record.
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

  // Called from JNI.
  @Keep
  @SuppressWarnings("unused")
  void onMapSearchResults(@NonNull Result[] results, long timestamp, boolean isLast);
}
