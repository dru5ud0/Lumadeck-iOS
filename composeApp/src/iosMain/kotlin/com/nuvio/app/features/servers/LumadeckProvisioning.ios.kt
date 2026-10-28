package com.nuvio.app.features.servers

import co.touchlab.kermit.Logger
import com.nuvio.app.features.profiles.ProfileRepository
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import platform.Foundation.NSBundle
import platform.Foundation.NSString
import platform.Foundation.NSUTF8StringEncoding
import platform.Foundation.NSUserDefaults
import platform.Foundation.stringWithContentsOfFile

private val log = Logger.withTag("LumadeckProvisioning")
private val json = Json { ignoreUnknownKeys = true }

@OptIn(ExperimentalForeignApi::class)
internal actual suspend fun ensureLumadeckProvisioned() {
    val path = NSBundle.mainBundle.pathForResource("LumadeckDefaults", ofType = "json") ?: return
    val text = NSString.stringWithContentsOfFile(path, NSUTF8StringEncoding, null) ?: return
    val server = runCatching {
        json.parseToJsonElement(text).jsonObject["server"]?.jsonObject
    }.getOrNull() ?: return

    val providerId = server.string("provider") ?: "jellyfin"
    val address = server.string("address") ?: return
    val username = server.string("username") ?: return
    val password = server.string("password") ?: return
    val provider = ServerProviders.forId(providerId) ?: return

    ServerRepository.ensureLoaded()
    val profileId = ProfileRepository.activeProfileId
    val defaults = NSUserDefaults.standardUserDefaults
    val marker = "lumadeck.provisioned.$profileId"
    if (defaults.boolForKey(marker)) return

    val alreadyConfigured = ServerRepository.uiState.value.connections.any { connection ->
        connection.providerId == provider.id && connection.address.normalizedAddress() == address.normalizedAddress()
    }
    if (alreadyConfigured) {
        defaults.setBool(true, forKey = marker)
        return
    }

    try {
        ServerRepository.connect(provider, address, username, password)
        defaults.setBool(true, forKey = marker)
        log.i { "Provisioned ${provider.id} server for profile $profileId" }
    } catch (error: CancellationException) {
        throw error
    } catch (error: Exception) {
        log.w(error) { "Provisioning ${provider.id} server failed for profile $profileId" }
    }
}

private fun JsonObject.string(key: String): String? =
    (this[key] as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotBlank() }

private fun String.normalizedAddress(): String = trim().trimEnd('/').lowercase()
