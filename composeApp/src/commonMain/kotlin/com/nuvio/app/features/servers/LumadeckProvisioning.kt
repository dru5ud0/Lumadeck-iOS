package com.nuvio.app.features.servers

/**
 * Applies the private LumaDeck defaults bundled next to the app binary.
 *
 * The defaults file is injected into the unsigned IPA for the personal build and
 * is deliberately kept out of source control. When it is absent (normal CI
 * builds, App Store builds, Android) provisioning is a no-op.
 */
internal expect suspend fun ensureLumadeckProvisioned()
