# Owlink's committed update settings (Sparkle 2, docs/updates.md), read by
# Scripts/bundle-app.sh (baked into Info.plist) and Scripts/release.sh
# (checked against the built app). Sourced, not run.
#
# Both values are public: the feed is where every installed copy looks for
# updates, and the key is the EdDSA PUBLIC key (base64, 32 bytes) whose
# private half signs the feed and every update. The private key is never in
# the repository. CEDRIC_SPARKLE_FEED_URL / CEDRIC_SPARKLE_PUBLIC_KEY, when
# set and not empty, override these (a test build, or a future key
# rotation); unset, a build gets these.
OWLINK_SPARKLE_FEED_URL=https://owlink.app/appcast.xml
OWLINK_SPARKLE_PUBLIC_KEY=hrWeLLjfQFt7O50s1x4JepXV7dXLmpEztAuhe1XcsQs=
