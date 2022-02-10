package com.jhomlala.better_player

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log

import androidx.annotation.NonNull
import androidx.annotation.Nullable

import com.google.android.exoplayer2.DefaultRenderersFactory
import com.google.android.exoplayer2.Format
import com.google.android.exoplayer2.MediaItem
import com.google.android.exoplayer2.database.ExoDatabaseProvider
import com.google.android.exoplayer2.drm.DrmSession
import com.google.android.exoplayer2.drm.DrmSessionEventListener
import com.google.android.exoplayer2.drm.OfflineLicenseHelper
import com.google.android.exoplayer2.offline.Download
import com.google.android.exoplayer2.offline.DownloadCursor
import com.google.android.exoplayer2.offline.DownloadHelper
import com.google.android.exoplayer2.offline.DownloadManager
import com.google.android.exoplayer2.offline.DownloadRequest
import com.google.android.exoplayer2.offline.DownloadService
import com.google.android.exoplayer2.source.TrackGroup
import com.google.android.exoplayer2.source.TrackGroupArray
import com.google.android.exoplayer2.trackselection.MappingTrackSelector
import com.google.android.exoplayer2.upstream.DefaultDataSourceFactory
import com.google.android.exoplayer2.upstream.DefaultHttpDataSource
import com.google.android.exoplayer2.upstream.cache.Cache
import com.google.android.exoplayer2.upstream.cache.NoOpCacheEvictor
import com.google.android.exoplayer2.upstream.cache.SimpleCache
import com.google.android.exoplayer2.util.Assertions
import com.google.android.exoplayer2.util.Util

import java.io.File
import java.io.IOException
import java.util.HashMap
import java.util.LinkedList
import java.util.List
import java.util.Map
import java.util.Timer
import java.util.TimerTask

import io.flutter.plugin.common.EventChannel

object BetterPlayerDownloadHelper {
    private const val DOWNLOAD_FOLDER_NAME = "downloads"
    private const val TAG = "BetterPlayerDownloader"

    private var downloadManager: DownloadManager? = null
    private var downloadCache: Cache? = null
    private var databaseProvider: ExoDatabaseProvider? = null

    @JvmStatic
    @Synchronized
    fun getDownloadManager(context: Context): DownloadManager {
        if (downloadManager == null) {
            downloadManager = DownloadManager(
                context,
                getDatabaseProvider(context),
                getDownloadCache(context),
                DefaultHttpDataSource.Factory(),
                Runnable::run
            )
            // TODO: make configurable?
            downloadManager!!.setMaxParallelDownloads(3)
        }

        return downloadManager!!
    }

    @JvmStatic
    @Synchronized
    fun getDownloadCache(context: Context): Cache {
        if (downloadCache == null) {
            downloadCache = SimpleCache(
                File(context.getFilesDir(), DOWNLOAD_FOLDER_NAME),
                NoOpCacheEvictor(),
                getDatabaseProvider(context)
            )
        }

        return downloadCache!!
    }

    @JvmStatic
    @Synchronized
    fun getDatabaseProvider(context: Context): ExoDatabaseProvider {
        if (databaseProvider == null) {
            databaseProvider = ExoDatabaseProvider(context)
        }

        return databaseProvider!!
    }

    @JvmStatic
    fun removeDownload(context: Context, url: String) {
        DownloadService.sendRemoveDownload(
            context,
            BetterPlayerDownloadService::class.java,
            url,
            false
        )
    }

    @JvmStatic
    fun getDownload(context: Context, url: String): Download? {
        try {
            return getDownloadManager(context)
                .getDownloadIndex()
                .getDownload(url)
        } catch (e: IOException) {
            return null
        }
    }

    @JvmStatic
    @Throws(IOException::class)
    fun listDownloads(context: Context): MutableList<Download> {
        var downloads = LinkedList<Download>()

        val downloadCursor = getDownloadManager(context).getDownloadIndex().getDownloads()
        if (downloadCursor.moveToFirst()) {
            do {
                downloads.add(downloadCursor.getDownload())
            } while (downloadCursor.moveToNext())
        }

        return downloads
    }

