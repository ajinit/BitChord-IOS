package com.music.bitchord.data.sources

/** Explicit catalogue choices never require a YouTube reference or fall back to YouTube. */
internal object DirectSourcePlayback {
    suspend fun jioSaavn(
        active: List<MusicSource>, trackId: String, request: StreamRequest,
    ): SourceStream? {
        val id = trackId.removePrefix("saavn:").trim()
        if (id.isEmpty()) return null
        val source = active.firstOrNull { it.kind == SourceKind.JIOSAAVN } ?: return null
        return source.stream(id, request)
    }
}
