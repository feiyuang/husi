package io.nekohasekai.sagernet.aidl

import android.os.Parcelable
import kotlinx.parcelize.Parcelize
import libcore.TrackerInfo
import libcore.TrackerInfoIterator

@Parcelize
data class Connection(
    val uuid: String = "",
    val inbound: String = "",
    val ipVersion: Short? = null,
    val network: String = "",
    val uploadTotal: Long = 0L,
    val downloadTotal: Long = 0L,
    val start: String = "",
    val src: String = "",
    val dst: String = "",
    val host: String = "",
    val matchedRule: String = "",
    val outbound: String = "",
    val chain: String = "",
    val protocol: String? = null,
) : Parcelable {
    constructor(trackerInfo: TrackerInfo) : this(
        uuid = trackerInfo.uuid,
        inbound = trackerInfo.inbound,
        ipVersion = trackerInfo.ipVersion.takeIf { it > 0 },
        network = trackerInfo.network,
        uploadTotal = trackerInfo.uploadTotal,
        downloadTotal = trackerInfo.downloadTotal,
        start = trackerInfo.start,
        src = trackerInfo.src,
        dst = trackerInfo.dst,
        host = trackerInfo.host,
        matchedRule = trackerInfo.matchedRule,
        outbound = trackerInfo.outbound,
        chain = trackerInfo.chain,
        protocol = trackerInfo.protocol.takeIf { it.isNotBlank() },
    )
}

fun TrackerInfoIterator.toList(): List<Connection> = ArrayList<Connection>(length()).apply {
    while (hasNext()) {
        add(Connection(next()))
    }
}