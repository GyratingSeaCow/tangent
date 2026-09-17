// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.tangent.tangent.storage

import java.net.URLEncoder

/** Disposable provider primitives only; all ownership policy lives in production. */
class CapturePublicationFixture : CaptureDocumentsPort {
    data class Document(var node:NativeNode,var bytes:ByteArray=byteArrayOf())
    val directory=NativeDirectory("capture.fixture","content://capture.fixture/tree/primary%3Aroot","primary:root")
    val documents=linkedMapOf<String,Document>()
    var source=byteArrayOf(1,2,3)
    var sourceIdentity:Map<String,Any?> = mapOf("version" to 1,"kind" to "posix-file","scope" to "8:1","objectId" to "18446744073709551615","generation" to null)
    var loading=false
    var queryError:String?=null
    var denied=false
    var failAfterReturn=false
    var renamed=false
    var returnedExisting:String?=null
    var writeFailureName:String?=null
    var partialWrite=false
    var descriptorError:String?=null
    var denyWritable=false
    var onReturn:((String)->Unit)?=null
    var onInitialize:(()->Unit)?=null
    var flushFailureName:String?=null
    var corruptWriteName:String?=null
    var creates=0; var writes=0; var deletes=0; var renames=0; var opens=0
    private var sequence=0
    private fun access() { if(denied) throw SecurityException("fixture denied") }
    val key=mapOf("version" to 1,"dumpId" to "fixture-dump","incarnation" to "fixture-owner")
    val location=mapOf("version" to 1,"id" to "fixture-location","label" to "fixture root","directory" to mapOf("version" to 1,"kind" to "saf","path" to "","authority" to directory.authority,"treeUri" to directory.treeUri,"documentId" to directory.documentId))
    val reservation=mapOf("version" to 1,"id" to "fixture-reservation","key" to key,"location" to location,"stagingPath" to "/fixture/fixture-reservation.opus","mode" to "meeting","startedAtMs" to 1893553445123L)
    val metadata="{ \"schemaVersion\": 2, \"id\": \"fixture-dump\", \"mode\": \"meeting\", \"title\": \"café 🧪\", \"transcript\": null }"
    fun args():Map<String,Any?> = mapOf("operationId" to "capture-fixture-reservation-prepare","reservation" to reservation,"metadataJson" to metadata,"audioSha256" to CaptureWire.sha(source))
    fun preparedArgs(preparation:Any?,id:String="fixture-inspect") = mapOf("operationId" to id,"reservation" to reservation,"preparation" to preparation)
    fun uri(id:String)="content://${directory.authority}/tree/primary%3Aroot/document/${URLEncoder.encode(id,"UTF-8").replace("+","%20") }"
    override fun name(directory:NativeDirectory):String { access(); return "fixture root" }
    override fun children(directory:NativeDirectory):List<NativeNode> {
        access(); return ProviderQuerySnapshot(documents.values.map { it.node },loading,queryError).completedRows()
    }
    override fun delete(directory:NativeDirectory,node:NativeNode):Boolean { deletes++; throw AssertionError("Capture must not delete") }
    var sourceReader:((String)->CaptureSource)?=null
    override fun captureSource(path:String):CaptureSource { access(); return sourceReader?.invoke(path) ?: CaptureSource(sourceIdentity,source.copyOf()) }
    override fun captureRoot(directory:NativeDirectory):Map<String,Any?> { name(directory); return CaptureWire.safIdentity(directory,directory.documentId) }
    override fun captureCreate(directory:NativeDirectory,name:String,mime:String,returned:(String)->Unit):String {
        access(); creates++
        val id=returnedExisting ?: "primary:opaque/path-${sequence++}"
        if(returnedExisting == null) documents[id]=Document(NativeNode(id,if(renamed) "$name (1)" else name,false))
        val uri=uri(id); returned(uri); onReturn?.invoke(uri)
        if(failAfterReturn) throw NativeStorageException("unavailable","Fixture query after successful create failed")
        return uri
    }
    override fun captureNode(directory:NativeDirectory,exactUri:String):NativeNode {
        access(); return children(directory).singleOrNull { it.id == CaptureWire.uri(exactUri).second }
            ?: throw NativeStorageException("unavailable","Fixture node not observable")
    }
    override fun captureOpen(directory:NativeDirectory,exactUri:String,writable:Boolean):CaptureDescriptor {
        if(writable && denyWritable) throw SecurityException("Fixture content is read-only")
        access(); opens++; descriptorError?.let { throw NativeStorageException(it,"Fixture descriptor failure") }
        val document=documents.getValue(CaptureWire.uri(exactUri).second)
        return object:CaptureDescriptor {
            override fun read():ByteArray { access(); return document.bytes.copyOf() }
            override fun initializeEmpty(bytes:ByteArray) {
                access()
                onInitialize?.invoke()
                if(!writable || document.bytes.isNotEmpty()) throw NativeStorageException("conflict","Fixture descriptor not empty")
                if(document.node.name == writeFailureName) {
                    if(partialWrite) { writes++; document.bytes=bytes.take(1).toByteArray() }
                    throw NativeStorageException("io","Fixture descriptor write/flush failed")
                }
                writes++; document.bytes=bytes.copyOf()
                if(document.node.name == corruptWriteName) document.bytes=byteArrayOf(9)
                if(document.node.name == flushFailureName) throw NativeStorageException("io","Fixture flush acknowledgement lost")
            }
            override fun close() {}
        }
    }
}

