package com.music.bitchord.data.sources

import com.music.bitchord.data.http.Http
import com.music.bitchord.data.model.Song
import io.ktor.http.Url
import io.ktor.http.URLProtocol
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull

/**
 * Port of upstream `data/sources/JioSaavnSource.kt`.
 *
 * ## Why this source is off by default
 *
 * Upstream seeds it disabled and makes every install opt in once, because JioSaavn's
 * catalogue matching can select the wrong recording. That is not a hedge: a search
 * is matched on title and artist against a catalogue with no ISRC, so a live
 * remix, a cover or a sped-up edit comes back as a confident wrong answer, and the
 * listener hears it as the app playing the wrong song. [SourceRegistry]'s one-shot
 * migration forces the choice to be made rather than inherited, so nobody ends up
 * with a source silently substituting recordings.
 *
 * Nothing here needs a platform: the catalogue is JioSaavn's own HTTP API and the
 * stream is served from its CDN.
 */
class JioSaavnSource internal constructor(
    override val config: SourceConfig,
    private val transport: (suspend (String, Map<String, String>) -> String)?,
) : MusicSource, ConfigBacked {
    constructor(config: SourceConfig) : this(config, null)

    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    override val configId: String get() = config.id
    override val kind: SourceKind get() = config.kind
    override val displayName: String get() = config.kind.label

    /**
     * Reachable, and serving rows.
     *
     * The check is a real search rather than a ping: there is no dedicated
     * endpoint, and a server that answers a search is the only thing actually
     * being relied on.
     */
    override suspend fun health(): SourceHealth = try {
        searchRows(HEALTH_QUERY, 1)
        SourceHealth.Ok("Catalogue reachable; playback availability is checked per track")
    } catch (e: CancellationException) { throw e }
    catch (_: Exception) { SourceHealth.Unreachable("Catalogue unavailable") }

    /**
     * Rows for [query], explicit versions first.
     *
     * Explicit-first is upstream's rule, and it is about the wrong-recording problem
     * rather than about taste: a clean and an explicit version of the same title are
     * two different masters, and the one a listener means is more often the
     * explicit one.
     */
    override suspend fun search(
        query: String,
        limit: Int,
        waitForAll: Boolean,
        request: StreamRequest?,
    ): List<Song> {
        val trimmed = query.trim()
        if (trimmed.isEmpty()) return emptyList()
        val rows = try { searchRows(trimmed, limit.coerceAtLeast(MIN_FETCH)) }
        catch (e: CancellationException) { throw e }
        catch (_: Exception) { return emptyList() }
        return rows
            .sortedWith(
                compareByDescending<JioSaavnRow> { it.explicit }
                    .thenByDescending { it.durationSec ?: 0 }
            )
            .take(limit)
            .map { it.toSong(config.id) }
    }

    /**
     * A stream for one of JioSaavn's own song ids.
     *
     * The best available rendition, capped by [request] when the caller named a
     * ceiling. The 96 and 48kbps links exist for a metered connection, and taking
     * one when nothing better is offered is a track that plays rather than one that
     * does not.
     */
    override suspend fun stream(trackId: String, request: StreamRequest): SourceStream? {
        val cap = request.kbpsCeiling
        if (cap != null && cap < 48) return null
        val song = try { fetchSong(trackId) }
        catch (e: CancellationException) { throw e }
        catch (_: Exception) { return null } ?: return null
        val bitrate = listOf(320, 160, 96, 48).firstOrNull {
            (cap == null || it <= cap) && (it != 320 || song.has320 != false)
        } ?: return null
        val encrypted = song.encryptedMediaUrl ?: return null
        val response = api("song.generateAuthToken", mapOf("url" to encrypted, "bitrate" to bitrate.toString()))
        val token = response as? JsonObject ?: return null
        // A refusal is terminal. Do not decrypt the opaque value locally, invent
        // CDN filenames, or keep requesting tokens at other qualities after it.
        if (token.str("status")?.lowercase()?.let { it != "success" } == true) return null
        val url = token.str("auth_url")?.takeIf { raw ->
            raw.startsWith("https://", ignoreCase = true) &&
                raw.drop(8).takeWhile { it !in "/?#" }.isNotBlank() &&
                raw.none { it.isWhitespace() || it == '\\' } &&
                runCatching { Url(raw) }.getOrNull()?.let {
                    it.protocol == URLProtocol.HTTPS && it.host.isNotBlank() &&
                        it.user == null && it.password == null
                } == true
        } ?: return null
        return SourceStream(
            url = url,
            // JioSaavn serves AAC in an MP4 container, so the container is what
            // actually matters to the engine and to the extension a download writes.
            format = StreamFormat(codec = "aac", kbps = bitrate),
            belowRequest = request is StreamRequest.Lossless,
            durationSec = song.durationSec,
            sourceConfigId = config.id,
        )
    }

    // ── Transport ─────────────────────────────────────────────────────────

    private suspend fun api(call: String, args: Map<String, String>): JsonElement {
        val body = transport?.invoke(call, args) ?: Http.getText(
            url = API,
            query = mapOf("__call" to call, "_format" to "json", "_marker" to "0",
                "api_version" to "4", "ctx" to "android") + args,
            headers = mapOf("Accept" to "application/json", "User-Agent" to "Mozilla/5.0"),
            timeoutMillis = 12_000,
        )
        return json.parseToJsonElement(body)
    }

    private suspend fun searchRows(query: String, limit: Int): List<JioSaavnRow> =
        parseSongs(api("search.getResults", mapOf("q" to query, "n" to limit.toString(), "p" to "1")))

    private suspend fun fetchSong(trackId: String): JioSaavnRow? {
        val root = api("song.getDetails", mapOf("pids" to trackId)) as? JsonObject ?: return null
        val songs = (root["songs"] as? JsonArray)?.filterIsInstance<JsonObject>()
            ?: root.values.filterIsInstance<JsonObject>()
        return songs.firstOrNull { it.str("id") == trackId }?.toRow()
    }

    /**
     * Songs out of a search envelope.
     *
     * Two shapes, because the API answers with one or the other depending on
     * whether a query matched anything: a `{results: [...]}` object, or a bare
     * array. A shape this has never seen reads as empty rather than throwing — a
     * catalogue changing its envelope is not a reason for a track to fail to play.
     */
    private fun parseSongs(root: JsonElement): List<JioSaavnRow> {
        val elements = when (root) {
            is JsonArray -> root
            is JsonObject -> (root["results"] as? JsonArray) ?: (root["data"] as? JsonArray) ?: emptyList()
            else -> emptyList()
        }
        return elements.mapNotNull { (it as? JsonObject)?.toRow() }
    }

    private fun JsonObject.toRow(): JioSaavnRow? {
        val id = str("id") ?: return null
        val name = str("title") ?: return null
        val info = get("more_info") as? JsonObject ?: return null
        val artists = ((info["artistMap"] as? JsonObject)?.get("primary_artists")).asStringList("name")
        val album = info.str("album")
        val year = str("year")?.toIntOrNull()
        val explicit = str("explicit_content") == "1"
        val durationSec = info.str("duration")?.toIntOrNull()
        val artwork = str("image")?.replace("150x150", "500x500")?.replace("http://", "https://")
        return JioSaavnRow(
            id = id,
            name = name,
            artist = artists.joinToString(", ").ifBlank { null },
            album = album,
            year = year,
            explicit = explicit,
            durationSec = durationSec,
            artworkUrl = artwork,
            encryptedMediaUrl = info.str("encrypted_media_url"),
            has320 = info.bool("320kbps"),
        )
    }

    private fun JsonObject.str(key: String): String? =
        (get(key) as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotBlank() }

    private fun JsonObject.bool(key: String): Boolean? =
        (get(key) as? JsonPrimitive)?.let {
            it.booleanOrNull ?: when (it.contentOrNull?.lowercase()) {
                "true", "1" -> true
                "false", "0" -> false
                else -> null
            }
        }

    private fun JsonElement?.asStringList(key: String): List<String> =
        (this as? JsonArray)?.mapNotNull { entry ->
            when (entry) {
                is JsonObject -> entry.str(key)
                is JsonPrimitive -> entry.contentOrNull
                else -> null
            }
        }.orEmpty()

    private companion object {
        const val API = "https://www.jiosaavn.com/api.php"
        /** An ordinary word: a nonsense probe that always comes back empty proves less. */
        const val HEALTH_QUERY = "music"
        /** The API has no limit parameter worth trusting, so ask for room to rank. */
        const val MIN_FETCH = 25
    }
}

/** One JioSaavn result, decoded. */
internal data class JioSaavnRow(
    val id: String,
    val name: String,
    val artist: String?,
    val album: String?,
    val year: Int?,
    val explicit: Boolean,
    val durationSec: Int?,
    val artworkUrl: String?,
    val encryptedMediaUrl: String? = null,
    val has320: Boolean? = null,
) {
    fun toSong(configId: String): Song = Song(
        // The identity is the route back to this source, packed into the one field
        // the whole app already treats as the media id.
        videoId = SourceRegistry.trackKey(configId, id),
        title = name,
        artist = artist.orEmpty(),
        thumbnailUrl = artworkUrl,
        durationText = mmss(durationSec),
        albumName = album,
        // Bounded by the source rather than the row: JioSaavn tops out at lossy
        // 320kbps AAC, so the resolver's ranking does not need to know that.
        sourceQuality = "AAC",
    )
}
