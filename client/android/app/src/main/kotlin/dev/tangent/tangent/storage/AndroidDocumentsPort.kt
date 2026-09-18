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
class AndroidDocumentsPort(context: Context) : DocumentsIoPort, CaptureDocumentsPort, DurableDocumentsPort {
    private val app = context.applicationContext
    private val resolver = app.contentResolver
    private val policy = SafPolicy(this)
    private val probeReceipts = ProbeReceipts()
    private val capture = CapturePublication(this)
    private val documents = DocumentPublication(this)
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
        val owned=policy.ownedChildById(directory,node.name,node.id) ?: fault("unavailable","Capture document is not a child")
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
    /** Verifies one known child without listing the directory (T8).
     *
     *  Membership is proved by building the child's URI THROUGH the tree and
     *  confirming the document it resolves to reports the expected id and
     *  name. buildDocumentUriUsingTree only yields a readable URI for a
     *  document actually under the granted tree, so a foreign or detached id
     *  cannot resolve here -- the same guarantee the listing gave, without
     *  paying for all 81 rows.
     *
     *  Nothing is cached: every call re-queries, so a file removed by another
     *  app is still seen as gone. */
    override fun membership(directory:NativeDirectory,name:String,documentId:String):Membership {
        val tree = try { grant(directory) } catch(e: SecurityException) { fault("denied","Provider access denied") }
        val child = try {
            DC.buildDocumentUriUsingTree(tree, documentId)
        } catch(e: IllegalArgumentException) { return Membership.Absent }
        val rows = try {
            resolver.query(child,arrayOf(DC.Document.COLUMN_DOCUMENT_ID,DC.Document.COLUMN_DISPLAY_NAME,DC.Document.COLUMN_MIME_TYPE,DC.Document.COLUMN_FLAGS),null,null,null)?.use { cursor ->
                val result = mutableListOf<NativeNode>()
                while (cursor.moveToNext()) {
                    val id = cursor.getString(0) ?: return Membership.Unsupported
                    val display = cursor.getString(1) ?: return Membership.Unsupported
                    result.add(NativeNode(id,display,cursor.getString(2) == DC.Document.MIME_TYPE_DIR,cursor.getLong(3) and DC.Document.FLAG_VIRTUAL_DOCUMENT.toLong() != 0L))
                }
                // A still-loading or errored cursor is not a definitive answer;
                // fall back to the listing rather than risk a false 'absent'.
                if (cursor.extras.getBoolean(DC.EXTRA_LOADING,false) || cursor.extras.getString(DC.EXTRA_ERROR) != null) null
                else result
            } ?: return Membership.Unsupported
        } catch(e: SecurityException) { fault("denied","Provider access denied") }
        catch(e: IllegalArgumentException) { return Membership.Absent }
        val node = rows.singleOrNull() ?: return Membership.Absent
        if (node.id != documentId || node.name != name) return Membership.Absent
        if (node.directory || node.virtual) return Membership.Absent
        return Membership.Present(node)
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
    /** Creates a child DIRECTORY (notebooks live in their own folder). Mirrors
     *  create(), but asserts the provider handed back an actual directory. */
    override fun createDirectory(directory:NativeDirectory,name:String):NativeNode {
        policy.requireAvailableNames(directory, setOf(name))
        grant(directory,true)
        val created = DC.createDocument(resolver,document(directory),DC.Document.MIME_TYPE_DIR,name)
            ?: fault("io","Provider refused directory create")
        return probeReceipts.observe(created.toString()) {
            val node = query(created).singleOrNull() ?: fault("io","Created directory not observable")
            if (node.name != name || !node.directory || node.virtual) fault("conflict","Provider changed created identity")
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
        // AOSP FileSystemProvider appends a MIME-derived extension when the
        // requested display name's extension does not match the MIME type,
        // silently renaming the temp and tripping the created-identity check
        // (observed on-device: '.x.partial' became '.x.partial.json'). Keep
        // the temp's final extension MIME-coherent so the provider returns
        // the exact requested name.
        val tempExt = when(mime) { "application/json" -> ".json"; "text/markdown" -> ".md"; "audio/ogg" -> ".ogg"; else -> "" }
        var temp = create(d,".$name-${UUID.randomUUID()}.partial$tempExt",mime)
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
    /** The 'Tangent Text Notes' child of the owned root, if present as a real
     * directory. Text notes publish there (see CapturePublication); bound
     * note operations must follow. Never created on this read path. */
    private fun noteDirectory(d:NativeDirectory):NativeDirectory? {
        val matches = children(d).filter { it.name == CaptureWire.TEXT_NOTE_DIRECTORY }
        val node = matches.singleOrNull() ?: return null
        if (!node.directory || node.virtual) return null
        return NativeDirectory(d.authority,d.treeUri,node.id)
    }
    fun execute(method:String,args:Map<String,Any?>):Any? {
        if(method in setOf("prepareCaptureAt","inspectPreparedCaptureAt","publishPreparedCaptureAt")) return capture.execute(method,args)
        if(method in setOf("publishDocumentAt","listDocumentsAt","deleteDocumentAt")) return documents.execute(method,args)
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
        if (method == "probeLocationAt") {
            // Reachability only: query the directory document itself instead of
            // enumerating its children. inspectLocation used to route to
            // listRecordingsAt, which parsed every recording in the folder and
            // discarded the result — 5.8s on a real 81-file folder, paid on
            // EVERY record tap before any audio work could begin.
            val uri = DC.buildDocumentUriUsingTree(grant(d), d.documentId)
            resolver.query(uri, arrayOf(DC.Document.COLUMN_DOCUMENT_ID, DC.Document.COLUMN_MIME_TYPE), null, null, null)?.use { cursor ->
                if (!cursor.moveToFirst()) fault("absent","Recording folder is unavailable")
                if (cursor.getString(1) != DC.Document.MIME_TYPE_DIR) fault("invalid","Recording folder is not a directory")
                return null
            } ?: fault("absent","Recording folder is unavailable")
        }
        if (method == "readRecordingAt") {
            // Reads ONE published entry instead of scanning the folder (T8).
            // The listing path does two ownedNode lookups plus a stat and a
            // metadata read PER recording; proving one freshly written receipt
            // that way cost 4.4s of a 5.9s stop with 56 recordings.
            //
            // Same row shape as listRecordingsAt, decoded by the same Dart
            // helper, so a single read can never disagree with the listing.
            val dumpId = text(args["dumpId"]); literal(dumpId)
            val contentSuffixes = listOf(".opus", ".wav", ".md")
            fun readOne(dir:NativeDirectory):Map<String,Any?>? {
                for (suffix in contentSuffixes) {
                    val name = "$dumpId$suffix"
                    val node = try { policy.ownedNode(dir,name,null) } catch(e: Exception) { null } ?: continue
                    var problem:Map<String,Any?>? = null; var meta:String? = null; var size = 0L; var modified = 0L
                    try {
                        resolver.query(checked(dir,node),arrayOf(DC.Document.COLUMN_SIZE,DC.Document.COLUMN_LAST_MODIFIED),null,null,null)?.use {
                            if (!it.moveToFirst() || it.isNull(0) || it.isNull(1)) fault("unavailable","Provider size/time unavailable")
                            size = it.getLong(0); modified = it.getLong(1)
                        } ?: fault("unavailable","Provider stat unavailable")
                        val sidecar = policy.ownedNode(dir,"$dumpId.meta.json",null)
                        if (sidecar != null) meta = read(dir,sidecar).toString(Charsets.UTF_8)
                    } catch(e: Exception) { problem = mapOf("code" to (if(e is NativeStorageException) e.code else "io"),"message" to "Could not inspect recording") }
                    return mapOf("id" to dumpId,"audio" to mapOf("version" to 1,"kind" to "saf","value" to uri(dir,node)),"sizeBytes" to size,"modifiedAt" to modified,"metadataJson" to meta,"problem" to problem)
                }
                return null
            }
            return readOne(d) ?: noteDirectory(d)?.let { readOne(it) }
        }
        if (method == "listRecordingsAt") {
            // Durable-pair primary content mirrors the shared Dart mode helper
            // (contentExtensionForMode): audio modes publish .opus, text notes
            // publish .md. Both enumerate as importable pairs. Text notes
            // publish inside the 'Tangent Text Notes' child; legacy root-level
            // .md pairs still enumerate (tolerance, no migration).
            val contentSuffixes = listOf(".opus", ".wav", ".md")
            fun scan(dir:NativeDirectory):List<Map<String,Any?>> {
                val nodes = children(dir)
                return nodes.mapNotNull { node ->
                    val suffix = contentSuffixes.firstOrNull { node.name.endsWith(it) } ?: return@mapNotNull null
                    val id = node.name.removeSuffix(suffix)
                    var problem:Map<String,Any?>? = null; var meta:String? = null; var size = 0L; var modified = 0L
                    try {
                        literal(id); val owned = policy.ownedNode(dir,node.name,node.id) ?: fault("absent","Audio disappeared")
                        resolver.query(checked(dir,owned),arrayOf(DC.Document.COLUMN_SIZE,DC.Document.COLUMN_LAST_MODIFIED),null,null,null)?.use {
                            if (!it.moveToFirst() || it.isNull(0) || it.isNull(1)) fault("unavailable","Provider size/time unavailable")
                            size = it.getLong(0); modified = it.getLong(1)
                        } ?: fault("unavailable","Provider stat unavailable")
                        val sidecar = policy.ownedNode(dir,"$id.meta.json",null)
                        if (sidecar != null) meta = read(dir,sidecar).toString(Charsets.UTF_8)
                    } catch(e: Exception) { problem = mapOf("code" to (if(e is NativeStorageException) e.code else "io"),"message" to "Could not inspect recording") }
                    mapOf("id" to id,"audio" to mapOf("version" to 1,"kind" to "saf","value" to uri(dir,node)),"sizeBytes" to size,"modifiedAt" to modified,"metadataJson" to meta,"problem" to problem)
                }
            }
            val results = scan(d).toMutableList()
            noteDirectory(d)?.let { results += scan(it) }
            return results
        }

        val b = binding ?: fault("invalid","Missing binding")
        val key = map(b["key"]); val id = literal(key["dumpId"]); literal(key["incarnation"])
        if (b["metadataName"] != "$id.meta.json") fault("invalid","Wrong metadata component")
        val expected = audioId(b,d)
        // Durable-pair primary content mirrors the shared Dart mode helper
        // (captureExtensionForGain): audio publishes .opus at unity gain and
        // .wav when amplified, text notes .md.
        // SAF document IDs are provider-opaque, so NEVER parse them for a
        // filename — resolve by constant-name lookup exactly as before, with
        // the .md fallback. ownedNode validates name+docId together, so a
        // foreign same-name document still faults. Text notes publish inside
        // the 'Tangent Text Notes' child, so name resolution checks the root
        // first (audio modes, legacy root notes) and then that child; the
        // binding-derived docId keeps the lookup anchored to the exact
        // published document either way.
        val note = noteDirectory(d)
        fun ownedContent():Pair<NativeDirectory,NativeNode>? {
            policy.ownedNode(d,"$id.opus",expected)?.let { return d to it }
            // Amplified captures publish .wav (see the Dart helper
            // captureExtensionForGain). Without this the audio exists on disk
            // but is invisible to playback, read and delete.
            policy.ownedNode(d,"$id.wav",expected)?.let { return d to it }
            policy.ownedNode(d,"$id.md",expected)?.let { return d to it }
            note?.let { n -> policy.ownedNode(n,"$id.md",expected)?.let { return n to it } }
            return null
        }
        // If content is present, even metadata-only work must reject a same-name
        // foreign document. Absence remains valid for explicit deletion retry.
        val present = ownedContent()
        return when(method) {
            "readAudioAt", "playbackSourceAt" -> {
                val (dir,node) = present ?: fault("absent","Audio absent")
                if (method == "readAudioAt") read(dir,node) else b["audio"]
            }
            "deleteComponentAt" -> {
                val component = text(args["component"])
                if (component != "audio" && component != "metadata") fault("invalid","Unknown component")
                // Components live beside the resolved content. A metadata-only
                // retry with no surviving content also checks the note child so
                // subdir sidecars stay deletable after their .md is gone.
                val dir = present?.first ?: d
                val contentName = present?.second?.name ?: "$id.opus"
                var result = policy.deleteComponent(dir,if(component == "audio") contentName else "$id.meta.json",if(component == "audio") expected else null)
                if (component == "metadata" && result.state == "absent" && present == null && note != null) {
                    result = policy.deleteComponent(note,"$id.meta.json",null)
                }
                mapOf("state" to result.state,"problem" to result.problem?.let { mapOf("code" to it.code,"message" to it.message) })
            }
            "writeMetadataAt" -> {
                // The sidecar publishes beside its content; with no surviving
                // content, prefer wherever an owned sidecar already exists.
                val target = present?.first
                    ?: note?.takeIf { policy.ownedNode(it,"$id.meta.json",null) != null }
                    ?: d
                publish(target,"$id.meta.json","application/json",metadata(args,id),true); null
            }
            else -> fault("unsupported","Unsupported native storage method")
        }
    }
}
