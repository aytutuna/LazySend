package com.lazysend.lazysend.data

import android.content.Context
import com.lazysend.lazysend.transfer.PhotoFormat
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** What the person chose in the app: where camera photos go besides the other device, and who they go to. */
class AppSettings(context: Context) {
    private val prefs = context.getSharedPreferences("settings", Context.MODE_PRIVATE)
    private val camera = MutableStateFlow(prefs.getBoolean(SAVE_CAMERA, false))

    val saveCameraPhotos: StateFlow<Boolean> get() = camera

    fun saveCameraPhotos(on: Boolean) {
        camera.value = on
        prefs.edit().putBoolean(SAVE_CAMERA, on).apply()
    }

    private val format = MutableStateFlow(runCatching { PhotoFormat.valueOf(prefs.getString(FORMAT, null)!!) }.getOrDefault(PhotoFormat.Jpeg))

    /** What camera shots and picked photos are sent as. */
    val photoFormat: StateFlow<PhotoFormat> get() = format

    fun photoFormat(value: PhotoFormat) {
        format.value = value
        prefs.edit().putString(FORMAT, value.name).apply()
    }

    /** The id of the device the camera and clipboard send to. */
    var target: String?
        get() = prefs.getString(TARGET, null)
        set(id) = prefs.edit().putString(TARGET, id).apply()

    private companion object {
        const val SAVE_CAMERA = "saveCameraPhotos"
        const val TARGET = "target"
        const val FORMAT = "photoFormat"
    }
}
