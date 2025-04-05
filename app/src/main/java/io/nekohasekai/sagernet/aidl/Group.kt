package io.nekohasekai.sagernet.aidl

import android.os.Parcelable
import kotlinx.parcelize.Parcelize

@Parcelize
data class Group(
    val name: String = "",
    val type: String = "",
    var selected: String = "",
    val selectable: Boolean = false,
    var isExpand: Boolean = false,
) : Parcelable {
    constructor(group: libcore.Group) : this(
        group.tag,
        group.type,
        group.selected,
        group.selectable,
    )
}

fun libcore.Group.toParcelable(): Group = Group(this)