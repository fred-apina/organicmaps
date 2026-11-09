#pragma once

#define OSM_CONSUMER_KEY "zz16eUusTr4TcVhoKQrgOJaRzZAeI2ktbVx6e3yn"
#define OSM_CONSUMER_SECRET "7g4XrlhFkiOG1I3Zpqh8ajo94P9cNNXaU2YCMgL7"
#define OSM_OAUTH2_CLIENT_ID "3iB16A21eY8HvxJpPbdih94Us1Po5NfqoWHaZaaCd50"
#define OSM_OAUTH2_CLIENT_SECRET "AKyf1iUliVQ6CWJWQV7NQcx2T1Icr013k5sb7JSK4eU"
#define OSM_OAUTH2_REDIRECT_URI "om://oauth2/osm/callback"
#define OSM_OAUTH2_SCOPE "read_prefs write_api write_notes"
#define MWM_GEOLOCATION_SERVER ""
// No meta server on purpose. The one upstream names answers with a bare JSON array that this engine's parser rejects,
// so every download fell back to DEFAULT_URLS_JSON below. When that list had dead mirrors in it, each download request
// lost them first and any later hiccup on the last live server failed the whole file. The list below is the mirrors
// that serve the current data version (checked 2026-11-09: HTTP 206 on range requests for World, WorldCoasts and
// country files on every one). Re-check this list when a data version changes.
#define METASERVER_URL ""
#define DIFF_LIST_URL ""
#define DEFAULT_URLS_JSON \
  R"({"servers":["https://cdn.organicmaps.app/","https://cdn-us1.organicmaps.app/","https://cdn-fi3.organicmaps.app/","https://cdn-de2.organicmaps.app/","https://cdn-de3.organicmaps.app/"]})"
#define DEFAULT_CONNECTION_CHECK_IP "162.55.100.169"  // For now the IP of cdn.organicmaps.app
#define TRAFFIC_DATA_BASE_URL ""
#define USER_BINDING_PKCS12 ""
#define USER_BINDING_PKCS12_PASSWORD ""
#define KAYAK_AFFILIATE_ID "kan_267335"
