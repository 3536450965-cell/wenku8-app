package org.mewx.wenku8_flutter

// The public snapshot ships the plugin that talks to Flutter but not the
// pieces it delegates to: the SAF folder scanner and the archive/document
// converters. They are reconstructed here as compiling placeholders so the
// release apk builds; every entry point reports "unsupported" instead of
// pretending to work, and the Wenku8 downloads (plain file import) never touch
// these paths.

import android.app.Activity
import android.net.Uri
import java.io.File

internal class BookFolderScanner(private val activity: Activity) {
    fun canReadAll(): Boolean = false

    fun selectAll() = Unit

    fun info(): Map<String, Any?>? = null

    fun setAutomatic(value: Boolean) = Unit

    fun disconnect() = Unit

    fun scan(): Map<String, Any?> = mapOf(
        "books" to emptyList<Any>(),
        "total" to 0,
        "unchanged" to 0,
        "warnings" to emptyList<String>(),
    )

    fun formats(): Set<String> = emptySet()

    fun setFormats(extensions: List<String>) = Unit

    fun stage(token: String, root: File, copy: (Uri, File, Long) -> Unit): Any =
        throw IllegalStateException("这个构建不支持扫描文件夹，请用「导入」选择文件。")

    fun link(token: String, links: BookTextLinks, root: File, copy: (Uri, File, Long) -> Unit): Any =
        throw IllegalStateException("这个构建不支持扫描文件夹，请用「导入」选择文件。")

    fun markImported(token: String) = Unit

    fun finish() = Unit

    fun select(uri: Uri, flags: Int) = Unit
}

internal class BookMarkupImport(private val root: File, private val read: (File) -> ByteArray) {
    fun prepare(name: String, source: BookDocumentInput): Any =
        throw IllegalStateException("这个构建不支持转换 $name。")

    fun documents(): Any = throw IllegalStateException("这个构建不支持转换文档。")
}

internal class BookPdfImport(private val activity: Activity, private val root: File) {
    fun read(file: File): ByteArray = throw IllegalStateException("这个构建不支持 PDF。")
}

internal class BookArchiveImport(private val root: File) {
    var documents: BookMarkupImport? = null

    fun prepare(name: String, source: BookDocumentInput): Any =
        throw IllegalStateException("这个构建不支持转换 $name。")

    fun prepare(name: String, source: File): Any =
        throw IllegalStateException("这个构建不支持转换 $name。")

    companion object {
        const val MAX_ARCHIVE: Long = 512L * 1024 * 1024

        fun supported(name: String): Boolean = false

        fun limit(name: String): Long = MAX_ARCHIVE
    }
}