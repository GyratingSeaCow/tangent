// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.tangent.tangent.storage

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract as DC
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import org.json.JSONObject
import android.system.Os
import android.system.OsConstants
import android.system.ErrnoException
import java.io.FileDescriptor
import java.io.ByteArrayOutputStream

/** Sole ContentResolver adapter. Never consults a current-default preference. */
class AndroidDocumentsPort(context: Context) : DocumentsIoPort, CaptureDocumentsPort {
    private val app = context.applicationContext
    private val resolver = app.contentResolver
    private val policy = SafPolicy(this)
    private val probeReceipts = ProbeReceipts()
    private val capture = CapturePublication(this)
    private fun <T> captureIo(action:()->T):T = try { action() }
        catch(e:ErrnoException) { fault(if(e.errno == OsConstants.EACCES || e.errno == OsConstants.EPERM) "denied" else if(e.errno == OsConstants.ENOENT) "absent" else "io","Capture descriptor operation failed") }
    private fun statIdentity(fd:FileDescriptor):Map<String,Any?> = captureIo {
        val s=Os.fstat(fd)
        if(!OsConstants.S_ISREG(s.st_mode)) fault("unsupported","Capture requires a regular descriptor")
        val major=((s.st_dev ushr 8) and 0xfffL) or ((s.st_dev ushr 32) and -4096L)
        val minor=(s.st_dev and 0xffL) or ((s.st_dev ushr 12) and -256L)
        CaptureWire.identity(mapOf("version" to 1,"kind" to "posix-file","scope" to "${CaptureWire.unsigned64(major)}:${CaptureWire.unsigned64(minor)}","objectId" to CaptureWire.unsigned64(s.st_ino),"generation" to null))
    }
    private inner class CaptureFd(private val fd:FileDescriptor, private val writable:Boolean,
                                  private val release:()->Unit) : CaptureDescriptor {
        private val identity=statIdentity(fd)
        private var closed=false
        private fun check() {
            if(closed || statIdentity(fd) != identity) fault("conflict","Capture descriptor identity changed")
        }
        override fun read():ByteArray = captureIo {
            check(); Os.lseek(fd,0L,OsConstants.SEEK_SET)
            val out=ByteArrayOutputStream(); val buffer=ByteArray(65536)
            while(true) { val count=Os.read(fd,buffer,0,buffer.size); if(count == 0) break; if(count < 0) fault("io","Capture descriptor read failed"); out.write(buffer,0,count) }
            check(); out.toByteArray()
        }
        override fun initializeEmpty(bytes:ByteArray) = captureIo {
            check()
            if(!writable || bytes.isEmpty() || Os.fstat(fd).st_size != 0L || read().isNotEmpty()) fault("conflict","Only an owned empty descriptor may be initialized")
            Os.lseek(fd,0L,OsConstants.SEEK_SET)
            var offset=0
            while(offset < bytes.size) { val count=Os.write(fd,bytes,offset,bytes.size-offset); if(count <= 0) fault("io","Capture descriptor short write"); offset+=count }
            Os.fsync(fd); check()
            if(!read().contentEquals(bytes)) fault("io","Capture descriptor readback mismatch")
        }
        override fun close() { if(!closed) { closed=true; release() } }
    }
    private fun sourceNode(s:android.system.StructStat) = AndroidCaptureSource.Node(
        s.st_dev,s.st_ino,OsConstants.S_ISDIR(s.st_mode),OsConstants.S_ISREG(s.st_mode),
        OsConstants.S_ISLNK(s.st_mode),s.st_uid)
    private fun sourceOpen(path:String):FileDescriptor =
        // Use only public API21 flags: O_CLOEXEC is public from API27 and
        // fcntlInt from API30. These read-only, short-lived handles never leave
        // this operation; no subprocess is launched by source acquisition.
        Os.open(path,OsConstants.O_RDONLY or OsConstants.O_NONBLOCK or OsConstants.O_NOFOLLOW,0)
    private val sourceIo = object:AndroidCaptureSource.Io<FileDescriptor> {
        override fun canonicalRoot(path:String) = File(path).canonicalPath
        override fun lstat(path:String) = sourceNode(Os.lstat(path))
        override fun open(path:String) = sourceOpen(path)
        override fun openAt(parent:FileDescriptor,name:String):FileDescriptor =
            android.os.ParcelFileDescriptor.dup(parent).use { anchor ->
                if(!OsConstants.S_ISDIR(Os.fstat(anchor.fileDescriptor).st_mode)) fault("invalid","Capture source parent is not a directory")
                sourceOpen("/proc/self/fd/${anchor.fd}/$name")
            }
        override fun stat(handle:FileDescriptor) = sourceNode(Os.fstat(handle))
        override fun identity(handle:FileDescriptor) = statIdentity(handle)
        override fun read(handle:FileDescriptor) = CaptureFd(handle,false) {}.use { it.read() }
        override fun close(handle:FileDescriptor) = Os.close(handle)
    }
    override fun captureSource(path:String):CaptureSource = captureIo {
        AndroidCaptureSource(app.cacheDir.path,sourceIo).read(path)
    }
    override fun captureRoot(directory:NativeDirectory):Map<String,Any?> {
        val row=query(document(directory)).singleOrNull() ?: fault("unavailable","Capture root unobservable")
        if(row.id != directory.documentId || !row.directory || row.virtual) fault("conflict","Capture root identity differs")
        return CaptureWire.safIdentity(directory,row.id)
    }
    override fun captureCreate(directory:NativeDirectory,name:String,mime:String,returned:(String)->Unit):String {
        policy.requireAvailableNames(directory,setOf(name)); grant(directory,true)
        val created=DC.createDocument(resolver,document(directory),mime,name) ?: fault("io","Provider refused capture create")
        val exact=created.toString(); returned(exact); return exact
    }
    override fun captureNode(directory:NativeDirectory,exactUri:String):NativeNode {
        val decoded=CaptureWire.uri(exactUri)
        if(decoded.first != directory.authority) fault("invalid","Foreign capture authority")
        grant(directory)
        val node=query(Uri.parse(exactUri)).singleOrNull() ?: fault("unavailable","Capture document unobservable")
        if(node.id != decoded.second || node.directory || node.virtual) fault("conflict","Capture returned identity differs")
        val owned=policy.ownedNode(directory,node.name,node.id) ?: fault("unavailable","Capture document is not a child")
        if(owned != node) fault("conflict","Capture membership differs")
        return node
    }
    override fun captureOpen(directory:NativeDirectory,exactUri:String,writable:Boolean):CaptureDescriptor {
        captureNode(directory,exactUri); grant(directory,writable)
        val pfd=resolver.openFileDescriptor(Uri.parse(exactUri),if(writable) "rw" else "r") ?: fault("io","Could not open capture descriptor")
        try { return CaptureFd(pfd.fileDescriptor,writable) { pfd.close() } }
        catch(e:Exception) { pfd.close(); throw e }
    }
    private fun fault(code:String,message:String):Nothing = throw NativeStorageException(code,message)
    private fun grant(directory:NativeDirectory,write:Boolean=false):Uri {
        val tree = Uri.parse(directory.treeUri)
        if (tree.scheme != "content" || tree.encodedAuthority != directory.authority || directory.documentId.isEmpty()) fault("invalid","Malformed directory capability")
        val treeId = try { DC.getTreeDocumentId(tree) } catch(e: Exception) { fault("invalid","Missing tree capability") }
        val permitted = resolver.persistedUriPermissions.any {
            try { SafPolicy.sameGrant(it.uri.encodedAuthority,DC.getTreeDocumentId(it.uri),tree.encodedAuthority,treeId) &&
                it.isReadPermission && (!write || it.isWritePermission) } catch(e: IllegalArgumentException) { false }
        }
        if (!permitted) fault("denied","Persisted directory grant is unavailable")
        return tree
    }
    override fun uri(directory:NativeDirectory,node:NativeNode):String = DC.buildDocumentUriUsingTree(grant(directory),node.id).toString()
    private fun document(directory:NativeDirectory) = DC.buildDocumentUriUsingTree(grant(directory),directory.documentId)
    private fun query(uri:Uri):List<NativeNode> {
        try {
            return resolver.query(uri,arrayOf(DC.Document.COLUMN_DOCUMENT_ID,DC.Document.COLUMN_DISPLAY_NAME,DC.Document.COLUMN_MIME_TYPE,DC.Document.COLUMN_FLAGS),null,null,null)?.use { cursor ->
                val result = mutableListOf<NativeNode>()
                while (cursor.moveToNext()) {
                    val id = cursor.getString(0) ?: fault("io","Missing document identity")
                    val name = cursor.getString(1) ?: fault("io","Missing display name")
                    result.add(NativeNode(id,name,cursor.getString(2) == DC.Document.MIME_TYPE_DIR,cursor.getLong(3) and DC.Document.FLAG_VIRTUAL_DOCUMENT.toLong() != 0L))
                }
                ProviderQuerySnapshot(result, cursor.extras.getBoolean(DC.EXTRA_LOADING, false),
                    cursor.extras.getString(DC.EXTRA_ERROR)).completedRows()
            } ?: fault("unavailable","Provider query returned no cursor")
        } catch(e: SecurityException) { fault("denied","Provider access denied") }
    }
    override fun name(directory:NativeDirectory):String {
        val nodes = query(document(directory))
        if (nodes.size != 1 || !nodes.single().directory || nodes.single().virtual) fault("unavailable","Effective directory unavailable")
        return nodes.single().name
    }
    override fun children(directory:NativeDirectory):List<NativeNode> {
        name(directory)
        return query(DC.buildChildDocumentsUriUsingTree(grant(directory),directory.documentId))
    }
    private fun checked(directory:NativeDirectory,node:NativeNode,flag:Int=0):Uri {
        val target = Uri.parse(uri(directory,node))
        val actual = query(target).singleOrNull() ?: fault("unavailable","Document unavailable")
        if (actual.id != node.id || actual.directory || actual.virtual) fault("invalid","Not an owned regular document")
        if (flag != 0) {
            grant(directory,true)
            val flags = resolver.query(target,arrayOf(DC.Document.COLUMN_FLAGS),null,null,null)?.use {
                if (!it.moveToFirst()) fault("unavailable","Document flags unavailable"); it.getLong(0)
            } ?: fault("unavailable","Document flags unavailable")
            if (flags and flag.toLong() == 0L) fault("denied","Provider does not support requested mutation")
        }
        return target
    }
    override fun delete(directory:NativeDirectory,node:NativeNode):Boolean = DC.deleteDocument(resolver,checked(directory,node,DC.Document.FLAG_SUPPORTS_DELETE))
    override fun read(directory:NativeDirectory,node:NativeNode):ByteArray = resolver.openInputStream(checked(directory,node))?.use { it.readBytes() } ?: fault("io","Could not open document")
    override fun write(directory:NativeDirectory,node:NativeNode,bytes:ByteArray) {
        resolver.openFileDescriptor(checked(directory,node,DC.Document.FLAG_SUPPORTS_WRITE),"rwt")?.use { descriptor ->
            FileOutputStream(descriptor.fileDescriptor).use { it.write(bytes); it.flush(); it.fd.sync() }
        } ?: fault("io","Could not open document for writing")
    }
    override fun create(directory:NativeDirectory,name:String,mime:String):NativeNode {
        policy.requireAvailableNames(directory, setOf(name))
        grant(directory,true)
        val created = DC.createDocument(resolver,document(directory),mime,name) ?: fault("io","Provider refused create")
        return probeReceipts.observe(created.toString()) {
            val node = query(created).singleOrNull() ?: fault("io","Created document not observable")
            if (node.name != name || node.directory || node.virtual) fault("conflict","Provider changed created identity")
            node
        }
    }
    override fun rename(directory:NativeDirectory,node:NativeNode,name:String):NativeNode {
        policy.requireAvailableNames(directory, setOf(name), node.id)
        val target = DC.renameDocument(resolver,checked(directory,node,DC.Document.FLAG_SUPPORTS_RENAME),name) ?: fault("io","Provider refused rename")
        return probeReceipts.observe(target.toString()) {
            val renamed = query(target).singleOrNull() ?: fault("io","Renamed document not observable")
            if (renamed.name != name || renamed.directory || renamed.virtual) fault("io","Provider changed rename target")
            renamed
        }
    }
    private fun map(value:Any?):Map<String,Any?> {
        @Suppress("UNCHECKED_CAST") return value as? Map<String,Any?> ?: fault("invalid","Missing object")
    }
    private fun text(value:Any?):String = value as? String ?: fault("invalid","Missing text field")
    private fun literal(value:Any?):String {
        val s = text(value)
        if (s.isEmpty() || s == "." || s == ".." || s.any { it == '/' || it == '\\' || it == '\u0000' }) fault("invalid","Invalid literal identifier")
        return s
    }
    private fun directory(location:Map<String,Any?>):NativeDirectory {
        val d = map(location["directory"])
        if (d["version"] != 1 || d["kind"] != "saf" || d["path"] != "") fault("invalid","Expected versioned SAF directory")
        return NativeDirectory(text(d["authority"]),text(d["treeUri"]),text(d["documentId"]))
    }
    private fun location(d:NativeDirectory,id:String,label:String):Map<String,Any?> = mapOf("version" to 1,"id" to id,"label" to label,"directory" to mapOf("version" to 1,"kind" to "saf","path" to "","authority" to d.authority,"treeUri" to d.treeUri,"documentId" to d.documentId))
    fun picked(tree:Uri):Map<String,Any?> {
        val d = NativeDirectory(tree.encodedAuthority ?: fault("invalid","Missing authority"),tree.toString(),DC.getTreeDocumentId(tree))
        return location(d,UUID.randomUUID().toString(),name(d))
    }
    private fun audioId(binding:Map<String,Any?>,d:NativeDirectory):String {
        val audio = map(binding["audio"])
        if (audio["version"] != 1 || audio["kind"] != "saf") fault("invalid","Expected versioned SAF audio")
        val uri = Uri.parse(text(audio["value"]))
        if (uri.encodedAuthority != d.authority) fault("invalid","Audio authority mismatch")
        return try { DC.getDocumentId(uri) } catch(e: Exception) { fault("invalid","Missing audio document ID") }
    }
    private fun metadata(args:Map<String,Any?>,id:String):ByteArray {
        val json = text(args["metadataJson"]); val decoded = JSONObject(json)
        if (decoded.optInt("schemaVersion") != 2 || decoded.optString("id") != id) fault("invalid","Metadata identity/schema mismatch")
        return json.toByteArray(Charsets.UTF_8)
    }
    private fun publish(d:NativeDirectory,name:String,mime:String,bytes:ByteArray,replace:Boolean):NativeNode {
        val old = policy.ownedNode(d,name,null)
        if (!replace && old != null) fault("conflict","Capture target exists")
        var temp = create(d,".$name-${UUID.randomUUID()}.partial",mime)
        try {
            write(d,temp,bytes)
            if (!read(d,temp).contentEquals(bytes)) fault("io","Publication readback mismatch")
            if (old != null && !delete(d,old)) fault("io","Provider refused replacement")
            temp = rename(d,temp,name)
            return temp
        } catch(e: Exception) {
            // Only this operation's exact returned document is eligible for cleanup.
            try { delete(d,temp) } catch (_: Exception) { /* Retain failure; never guess another URI. */ }
            throw e
        }
    }
    fun execute(method:String,args:Map<String,Any?>):Any? {
        if(method in setOf("prepareCaptureAt","inspectPreparedCaptureAt","publishPreparedCaptureAt")) return capture.execute(method,args)
        if (method == "inspectLegacyStorage") {
            return LegacyStorageInspection(
                { app.getSharedPreferences("tangent_storage",Context.MODE_PRIVATE).getString("recordings_tree_uri",null) },
                { d -> query(document(d)) },
                { d -> children(d) }
            ).inspect(args["frozenAnchorJson"])
        }
        val binding = args["binding"]?.let(::map)
        val reservation = args["reservation"]?.let(::map)
        val loc = map(binding?.get("location") ?: reservation?.get("location") ?: args["location"])
        val d = directory(loc)
        if (method == "validateCandidate") {
            return probeReceipts.capture { policy.probe(d,literal(args["token"])) }
        }
        if (method == "listRecordingsAt") {
            val nodes = children(d)
            // Durable-pair primary content mirrors the shared Dart mode helper
            // (contentExtensionForMode): audio modes publish .opus, text notes
            // publish .md. Both enumerate as importable pairs.
            val contentSuffixes = listOf(".opus", ".md")
            return nodes.mapNotNull { node ->
                val suffix = contentSuffixes.firstOrNull { node.name.endsWith(it) } ?: return@mapNotNull null
                val id = node.name.removeSuffix(suffix)
                var problem:Map<String,Any?>? = null; var meta:String? = null; var size = 0L; var modified = 0L
                try {
                    literal(id); val owned = policy.ownedNode(d,node.name,node.id) ?: fault("absent","Audio disappeared")
                    resolver.query(checked(d,owned),arrayOf(DC.Document.COLUMN_SIZE,DC.Document.COLUMN_LAST_MODIFIED),null,null,null)?.use {
                        if (!it.moveToFirst() || it.isNull(0) || it.isNull(1)) fault("unavailable","Provider size/time unavailable")
                        size = it.getLong(0); modified = it.getLong(1)
                    } ?: fault("unavailable","Provider stat unavailable")
                    val sidecar = policy.ownedNode(d,"$id.meta.json",null)
                    if (sidecar != null) meta = read(d,sidecar).toString(Charsets.UTF_8)
                } catch(e: Exception) { problem = mapOf("code" to (if(e is NativeStorageException) e.code else "io"),"message" to "Could not inspect recording") }
                mapOf("id" to id,"audio" to mapOf("version" to 1,"kind" to "saf","value" to uri(d,node)),"sizeBytes" to size,"modifiedAt" to modified,"metadataJson" to meta,"problem" to problem)
            }
        }

        val b = binding ?: fault("invalid","Missing binding")
        val key = map(b["key"]); val id = literal(key["dumpId"]); literal(key["incarnation"])
        if (b["metadataName"] != "$id.meta.json") fault("invalid","Wrong metadata component")
        val expected = audioId(b,d)
        // Durable-pair primary content mirrors the shared Dart mode helper
        // (contentExtensionForMode): the binding carries no mode, so exactly
        // the mode-derived names are acceptable — matching the Dart backend's
        // _component check. All bound operations use the binding's own name.
        val contentName = expected.substringAfterLast('/').substringAfterLast(':')
        if (contentName != "$id.opus" && contentName != "$id.md") fault("invalid","Binding does not identify exact owned components")
        // If content is present, even metadata-only work must reject a same-name
        // foreign document. Absence remains valid for explicit deletion retry.
        policy.ownedNode(d,contentName,expected)
        return when(method) {
            "readAudioAt", "playbackSourceAt" -> {
                val node = policy.ownedNode(d,contentName,expected) ?: fault("absent","Audio absent")
                if (method == "readAudioAt") read(d,node) else b["audio"]
            }
            "deleteComponentAt" -> {
                val component = text(args["component"])
                if (component != "audio" && component != "metadata") fault("invalid","Unknown component")
                val result = policy.deleteComponent(d,if(component == "audio") contentName else "$id.meta.json",if(component == "audio") expected else null)
                mapOf("state" to result.state,"problem" to result.problem?.let { mapOf("code" to it.code,"message" to it.message) })
            }
            "writeMetadataAt" -> { publish(d,"$id.meta.json","application/json",metadata(args,id),true); null }
            else -> fault("unsupported","Unsupported native storage method")
        }
    }
}
