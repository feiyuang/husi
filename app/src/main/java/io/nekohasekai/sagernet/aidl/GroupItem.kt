package io.nekohasekai.sagernet.aidl

import android.os.Parcelable
import kotlinx.parcelize.Parcelize
import libcore.GroupItemIterator

@Parcelize
data class GroupItem(
    val tag: String = "",
    val type: String = "",
    var delay: Short = -1,
) : Parcelable {
    constructor(item: libcore.GroupItem) : this(
        item.tag,
        item.type,
        item.delay,
    )
}

fun GroupItemIterator.toList(): List<GroupItem> = ArrayList<GroupItem>(length()).apply {
    while (hasNext()) {
        add(GroupItem(next()))
    }
}