/** Native unit tests use a permission-aware model; an explicit host gate supplies real syscalls. */
internal class CaptureSourceFixture(alias: Boolean = false, readableAncestors: Boolean = false) : AutoCloseable {
    private val bridge = System.getenv("TANGENT_CAPTURE_HOST_BRIDGE")?.let {
        ProcessBuilder("wsl.exe", "-d", "Ubuntu", "--", "python3", it).redirectError(ProcessBuilder.Redirect.INHERIT).start()
    }
    private val input = bridge?.inputStream?.bufferedReader()
    private val output = bridge?.outputStream?.bufferedWriter()
    private val memory = if (bridge == null) SourceMemory() else null
    private fun request(op: String, vararg args: Any): org.json.JSONObject {
        val message = org.json.JSONObject().put("op", op).put("args", org.json.JSONArray(args.toList()))
        val response = if (memory != null) memory.request(message) else {
            output!!.write(message.toString()); output.newLine(); output.flush()
            org.json.JSONObject(input!!.readLine() ?: error("Host bridge exited before response"))
        }
        if (response.has("error")) throw NativeStorageException(response.getString("error"), response.optString("message"))
        return response
    }
    private val setup = request("init", alias, readableAncestors)
    val root: String = setup.getString("root")
    val canonical: String = setup.getString("canonical")
    val path: String = "$root/TangentStaging/fixture-reservation.opus"
    var afterRead: (() -> Unit)? = null
    val opens = mutableListOf<String>()
    val canonicalCalls = mutableListOf<String>()
    private fun node(j: org.json.JSONObject) = AndroidCaptureSource.Node(j.getLong("device"), j.getLong("inode"),
        j.getBoolean("directory"), j.getBoolean("regular"), j.getBoolean("link"), j.getInt("uid"))
    val io = object : AndroidCaptureSource.Io<Int> {
        override fun canonicalRoot(path: String): String {
            canonicalCalls.add(path); return request("canonical", path).getString("value")
        }
        override fun lstat(path: String) = node(request("lstat", path))
        override fun open(path: String): Int { opens.add(path); return request("open", path).getInt("fd") }
        override fun openAt(parent: Int, name: String): Int = request("openAt", parent, name).getInt("fd")
        override fun stat(handle: Int) = node(request("stat", handle))
        override fun identity(handle: Int): Map<String, Any?> {
            val s = stat(handle)
            if (!s.regular) throw NativeStorageException("unsupported", "Source is not regular")
            return mapOf("version" to 1, "kind" to "posix-file", "scope" to "0:${s.device}",
                "objectId" to s.inode.toString(), "generation" to null)
        }
        override fun read(handle: Int): ByteArray {
            val values = request("read", handle).getJSONArray("bytes")
            val bytes = ByteArray(values.length()) { values.getInt(it).toByte() }
            afterRead?.also { afterRead = null; it() }
            return bytes
        }
        override fun close(handle: Int) { request("close", handle) }
    }
    fun change(kind: String) { request("change", kind) }
    fun read(path: String = this.path) = AndroidCaptureSource(root, io).read(path)
    override fun close() {
        val live = request("live").getInt("count")
        request("finish")
        output?.close(); input?.close()
        if (bridge != null) {
            check(bridge.waitFor(10, java.util.concurrent.TimeUnit.SECONDS)) { "Host fixture did not exit" }
            check(bridge.exitValue() == 0)
        }
        check(live == 0) { "Leaked source descriptors: $live" }
    }
}

