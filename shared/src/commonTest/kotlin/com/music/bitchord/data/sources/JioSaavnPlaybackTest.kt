package com.music.bitchord.data.sources

import com.music.bitchord.data.model.Song
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import kotlin.test.*

class JioSaavnPlaybackTest {
    private val youtube = object : MusicSource {
        override val configId = "youtube"
        override val kind = SourceKind.YOUTUBE
        override val displayName = "YouTube"
        override suspend fun health(): SourceHealth = error("YouTube must not be asked")
        override suspend fun search(query: String, limit: Int, waitForAll: Boolean, request: StreamRequest?): List<Song> =
            error("YouTube must not be asked")
        override suspend fun stream(trackId: String, request: StreamRequest): SourceStream? =
            error("YouTube must not be asked")
    }
    private fun song(extra: String = "", media: String = "opaque") =
        """{"id":"fixture","title":"Example","more_info":{"duration":"180","encrypted_media_url":"$media"$extra}}"""

    private fun source(
        details: String = """{"songs":[${song()}]}""",
        token: String = """{"status":"success","auth_url":"https://audio.example.test/song.mp4"}""",
        calls: MutableList<Pair<String, Map<String, String>>> = mutableListOf(),
    ) = JioSaavnSource(SourceConfig(kind = SourceKind.JIOSAAVN)) { call, args ->
        calls += call to args
        when (call) {
            "song.getDetails" -> details
            "song.generateAuthToken" -> token
            else -> error("Unexpected provider call: $call")
        }
    }

    @Test fun meteredCeilingIsAppliedToProviderRequest() = runTest {
        val calls = mutableListOf<Pair<String, Map<String, String>>>()
        val stream = source(calls = calls).stream("fixture", StreamRequest.Capped(128))
        assertEquals(96, assertNotNull(stream).format.kbps)
        assertEquals("96", calls.last().second["bitrate"])
    }

    @Test fun advertised320AvailabilityIsRespected() = runTest {
        for (flag in listOf("false", "\"false\"", "0", "\"0\"")) {
            val details = """{"songs":[${song(",\"320kbps\":$flag")}]}"""
            val stream = source(details = details).stream("fixture", StreamRequest.Best)
            assertEquals(160, assertNotNull(stream).format.kbps)
        }
    }

    @Test fun losslessRequestReportsLossyDelivery() = runTest {
        val stream = assertNotNull(source().stream("fixture", StreamRequest.Lossless))
        assertTrue(stream.belowRequest)
        assertEquals(false, stream.format.isLossless)
    }

    @Test fun unsupportedCeilingMakesNoNetworkRequests() = runTest {
        val calls = mutableListOf<Pair<String, Map<String, String>>>()
        assertNull(source(calls = calls).stream("fixture", StreamRequest.Capped(32)))
        assertTrue(calls.isEmpty())
    }

    @Test fun missingMediaDoesNotRequestAuthorization() = runTest {
        val calls = mutableListOf<Pair<String, Map<String, String>>>()
        val details = """{"songs":[${song(media = "")}]}"""
        assertNull(source(details = details, calls = calls).stream("fixture", StreamRequest.Best))
        assertEquals(listOf("song.getDetails"), calls.map { it.first })
    }

    @Test fun providerRefusalIsTerminalEvenWithAnAuthUrl() = runTest {
        val calls = mutableListOf<Pair<String, Map<String, String>>>()
        val token = """{"status":"failure","auth_url":"https://audio.example.test/song.mp4"}"""
        assertNull(source(token = token, calls = calls).stream("fixture", StreamRequest.Best))
        assertEquals(listOf("song.getDetails", "song.generateAuthToken"), calls.map { it.first })
    }

    @Test fun missingAuthUrlDoesNotDecryptOrRetry() = runTest {
        val calls = mutableListOf<Pair<String, Map<String, String>>>()
        assertNull(source(token = """{"status":"success"}""", calls = calls).stream("fixture", StreamRequest.Best))
        assertEquals(listOf("song.getDetails", "song.generateAuthToken"), calls.map { it.first })
    }

    @Test fun onlyUsableHttpsUrlsAreAccepted() = runTest {
        for (url in listOf("http://audio.example.test/song", "file:///song", "https://", "https://user:pass@audio.example.test/song")) {
            assertNull(source(token = """{"auth_url":"$url"}""").stream("fixture", StreamRequest.Best), url)
        }
    }

    @Test fun keyedSongDetailsRemainCompatible() = runTest {
        val stream = source(details = """{"fixture":${song()}}""").stream("fixture", StreamRequest.Best)
        assertNotNull(stream)
        assertEquals(180, stream.durationSec)
    }

    @Test fun unrelatedSongDetailsCannotBecomeTheSelectedTrack() = runTest {
        val calls = mutableListOf<Pair<String, Map<String, String>>>()
        assertNull(source(calls = calls).stream("another-id", StreamRequest.Best))
        assertEquals(listOf("song.getDetails"), calls.map { it.first })
    }

    @Test fun cancellationIsNotReportedAsAnEmptyCatalogue() = runTest {
        val source = JioSaavnSource(SourceConfig(kind = SourceKind.JIOSAAVN)) { _, _ ->
            throw CancellationException("left track")
        }
        assertFailsWith<CancellationException> { source.search("Example", 5, false, null) }
        assertFailsWith<CancellationException> { source.stream("fixture", StreamRequest.Best) }
        assertFailsWith<CancellationException> { source.health() }
    }

    @Test fun tokenCancellationStopsPlaybackResolution() = runTest {
        val source = JioSaavnSource(SourceConfig(kind = SourceKind.JIOSAAVN)) { call, _ ->
            if (call == "song.getDetails") """{"songs":[${song()}]}"""
            else throw CancellationException("left track")
        }
        assertFailsWith<CancellationException> { source.stream("fixture", StreamRequest.Best) }
    }

    @Test fun directChoiceUsesProviderIdAndNeverYouTube() = runTest {
        val calls = mutableListOf<Pair<String, Map<String, String>>>()
        val provider = source(calls = calls)
        val stream = DirectSourcePlayback.jioSaavn(listOf(youtube, provider), "saavn:fixture", StreamRequest.Capped(128))
        assertNotNull(stream)
        assertEquals("fixture", calls.first().second["pids"])
        assertEquals("96", calls.last().second["bitrate"])
    }

    @Test fun disabledProviderAndEmptyIdDoNotResolve() = runTest {
        assertNull(DirectSourcePlayback.jioSaavn(listOf(youtube), "fixture", StreamRequest.Best))
        val calls = mutableListOf<Pair<String, Map<String, String>>>()
        assertNull(DirectSourcePlayback.jioSaavn(listOf(source(calls = calls)), "saavn: ", StreamRequest.Best))
        assertTrue(calls.isEmpty())
    }
}
