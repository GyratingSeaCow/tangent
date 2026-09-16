// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.tangent.tangent.storage

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract as DC
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import org.json.JSONObject

/** Sole ContentResolver adapter. Never consults a current-default preference. */
class AndroidDocumentsPort(context: Context) : DocumentsIoPort {
    private val app = context.applicationContext
    private val resolver = app.contentResolver
    private val policy = SafPolicy(this)
    private val probeReceipts = ProbeReceipts()
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
            return nodes.filter { it.name.endsWith(".opus") }.map { node ->
                val id = node.name.removeSuffix(".opus")
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
        if (reservation != null && method == "publishCaptureAt") {
            val key = map(reservation["key"]); val id = literal(key["dumpId"]); literal(key["incarnation"])
            val source = File(text(reservation["stagingPath"]))
            if (!source.isFile || source.length() <= 0 || source.canonicalFile != source.absoluteFile) fault("invalid","Staging audio unavailable")
            policy.requireAvailableNames(d, setOf("$id.opus", "$id.meta.json"))
            val bytes = source.readBytes(); val meta = metadata(args,id)
            val audio = publish(d,"$id.opus","audio/ogg",bytes,false)
            publish(d,"$id.meta.json","application/json",meta,false)
            return mapOf("binding" to mapOf("version" to 1,"key" to key,"location" to loc,"audio" to mapOf("version" to 1,"kind" to "saf","value" to uri(d,audio)),"metadataName" to "$id.meta.json"),"sizeBytes" to bytes.size)
        }
        val b = binding ?: fault("invalid","Missing binding")
        val key = map(b["key"]); val id = literal(key["dumpId"]); literal(key["incarnation"])
        if (b["metadataName"] != "$id.meta.json") fault("invalid","Wrong metadata component")
        val expected = audioId(b,d)
        // If audio is present, even metadata-only work must reject a same-name
        // foreign document. Absence remains valid for explicit deletion retry.
        policy.ownedNode(d,"$id.opus",expected)
        return when(method) {
            "readAudioAt", "playbackSourceAt" -> {
                val node = policy.ownedNode(d,"$id.opus",expected) ?: fault("absent","Audio absent")
                if (method == "readAudioAt") read(d,node) else b["audio"]
            }
            "deleteComponentAt" -> {
                val component = text(args["component"])
                if (component != "audio" && component != "metadata") fault("invalid","Unknown component")
                val result = policy.deleteComponent(d,if(component == "audio") "$id.opus" else "$id.meta.json",if(component == "audio") expected else null)
                mapOf("state" to result.state,"problem" to result.problem?.let { mapOf("code" to it.code,"message" to it.message) })
            }
            "writeMetadataAt" -> { publish(d,"$id.meta.json","application/json",metadata(args,id),true); null }
            else -> fault("unsupported","Unsupported native storage method")
        }
    }
}
