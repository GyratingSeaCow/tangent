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
    override fun captureSource(path:String):CaptureSource { access(); return CaptureSource(sourceIdentity,source.copyOf()) }
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
