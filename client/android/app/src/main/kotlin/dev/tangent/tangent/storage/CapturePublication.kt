// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.tangent.tangent.storage

import java.net.URI
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import org.json.JSONObject

/** Only provider primitives are replaceable; production and JVM use this policy. */
interface CaptureDocumentsPort : DocumentsPort {
    fun captureSource(path: String): CaptureSource
    fun captureRoot(directory: NativeDirectory): Map<String,Any?>
    fun captureCreate(directory: NativeDirectory, name: String, mime: String, returned: (String)->Unit): String
    fun captureNode(directory: NativeDirectory, exactUri: String): NativeNode
    fun captureOpen(directory: NativeDirectory, exactUri: String, writable: Boolean): CaptureDescriptor
}
data class CaptureSource(val identity: Map<String,Any?>, val bytes: ByteArray)
interface CaptureDescriptor : AutoCloseable {
    fun read(): ByteArray
    /** Must check the opened regular descriptor is empty; no truncating open. */
    fun initializeEmpty(bytes: ByteArray)
}

object CaptureWire {
    // Long.toUnsignedString is API26; the supported Android minimum is API24.
    fun unsigned64(value:Long):String = java.math.BigInteger.valueOf(value)
        .and(java.math.BigInteger.ONE.shiftLeft(64).subtract(java.math.BigInteger.ONE)).toString()
    fun fault(code:String, message:String):Nothing = throw NativeStorageException(code,message)
    fun text(x:Any?):String = x as? String ?: fault("invalid","Expected capture string")
    fun literal(x:Any?):String = text(x).also {
        if (it.isEmpty() || it in setOf(".","..") || it.any { c -> c == '/' || c == '\\' || c == '\u0000' }) fault("invalid","Invalid capture literal")
    }
    fun integer(x:Any?, positive:Boolean=true):Long {
        if (x !is Int && x !is Long) fault("invalid","Expected integral capture value")
        val n = (x as Number).toLong()
        if (positive && n <= 0) fault("invalid","Expected positive capture value")
        return n
    }
    fun obj(x:Any?, fields:Set<String>):Map<String,Any?> {
        val raw = x as? Map<*,*> ?: fault("invalid","Expected capture object")
        if (raw.keys.any { it !is String }) fault("invalid","Invalid capture object key")
        if (raw["version"] !is Int && raw["version"] !is Long) fault("invalid","Expected integer capture version")
        if ((raw["version"] as Number).toLong() != 1L) fault("unsupported","Unsupported capture version")
        if (raw.keys != fields + "version") fault("invalid","Unexpected capture object fields")
        @Suppress("UNCHECKED_CAST") return raw as Map<String,Any?>
    }
    private fun authority(value:String):String = value.also {
        if(it.isEmpty() || it.any { c -> c == '\u0000' || c in "/\\:?#@" }) fault("invalid","Invalid capture authority")
    }
    private fun contentParts(value:String):Pair<String,List<String>> {
        try {
            val u = URI(value)
            if (!u.scheme.equals("content",ignoreCase=true) || u.rawAuthority.isNullOrEmpty() ||
                u.rawQuery != null || u.rawFragment != null || !u.rawPath.startsWith('/')) fault("invalid","Invalid capture URI envelope")
            val scope=authority(u.rawAuthority)
            // Split before decoding. Preserve literal Unicode, plus and encoded
            // slashes; reject malformed UTF-8 rather than replacement decoding.
            val segments=u.rawPath.substring(1).split('/').map { encoded ->
                val pieces=encoded.split('%'); val bytes=ByteArrayOutputStream()
                bytes.write(pieces.first().toByteArray(Charsets.UTF_8))
                for(piece in pieces.drop(1)) {
                    bytes.write(piece.substring(0,2).toInt(16))
                    bytes.write(piece.substring(2).toByteArray(Charsets.UTF_8))
                }
                val decoded=Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes.toByteArray())).toString()
                if(decoded.contains('\u0000')) fault("invalid","Invalid capture URI identity")
                decoded
            }
            return scope to segments
        } catch(e:NativeStorageException) { throw e }
        catch(e:Exception) { fault("invalid","Malformed capture URI") }
    }
    fun uri(value:String):Pair<String,String> {
        val (scope,parts)=contentParts(value)
        val id=when {
            parts.size == 2 && parts[0] == "document" -> parts[1]
            parts.size == 4 && parts[0] == "tree" && parts[1].isNotEmpty() && parts[2] == "document" -> parts[3]
            else -> fault("invalid","Invalid capture document URI")
        }
        if(id.isEmpty()) fault("invalid","Empty capture document ID")
        return scope to id
    }
    fun identity(x:Any?):Map<String,Any?> {
        val m = obj(x,setOf("kind","scope","objectId","generation"))
        val kind = text(m["kind"]); val scope=text(m["scope"]); val id=text(m["objectId"]); val g=m["generation"]
        if (g != null && g !is String) fault("invalid","Invalid capture generation")
        fun decimal(v:String,bits:Int) = Regex("0|[1-9][0-9]*").matches(v) && v.toBigInteger() < java.math.BigInteger.ONE.shiftLeft(bits)
        when(kind) {
            "windows-file" -> if (!Regex("[0-9a-f]{16}").matches(scope) || !Regex("[0-9a-f]{32}").matches(id) || (g != null && !decimal(g as String,64))) fault("invalid","Invalid Windows capture identity")
            "posix-file" -> {
                val dev=scope.split(':')
                if (dev.size != 2 || dev.any { !decimal(it,32) } || !decimal(id,64)) fault("invalid","Invalid POSIX capture identity")
                if (g != null) {
                    val birth=(g as String).split(':')
                    if (birth.size != 2 || !Regex("-?(0|[1-9][0-9]*)").matches(birth[0]) || birth[0] == "-0" || birth[0].toLongOrNull() == null || !Regex("[0-9]{9}").matches(birth[1])) fault("invalid","Invalid birth identity")
                }
            }
            "saf-document" -> {
                authority(scope)
                contentParts("content://$scope/document/fixture")
                if(id.isEmpty() || id.contains('\u0000') || g != null) fault("invalid","Invalid SAF capture identity")
            }
            else -> fault("invalid","Unknown capture identity kind")
        }
        return m
    }
    fun safIdentity(d:NativeDirectory,id:String) = identity(mapOf("version" to 1,"kind" to "saf-document","scope" to d.authority,"objectId" to id,"generation" to null))
    fun directory(location:Any?):NativeDirectory {
        val loc=obj(location,setOf("id","label","directory")); literal(loc["id"]); text(loc["label"])
        val d=obj(loc["directory"],setOf("kind","path","treeUri","authority","documentId"))
        if (d["kind"] != "saf" || d["path"] != "") fault("invalid","Expected SAF capture root")
        val authority=text(d["authority"]); val id=text(d["documentId"]); safIdentity(NativeDirectory(authority,"",id),id)
        val tree=text(d["treeUri"])
        val (scope,parts)=contentParts(tree)
        val validTree=parts.size == 2 || (parts.size == 4 && parts[2] == "document" && parts[3].isNotEmpty())
        if(scope != authority || !validTree || parts[0] != "tree" || parts[1].isEmpty()) fault("invalid","Invalid capture tree capability")
        return NativeDirectory(authority,tree,id)
    }
    fun reservation(x:Any?):Map<String,Any?> {
        val r=obj(x,setOf("id","key","location","stagingPath","mode","startedAtMs"))
        val id=literal(r["id"]); key(r["key"]); directory(r["location"]); integer(r["startedAtMs"])
        val path=text(r["stagingPath"])
        if (!path.startsWith('/') || path.contains('\u0000') || path.split('/').any { it == "." || it == ".." } || path.substringAfterLast('/') != "$id.opus") fault("invalid","Invalid reservation staging path")
        if (text(r["mode"]) !in setOf("meeting","brain_dump")) fault("invalid","Invalid capture mode")
        return r
    }
    fun key(x:Any?):Map<String,Any?> = obj(x,setOf("dumpId","incarnation")).also { literal(it["dumpId"]); literal(it["incarnation"]) }
    fun digest(x:Any?):String = text(x).also { if (!Regex("[0-9a-f]{64}").matches(it)) fault("invalid","Invalid capture SHA-256") }
    fun sha(bytes:ByteArray):String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    fun metadata(json:String,r:Map<String,Any?>) {
        try {
            val m=JSONObject(json)
            if (m.get("schemaVersion") != 2 || m.get("id") != key(r["key"])["dumpId"] || m.get("mode") != r["mode"]) fault("invalid","Frozen capture metadata mismatch")
        } catch(e:NativeStorageException) { throw e } catch(e:Exception) { fault("invalid","Malformed frozen capture metadata") }
    }
    fun claim(x:Any?, component:String, r:Map<String,Any?>):Map<String,Any?> {
        val c=obj(x,setOf("component","name","locator","identity")); val d=directory(r["location"])
        val expected="${key(r["key"])["dumpId"]}" + if(component == "audio") ".opus" else ".meta.json"
        if (c["component"] != component || c["name"] != expected) fault("invalid","Wrong capture component")
        val l=obj(c["locator"],setOf("kind","value")); if(l["kind"] != "saf") fault("invalid","Wrong capture locator kind")
        val id=identity(c["identity"]); val u=uri(text(l["value"]))
        if (id["kind"] != "saf-document" || id["scope"] != d.authority || u.first != d.authority || u.second != id["objectId"]) fault("invalid","Capture locator identity mismatch")
        return c
    }
    fun preparation(x:Any?,r:Map<String,Any?>):Map<String,Any?> {
        val p=obj(x,setOf("publicationId","reservationId","key","location","stagingPath","sourceIdentity","rootIdentity","audioSizeBytes","audioSha256","metadataJson","audio","metadata"))
        if (p["publicationId"] != r["id"] || p["reservationId"] != r["id"] || p["key"] != r["key"] || p["location"] != r["location"] || p["stagingPath"] != r["stagingPath"]) fault("conflict","Capture preparation has another owner")
        integer(p["audioSizeBytes"]); digest(p["audioSha256"]); metadata(text(p["metadataJson"]),r)
        val d=directory(r["location"]); val root=identity(p["rootIdentity"]); val source=identity(p["sourceIdentity"])
        if(root != safIdentity(d,d.documentId) || source["kind"] != "posix-file") fault("invalid","Invalid capture source/root identity")
        if (p["audio"] == null || p["metadata"] == null) fault("unresolved","Capture preparation is incomplete")
        val a=claim(p["audio"],"audio",r); val m=claim(p["metadata"],"metadata",r)
        if(a["identity"] == m["identity"] || a["identity"] == root || m["identity"] == root) fault("invalid","Capture identities alias")
        return p
    }
    fun problem(e:Exception):Map<String,Any?> = mapOf("version" to 1,"code" to when(e) {
        is NativeStorageException -> e.code; is SecurityException -> "denied"; else -> "io"
    },"message" to (if(e is NativeStorageException) e.message else "Capture provider operation failed"))
}

