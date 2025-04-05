package io.nekohasekai.sagernet.ui.traffic

import android.annotation.SuppressLint
import android.os.Bundle
import androidx.core.view.isInvisible
import android.text.TextWatcher
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.fragment.app.Fragment
import androidx.core.widget.addTextChangedListener
import androidx.recyclerview.widget.GridLayoutManager
import androidx.recyclerview.widget.RecyclerView
import androidx.recyclerview.widget.SimpleItemAnimator
import androidx.core.view.isVisible
import com.google.android.material.textfield.MaterialAutoCompleteTextView
import io.nekohasekai.sagernet.R
import io.nekohasekai.sagernet.aidl.Group
import io.nekohasekai.sagernet.aidl.GroupItem
import io.nekohasekai.sagernet.databinding.LayoutClashGroupsBinding
import io.nekohasekai.sagernet.databinding.ViewDashboardGroupItemBinding
import io.nekohasekai.sagernet.ktx.FixedLinearLayoutManager
import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.ktx.runOnDefaultDispatcher
import io.nekohasekai.sagernet.ui.MainActivity
import io.nekohasekai.sfa.utils.ColorUtils.colorForURLTestDelay
import kotlinx.coroutines.DelicateCoroutinesApi

class DashboardGroup : Fragment(R.layout.layout_clash_groups) {

    val activity: MainActivity? get() = super.activity as? MainActivity
    lateinit var binding: LayoutClashGroupsBinding
    lateinit var adapter: Adapter

    fun groupSwitch(groupName: String, tag: String) {
        if (!::adapter.isInitialized) return
        val index = adapter.groups.indexOfFirst { it.name == groupName }
        if (index < 0) return

        adapter.groups[index].selected = tag
        adapter.notifyItemChanged(index)
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)

        binding = LayoutClashGroupsBinding.bind(view)