private class SourceMemory {
    private class Entry(val id: Long, val directory: Boolean, val target: String? = null,
                        val uid: Int = 1000, var readable: Boolean = true) {
        val children = linkedMapOf<String, Entry>()
    }
    private var sequence = 0L
    private fun dir() = Entry(++sequence, true)
    private fun file() = Entry(++sequence, false)
    private val top = dir()
    private val handles = mutableMapOf<Int, Entry>()
    private var nextFd = 10
    private var root = ""
    private val canonical = "/fixture/data/app/cache"
    private fun failure(code: String): Nothing = throw NativeStorageException(code, "Model filesystem $code")
    private fun resolve(path: String, followLast: Boolean = true, depth: Int = 0): Entry {
        if (depth > 20) failure("invalid")
        val names = path.split('/').filter { it.isNotEmpty() }
        var node = top
        for ((i, name) in names.withIndex()) {
            if (!node.directory) failure("invalid")
            node = node.children[name] ?: failure("absent")
            val target = node.target
            if (target != null && (followLast || i < names.lastIndex))
                node = resolve(target, true, depth + 1)
        }
        return node
    }
    private fun mkdir(path: String) {
        var node = top
        for (name in path.split('/').filter { it.isNotEmpty() }) node = node.children.getOrPut(name) { dir() }
    }
    private fun stat(e: Entry) = org.json.JSONObject().put("device", 1).put("inode", e.id)
        .put("directory", e.directory).put("regular", !e.directory && e.target == null)
        .put("link", e.target != null).put("uid", e.uid)
    private fun opened(e: Entry): org.json.JSONObject {
        if (e.target != null) failure("invalid")
        if (!e.readable) failure("denied")
        val fd = nextFd++; handles[fd] = e
        return org.json.JSONObject().put("fd", fd)
    }
    fun request(j: org.json.JSONObject): org.json.JSONObject {
        val a = j.getJSONArray("args")
        return when (j.getString("op")) {
            "init" -> {
                mkdir("$canonical/TangentStaging"); mkdir("/fixture/foreign")
                mkdir("$canonical-sibling/TangentStaging")
                resolve("$canonical-sibling/TangentStaging").children["fixture-reservation.opus"] = file()
                resolve("$canonical/TangentStaging").children["fixture-reservation.opus"] = file()
                resolve("/fixture/foreign").children["fixture-reservation.opus"] = file()
                resolve("/fixture/data").readable = a.getBoolean(1)
                root = if (a.getBoolean(0)) {
                    resolve("/fixture").children["alias"] = Entry(++sequence, false, "/fixture/data")
                    "/fixture/alias/app/cache"
                } else canonical
                org.json.JSONObject().put("root", root).put("canonical", canonical)
            }
            "canonical" -> {
                resolve(a.getString(0))
                org.json.JSONObject().put("value", if (a.getString(0) == root) canonical else a.getString(0))
            }
            "lstat" -> stat(resolve(a.getString(0), false))
            "open" -> opened(resolve(a.getString(0), false))
            "openAt" -> {
                val parent = handles.getValue(a.getInt(0))
                if (!parent.directory) failure("invalid")
                opened(parent.children[a.getString(1)] ?: failure("absent"))
            }
            "stat" -> stat(handles.getValue(a.getInt(0)))
            "read" -> { if (handles.getValue(a.getInt(0)).directory) failure("unsupported")
                org.json.JSONObject().put("bytes", org.json.JSONArray(listOf(1, 2, 3))) }
            "close" -> { check(handles.remove(a.getInt(0)) != null); org.json.JSONObject() }
            "live" -> org.json.JSONObject().put("count", handles.size)
            "finish" -> org.json.JSONObject()
            "change" -> {
                val cache = resolve(canonical)
                val staging = cache.children.getValue("TangentStaging")
                when (a.getString(0)) {
                    "finalLink" -> staging.children["fixture-reservation.opus"] = Entry(++sequence, false, "/fixture/foreign/fixture-reservation.opus")
                    "suffixLink" -> cache.children["TangentStaging"] = Entry(++sequence, false, "/fixture/foreign")
                    "replaceFile" -> staging.children["fixture-reservation.opus"] = file()
                    "rootSwap" -> { val replacement = dir(); replacement.children.putAll(cache.children)
                        resolve("/fixture/data/app").children["cache"] = replacement }
                    "suffixSwap" -> { val replacement = dir(); replacement.children.putAll(staging.children)
                        cache.children["TangentStaging"] = replacement }
                    "rootLink" -> resolve("/fixture/data/app").children["cache"] = Entry(++sequence, false, "/fixture/foreign")
                    "appLink" -> resolve("/fixture/data").children["app"] = Entry(++sequence, false, "/fixture/foreign")
                    "untrustedAlias" -> resolve("/fixture").children["alias"] = Entry(++sequence, false, "/fixture/data", 12345)
                    "directoryFile" -> staging.children["fixture-reservation.opus"] = dir()
                    else -> error("Unknown fixture mutation")
                }
                org.json.JSONObject()
            }
            else -> error("Unknown fixture command")
        }
    }
}