class CapturePublication(private val port:CaptureDocumentsPort) {
    private val policy=SafPolicy(port)
    private fun source(r:Map<String,Any?>,digest:String):CaptureSource {
        val source=port.captureSource(CaptureWire.text(r["stagingPath"]))
        CaptureWire.identity(source.identity)
        if(source.identity["kind"] != "posix-file" || source.bytes.isEmpty() || CaptureWire.sha(source.bytes) != digest) CaptureWire.fault("conflict","Frozen capture source changed")
        return source
    }
    private fun inventory(d:NativeDirectory):List<NativeNode> = port.children(d).also { rows ->
        if(rows.map { it.id }.distinct().size != rows.size) CaptureWire.fault("conflict","Duplicate capture child identity")
    }
    private fun observe(d:NativeDirectory,claim:Map<String,Any?>):NativeNode? {
        val uri=CaptureWire.text((claim["locator"] as Map<*,*>)["value"])
        val id=CaptureWire.text((claim["identity"] as Map<*,*>)["objectId"])
        val owned=policy.ownedNode(d,CaptureWire.text(claim["name"]),id) ?: return null
        val queried=port.captureNode(d,uri)
        if(queried != owned) CaptureWire.fault("conflict","Capture URI and membership differ")
        return owned
    }
    fun prepare(args:Map<String,Any?>):Map<String,Any?> {
        val raw=mutableListOf<String>(); var dispatched=false; var prepared:MutableMap<String,Any?>?=null
        try {
            val r=CaptureWire.reservation(args["reservation"]); val d=CaptureWire.directory(r["location"])
            if(args["operationId"] != "capture-${r["id"]}-prepare") CaptureWire.fault("invalid","Wrong capture preparation operation ID")
            val metadata=CaptureWire.text(args["metadataJson"]); CaptureWire.metadata(metadata,r)
            val digest=CaptureWire.digest(args["audioSha256"]); val source=source(r,digest)
            val root=port.captureRoot(d); if(root != CaptureWire.safIdentity(d,d.documentId)) CaptureWire.fault("conflict","Capture root differs")
            val id=CaptureWire.key(r["key"])["dumpId"] as String
            val before=inventory(d).map { it.id }.toSet()
            policy.requireAvailableNames(d,setOf("$id.opus","$id.meta.json"))
            prepared=linkedMapOf("version" to 1,"publicationId" to r["id"],"reservationId" to r["id"],"key" to r["key"],"location" to r["location"],"stagingPath" to r["stagingPath"],"sourceIdentity" to source.identity,"rootIdentity" to root,"audioSizeBytes" to source.bytes.size,"audioSha256" to digest,"metadataJson" to metadata,"audio" to null,"metadata" to null)
            for(component in listOf("audio","metadata")) {
                val name=if(component == "audio") "$id.opus" else "$id.meta.json"
                if(port.captureRoot(d) != root) CaptureWire.fault("conflict","Capture root changed")
                val prior=inventory(d).map { it.id }.toSet()
                policy.requireAvailableNames(d,setOf(name))
                dispatched=true
                val uri=port.captureCreate(d,name,if(component == "audio") "audio/ogg" else "application/json") { raw.add(it) }
                if(raw.lastOrNull() != uri) CaptureWire.fault("invalid","Missing raw capture creation receipt")
                val decoded=CaptureWire.uri(uri)
                if(decoded.first != d.authority || decoded.second in before || decoded.second in prior || decoded.second == d.documentId) CaptureWire.fault("conflict","Returned capture ID was not newly created")
                val claim=mapOf("version" to 1,"component" to component,"name" to name,"locator" to mapOf("version" to 1,"kind" to "saf","value" to uri),"identity" to CaptureWire.safIdentity(d,decoded.second))
                CaptureWire.claim(claim,component,r)
                if(observe(d,claim) == null) CaptureWire.fault("unavailable","Created capture is not observable")
                prepared[component]=claim
                port.captureOpen(d,uri,false).use { if(it.read().isNotEmpty()) CaptureWire.fault("conflict","Created capture is not empty") }
                if(observe(d,claim) == null) CaptureWire.fault("unavailable","Created capture disappeared")
            }
            CaptureWire.preparation(prepared,r)
            val again=source(r,digest)
            if(again.identity != source.identity || !again.bytes.contentEquals(source.bytes) || port.captureRoot(d) != root) CaptureWire.fault("conflict","Capture proof changed during prepare")
            return mapOf("version" to 1,"state" to "prepared","preparation" to prepared,"rawReturnedLocators" to raw.toList(),"problem" to null)
        } catch(e:Exception) {
            return mapOf("version" to 1,"state" to if(dispatched) "uncertain" else "notStarted","preparation" to if(dispatched) prepared else null,"rawReturnedLocators" to raw.toList(),"problem" to CaptureWire.problem(e))
        }
    }
    private fun proof(r:Map<String,Any?>,p:Map<String,Any?>):CaptureSource {
        val source=source(r,CaptureWire.digest(p["audioSha256"]))
        if(source.identity != p["sourceIdentity"] || source.bytes.size.toLong() != CaptureWire.integer(p["audioSizeBytes"]) || port.captureRoot(CaptureWire.directory(r["location"])) != p["rootIdentity"]) CaptureWire.fault("conflict","Capture source/root proof differs")
        return source
    }
    private fun state(bytes:ByteArray,expected:ByteArray):String = if(bytes.isEmpty()) "empty" else if(bytes.contentEquals(expected)) "complete" else "partial"
    private fun inspectOne(d:NativeDirectory,claim:Map<String,Any?>,bytes:ByteArray):Map<String,Any?> {
        try {
            if(observe(d,claim) == null) return mapOf("version" to 1,"state" to "absent","problem" to null)
            val uri=CaptureWire.text((claim["locator"] as Map<*,*>)["value"])
            val result=port.captureOpen(d,uri,false).use { state(it.read(),bytes) }
            if(observe(d,claim) == null) CaptureWire.fault("unavailable","Capture disappeared during readback")
            return mapOf("version" to 1,"state" to result,"problem" to if(result == "partial") CaptureWire.problem(NativeStorageException("unresolved","Nonempty capture differs")) else null)
        } catch(e:Exception) {
            val problem=CaptureWire.problem(e)
            return mapOf("version" to 1,"state" to if(problem["code"] in setOf("invalid","conflict")) "foreign" else "unknown","problem" to problem)
        }
    }
    fun inspect(args:Map<String,Any?>):Map<String,Any?> {
        val r=CaptureWire.reservation(args["reservation"]); val p=CaptureWire.preparation(args["preparation"],r); val source=proof(r,p)
        val d=CaptureWire.directory(r["location"])
        val a=CaptureWire.claim(p["audio"],"audio",r); val m=CaptureWire.claim(p["metadata"],"metadata",r)
        val result=mapOf("version" to 1,"audio" to inspectOne(d,a,source.bytes),"metadata" to inspectOne(d,m,CaptureWire.text(p["metadataJson"]).toByteArray(Charsets.UTF_8)))
        proof(r,p); return result
    }
    fun publish(args:Map<String,Any?>):Map<String,Any?> {
        val r=CaptureWire.reservation(args["reservation"]); val p=CaptureWire.preparation(args["preparation"],r); val source=proof(r,p)
        val d=CaptureWire.directory(r["location"]); val a=CaptureWire.claim(p["audio"],"audio",r); val m=CaptureWire.claim(p["metadata"],"metadata",r)
        val inspection=inspect(args)
        for(c in listOf("audio","metadata")) if((inspection[c] as Map<*,*>)["state"] !in setOf("empty","complete")) CaptureWire.fault("unresolved","Capture component is not safe to initialize")
        val metadata=CaptureWire.text(p["metadataJson"]).toByteArray(Charsets.UTF_8)
        val au=CaptureWire.text((a["locator"] as Map<*,*>)["value"]); val mu=CaptureWire.text((m["locator"] as Map<*,*>)["value"])
        if(observe(d,a) == null || observe(d,m) == null) CaptureWire.fault("unavailable","Capture component disappeared")
        port.captureOpen(d,au,(inspection["audio"] as Map<*,*>)["state"] == "empty").use { audio ->
          port.captureOpen(d,mu,(inspection["metadata"] as Map<*,*>)["state"] == "empty").use { meta ->
            val as_=state(audio.read(),source.bytes); val ms=state(meta.read(),metadata)
            if(as_ == "partial" || ms == "partial") CaptureWire.fault("unresolved","Capture content became partial")
            if(observe(d,a) == null || observe(d,m) == null) CaptureWire.fault("unavailable","Capture membership changed")
            if(as_ == "empty") audio.initializeEmpty(source.bytes)
            if(!audio.read().contentEquals(source.bytes) || observe(d,a) == null) CaptureWire.fault("io","Capture audio readback failed")
            if(ms == "empty") meta.initializeEmpty(metadata)
            if(!meta.read().contentEquals(metadata) || observe(d,m) == null) CaptureWire.fault("io","Capture metadata readback failed")
        } }
        val verified=inspect(args)
        for(c in listOf("audio","metadata")) if((verified[c] as Map<*,*>)["state"] != "complete") CaptureWire.fault("unresolved","Capture pair is not complete")
        return mapOf("binding" to mapOf("version" to 1,"key" to r["key"],"location" to r["location"],"audio" to a["locator"],"metadataName" to m["name"]),"sizeBytes" to source.bytes.size)
    }
    fun execute(method:String,args:Map<String,Any?>):Any = when(method) {
        "prepareCaptureAt" -> prepare(args)
        "inspectPreparedCaptureAt" -> inspect(args)
        "publishPreparedCaptureAt" -> publish(args)
        else -> CaptureWire.fault("unsupported","Unknown capture operation")
    }
}