        binding.itemList.layoutManager = FixedLinearLayoutManager(binding.itemList)
        binding.itemList.adapter = Adapter().apply {
            adapter = this
            activity?.connection?.service?.groups?.let {
                groups = it
            }
        }
    }

    inner class Adapter : RecyclerView.Adapter<GroupView>() {

        var groups = mutableListOf<Group>()

        /*fun setGroups(newGroups: List<Group>) {
            if (groups.size != newGroups.size) {
                groups = newGroups.toMutableList()
                notifyDataSetChanged()
            } else {
                newGroups.forEachIndexed { index, group ->
                    if (this.groups[index] != group) {
                        this.groups[index] = group
                        notifyItemChanged(index)
                    }
                }
            }
        }*/

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): GroupView {
            return GroupView(
                LayoutClashGroupsBinding.inflate(
                    LayoutInflater.from(parent.context),
                    parent,
                    false,
                ),
            )
        }

        override fun getItemCount(): Int {
            return groups.size
        }

        override fun onBindViewHolder(holder: GroupView, position: Int) {
            holder.bind(groups[position])
        }
    }

    inner class GroupView(val binding: LayoutClashGroupsBinding) :
        RecyclerView.ViewHolder(binding.root) {

        private lateinit var group: Group
        lateinit var items: List<GroupItem>
        private lateinit var adapter: ItemAdapter
        private var textWatcher: TextWatcher? = null

        @OptIn(DelicateCoroutinesApi::class)
        @SuppressLint("NotifyDataSetChanged")
        fun bind(group: Group) {
            this.group = group
            binding.groupName.text = group.name
            binding.groupType.text = group.type
            binding.urlTestButton.setOnClickListener {
                runOnDefaultDispatcher {
                    try {
                        activity!!.urlTest(group.name)
                    } catch (e: Exception) {
                        Logs.e(e)
                    }
                }
            }

            items = activity?.connection?.service?.queryGroup(group.name) ?: return
            if (!::adapter.isInitialized) {
                adapter = ItemAdapter(this, group, items.toMutableList())
                binding.itemList.adapter = adapter
                (binding.itemList.itemAnimator as SimpleItemAnimator).supportsChangeAnimations =
                    false
                binding.itemList.layoutManager = GridLayoutManager(binding.root.context, 2)
            } else {
                adapter.group = group
                adapter.setItems(items)
            }
            updateExpand()
        }

        @OptIn(DelicateCoroutinesApi::class)
        private fun updateExpand(isExpand: Boolean? = null) {
            val newExpandStatus = isExpand ?: group.isExpand
            group.isExpand = newExpandStatus

            binding.itemList.isVisible = newExpandStatus
            binding.groupSelected.isVisible = !newExpandStatus
            val textView = (binding.groupSelected.editText as MaterialAutoCompleteTextView)
            if (textWatcher != null) {
                textView.removeTextChangedListener(textWatcher)
            }
            if (!newExpandStatus) {
                textView.setText(group.selected)
                binding.groupSelected.isEnabled = group.selectable
                if (group.selectable) {
                    textView.setSimpleItems(items.toList().map { it.tag }.toTypedArray())
                    textWatcher = textView.addTextChangedListener {
                        val selected = textView.text.toString()
                        if (selected != group.selected) {
                            updateSelected(group, selected)
                        }
                        runOnDefaultDispatcher {
                            activity?.connection?.service?.groupSelecte(group.name, selected)
                        }
                    }
                }
            }
            if (newExpandStatus) {
                binding.urlTestButton.isVisible = true
                binding.expandButton.setImageResource(R.drawable.ic_expand_less_24)
            } else {
                binding.urlTestButton.isVisible = false
                binding.expandButton.setImageResource(R.drawable.ic_expand_more_24)
            }
            binding.expandButton.setOnClickListener {
                updateExpand(!binding.itemList.isVisible)
            }
        }

        fun updateSelected(group: Group, itemTag: String) {
            val oldSelected = items.indexOfFirst { it.tag == group.selected }
            group.selected = itemTag
            if (oldSelected != -1) {
                adapter.notifyItemChanged(oldSelected)
            }
        }
    }

    inner class ItemAdapter(
        val groupView: GroupView,
        var group: Group,
        private var items: MutableList<GroupItem> = mutableListOf()
    ) :
        RecyclerView.Adapter<ItemGroupView>() {

        @SuppressLint("NotifyDataSetChanged")
        fun setItems(newItems: List<GroupItem>) {
            if (items.size != newItems.size) {
                items = newItems.toMutableList()
                notifyDataSetChanged()
            } else {
                newItems.forEachIndexed { index, item ->
                    if (items[index] != item) {
                        items[index] = item
                        notifyItemChanged(index)
                    }
                }
            }
        }

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): ItemGroupView {
            return ItemGroupView(
                ViewDashboardGroupItemBinding.inflate(
                    LayoutInflater.from(parent.context),
                    parent,
                    false,
                )
            )
        }

        override fun getItemCount(): Int {
            return items.size
        }

        override fun onBindViewHolder(holder: ItemGroupView, position: Int) {
            holder.bind(groupView, group, items[position])
        }
    }

    inner class ItemGroupView(val binding: ViewDashboardGroupItemBinding) :
        RecyclerView.ViewHolder(binding.root) {

        @OptIn(DelicateCoroutinesApi::class)
        fun bind(groupView: GroupView, group: Group, item: GroupItem) {
            if (group.selectable) {
                binding.itemCard.setOnClickListener {
                    binding.selectedView.isVisible = true
                    groupView.updateSelected(group, item.tag)
                    runOnDefaultDispatcher {
                        activity?.connection?.service?.groupSelecte(group.name, item.tag)
                    }
                }
            }
            binding.selectedView.isInvisible = group.selected != item.tag
            binding.itemName.text = item.tag
            binding.itemStatus.isVisible = item.delay > 0
            if (item.delay > 0) {
                binding.itemStatus.text = "${item.delay}ms"
                binding.itemStatus.setTextColor(
                    colorForURLTestDelay(
                        binding.root.context,
                        item.delay,
                    )
                )
            }
        }
    }
}