package com.jhomlala.better_player

import android.net.Uri
import com.google.android.exoplayer2.upstream.DataSource
import com.jhomlala.better_player.DataSourceUtils
import com.google.android.exoplayer2.upstream.DefaultHttpDataSource
import com.google.android.exoplayer2.util.Util
import com.google.android.exoplayer2.C

internal object DataSourceUtils {
    private const val USER_AGENT = "User-Agent"
    private const val USER_AGENT_PROPERTY = "http.agent"
    private const val FORMAT_SS = "ss"
    private const val FORMAT_DASH = "dash"
    private const val FORMAT_HLS = "hls"
    private const val FORMAT_OTHER = "other"

    @JvmStatic
    fun getUserAgent(headers: Map<String, String>?): String {
        var userAgent = System.getProperty(USER_AGENT_PROPERTY)
        if (headers != null && headers.containsKey(USER_AGENT)) {
            val userAgentHeader = headers[USER_AGENT]
            if (userAgentHeader != null) {
                userAgent = userAgentHeader
            }
        }
        return userAgent
    }

    @JvmStatic
    fun getDataSourceFactory(
        userAgent: String?,
        headers: Map<String, String>?
    ): DataSource.Factory {
        val dataSourceFactory: DataSource.Factory = DefaultHttpDataSource.Factory()
            .setUserAgent(userAgent)
            .setAllowCrossProtocolRedirects(true)
            .setConnectTimeoutMs(DefaultHttpDataSource.DEFAULT_CONNECT_TIMEOUT_MILLIS)
            .setReadTimeoutMs(DefaultHttpDataSource.DEFAULT_READ_TIMEOUT_MILLIS)
        if (headers != null) {
            val notNullHeaders = mutableMapOf<String, String>()
            headers.forEach { entry ->
                if (entry.key != null && entry.value != null) {
                    notNullHeaders[entry.key!!] = entry.value!!
                }
            }
            (dataSourceFactory as DefaultHttpDataSource.Factory).setDefaultRequestProperties(
                notNullHeaders
            )
        }
        return dataSourceFactory
    }

    @JvmStatic
    fun isHTTP(uri: Uri?): Boolean {
        if (uri == null || uri.scheme == null) {
            return false
        }
        val scheme = uri.scheme
        return scheme == "http" || scheme == "https"
    }

    @JvmStatic
    fun getContentType(uri: Uri, formatHint: String?): Int {
        if (formatHint == null) {
            var lastPathSegment = uri.getLastPathSegment()
            if (lastPathSegment == null) {
                lastPathSegment = ""
            }
            return Util.inferContentType(lastPathSegment)
        }

        return when (formatHint) {
            FORMAT_SS -> C.TYPE_SS
            FORMAT_DASH -> C.TYPE_DASH
            FORMAT_HLS -> C.TYPE_HLS
            FORMAT_OTHER -> C.TYPE_OTHER
            else -> -1
        }
    }

    @JvmStatic
    fun getContentType(url: String, formatHint: String?): Int {
        return getContentType(Uri.parse(url), formatHint)
    }
}
