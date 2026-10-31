package dev.tachyon.tachyon_client

import android.content.Context
import android.os.Build
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.security.MessageDigest

data class CoreExecutable(val file: File, val version: String, val id: String = "bundled") {
    fun command(vararg arguments: String): List<String> =
        (if (id == "bundled") listOf(file.absolutePath) else listOf("/system/bin/linker64", file.absolutePath)) + arguments

    companion object {
        fun bundled(context: Context): CoreExecutable {
            val manifest = JSONObject(context.assets.open("core-manifest.json").bufferedReader().use { it.readText() })
            return CoreExecutable(File(context.applicationInfo.nativeLibraryDir, "libtachyon.so"), manifest.getString("version"))
        }

        fun architecture(): String = when (Build.SUPPORTED_ABIS.firstOrNull()) {
            "arm64-v8a" -> "aarch64"
            "x86_64" -> "x86_64"
            else -> error("Обновление поддерживает только ARM64 и x86_64.")
        }

        fun sha256(file: File): String {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val buffer = ByteArray(65536)
                while (true) {
                    val size = input.read(buffer)
                    if (size < 0) break
                    digest.update(buffer, 0, size)
                }
            }
            return digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
        }

        fun validate(file: File) {
            require(file.length() in 64..(128L * 1024 * 1024)) { "Неверный размер бинарника ядра." }
            RandomAccessFile(file, "r").use { elf ->
                fun u16(): Int = java.lang.Short.reverseBytes(elf.readShort()).toInt() and 65535
                fun u32(): Long = java.lang.Integer.reverseBytes(elf.readInt()).toLong() and 0xffffffffL
                fun u64(): Long = java.lang.Long.reverseBytes(elf.readLong())
                val magic = ByteArray(6).also { elf.readFully(it) }
                require(magic.contentEquals(byteArrayOf(127, 69, 76, 70, 2, 1))) { "Нужен ELF64 для Android." }
                elf.seek(16)
                require(u16() == 3 && u16() == if (architecture() == "aarch64") 183 else 62) { "Архитектура Android-ядра не совпадает." }
                elf.seek(32); val table = u64()
                elf.seek(54); val stride = u16(); val count = u16()
                require(stride == 56 && count in 1..1024 && table >= 64 && table <= elf.length() - count * 56) { "Повреждены заголовки ELF." }
                var loaders = 0; var loads = 0
                repeat(count) { index ->
                    elf.seek(table + index * 56)
                    val type = u32(); u32()
                    val offset = u64(); val address = u64(); u64()
                    val size = u64(); u64(); val alignment = u64()
                    require(offset >= 0 && size >= 0 && offset <= elf.length() - size) { "Повреждён сегмент ELF." }
                    if (type == 3L) {
                        require(size == 21L) { "Неверный загрузчик Android." }
                        elf.seek(offset)
                        require(ByteArray(size.toInt()).also { elf.readFully(it) }.contentEquals("/system/bin/linker64\u0000".toByteArray())) { "Нужна Android/Bionic-сборка ядра." }
                        loaders++
                    }
                    if (type == 1L) {
                        require(alignment >= 16384 && alignment and (alignment - 1) == 0L && offset % 16384 == address % 16384) { "Ядро не поддерживает страницы 16 КБ." }
                        loads++
                    }
                }
                require(loaders == 1 && loads > 0) { "Нужен исполняемый Android PIE." }
            }
        }
    }
}