    @JvmStatic
    fun addDownload(
        context: Context,
        mediaItem: MediaItem,
        eventSink: EventChannel.EventSink,
        downloadData: String,
        onDone: Runnable?
    ) {
        var downloadHelper = DownloadHelper.forMediaItem(
            context,
            mediaItem,
            DefaultRenderersFactory(context),
            // TODO: probably want to use DataSourceUtils.getDataSourceFactory?
            DefaultDataSourceFactory(context)
        )

        downloadHelper.prepare(object : DownloadHelper.Callback {
            override fun onPrepared(helper: DownloadHelper) {
                val playbackProperties = mediaItem.playbackProperties!!
                val url = playbackProperties.uri.toString()
                var licenseUrl: String? = null
                var drmHeaders: MutableMap<String, String> = HashMap<String, String>()
                playbackProperties.drmConfiguration?.also { drmConfiguration ->
                    drmHeaders = drmConfiguration.requestHeaders
                    if (drmConfiguration.licenseUri != null) {
                        licenseUrl = drmConfiguration.licenseUri.toString()
                    }
                }

                var downloadRequest =
                    helper.getDownloadRequest(url, Util.getUtf8Bytes(downloadData))

                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.JELLY_BEAN_MR2) {
                    Log.e(TAG, "Protected content not supported on API levels below 18")
                } else if (licenseUrl != null) {
                    val offlineLicenseHelper = OfflineLicenseHelper.newWidevineInstance(
                        licenseUrl!!,
                        false,
                        DefaultHttpDataSource.Factory().setDefaultRequestProperties(drmHeaders),
                        drmHeaders,
                        DrmSessionEventListener.EventDispatcher()
                    );

                    for (periodIndex in 0 until helper.getPeriodCount()) {
                        val mappedTrackInfo = helper.getMappedTrackInfo(periodIndex)
                        for (rendererIndex in 0 until mappedTrackInfo.getRendererCount()) {
                            val trackGroups = mappedTrackInfo.getTrackGroups(rendererIndex)
                            for (trackGroupIndex in 0 until trackGroups.length) {
                                val trackGroup = trackGroups.get(trackGroupIndex)
                                for (formatIndex in 0 until trackGroup.length) {
                                    val format = trackGroup.getFormat(formatIndex)
                                    if (format.drmInitData != null) {
                                        try {
                                            val keySetId =
                                                offlineLicenseHelper.downloadLicense(format)
                                            downloadRequest =
                                                downloadRequest.copyWithKeySetId(keySetId)
                                        } catch (e: DrmSession.DrmSessionException) {
                                            Log.e(TAG, "Failed to fetch offline license")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                DownloadService.sendAddDownload(
                    context,
                    BetterPlayerDownloadService::class.java,
                    downloadRequest,
                    false
                )

                val handler = Handler(Looper.getMainLooper())

                val timer = Timer()
                timer.schedule(object : TimerTask() {
                    override fun run() {
                        // getCurrentDownloads is used because it stores much more accurate progress
                        // percentage
                        val downloads = getDownloadManager(context).getCurrentDownloads()
                        var download: Download? = null
                        for (d in downloads) {
                            if (d.request.id.equals(url)) {
                                download = d
                                break
                            }
                        }
                        if (download == null)
                            return

                        val progress = download.getPercentDownloaded()
                        handler.post({ eventSink.success(progress) })
                    }
                }, 0, 1000)

                getDownloadManager(context).addListener(object : DownloadManager.Listener {
                    override fun onDownloadRemoved(
                        downloadManager: DownloadManager,
                        download: Download
                    ) {
                        if (download.request.id.equals(url)) {
                            getDownloadManager(context).removeListener(this)
                            eventSink.success(download.getPercentDownloaded())
                            eventSink.endOfStream()
                        }
                    }

                    override fun onDownloadChanged(
                        downloadManager: DownloadManager,
                        download: Download,
                        finalException: Exception?
                    ) {
                        if (download.request.id.equals(url) && download.state == Download.STATE_COMPLETED) {
                            getDownloadManager(context).removeListener(this)
                            timer.cancel()
                            eventSink.success(100f)
                            eventSink.endOfStream()
                        }
                    }
                })


                if (onDone != null) {
                    onDone.run()
                }
            }

            override fun onPrepareError(helper: DownloadHelper, e: IOException) {
                // TODO: inform about better_player about failure
                Log.e(TAG, "Failed prepare");
            }
        })
    }
}
