package libcore

import (
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/urltest"
	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/protocol/group"
	"github.com/sagernet/sing/common"
	"github.com/sagernet/sing/service"

	"libcore/plugin"
)

func (b *BoxInstance) SelectOutbound(tag string) (ok bool) {
	if selector, isSelector := b.group.(*group.Selector); isSelector {
		ok = selector.SelectOutbound(tag)
		if ok {
			b.platformInterface.GroupCallback(tag)
		}
	}
	return
}

// watchGroupChange monitors changes in the selector.
// The interval at which the selector is checked is dynamically adjusted.
//
// block
func (b *BoxInstance) watchGroupChange() {
	const (
		duration0 = 500 * time.Millisecond
		duration1 = 700 * time.Millisecond
		duration2 = 1000 * time.Millisecond
		duration3 = 2000 * time.Millisecond
	)

	var durationLevel uint8 = 0
	ticker := time.NewTicker(duration0)
	defer ticker.Stop()

	updateTicker := func(changed bool) {
		if changed {
			ticker.Reset(duration0)
			durationLevel = 0
			return
		}

		switch durationLevel {
		case 0:
			ticker.Reset(duration1)
		case 1:
			ticker.Reset(duration2)
		case 2:
			ticker.Reset(duration3)
		case 3:
			// Already the longest
			return
		default:
			ticker.Reset(duration0)
		}
		durationLevel++
	}

	oldTag := b.group.Now()
	log.TraceContext(b.ctx, "Start watching group change")

	for {
		select {
		case <-b.ctx.Done():
			log.TraceContext(b.ctx, "Group change monitor close by context: ", b.ctx.Err())
			return
		case <-ticker.C:
			if b.state.Load() == boxStateClosed {
				log.TraceContext(b.ctx, "Group change monitor close because of box close")
				return
			}
		}

		newTag := b.group.Now()
		changed := oldTag != newTag
		if changed {
			b.platformInterface.GroupCallback(newTag)
			oldTag = newTag
		}
		updateTicker(changed)
	}

}

type Group struct {
	Tag        string
	Type       string
	Selected   string
	Selectable bool
}

// GetGroup returns the main proxy group.
func (b *BoxInstance) GetGroup() *Group {
	if b.group == nil {
		return nil
	}
	_, isSelector := b.group.(*group.Selector)
	return &Group{
		Tag:        b.group.Tag(),
		Type:       b.group.Type(),
		Selected:   b.group.Now(),
		Selectable: isSelector,
	}
}

type GroupItem struct {
	Tag   string
	Type  string
	Delay int16 // Short
}

type GroupItemIterator interface {
	Next() *GroupItem
	HasNext() bool
	Length() int32
}

// QueryGroup returns the group that named name's all items.
func (b *BoxInstance) QueryGroup(name string) GroupItemIterator {
	outbound, loaded := b.Outbound().Outbound(name)
	if !loaded {
		return nil
	}
	outboundGroup, isGroup := outbound.(adapter.OutboundGroup)
	if !isGroup {
		return nil
	}

	historyStorage := service.PtrFromContext[urltest.HistoryStorage](b.ctx)
	tags := outboundGroup.All()
	outboundManager := b.Outbound()
	items := common.Map(tags, func(it string) *GroupItem {
		outbound, _ := outboundManager.Outbound(it) // must

		var delay int16 = -1
		if historyStorage != nil {
			if history := historyStorage.LoadURLTestHistory(it); history != nil {
				delay = int16(history.Delay)
			}
		}

		return &GroupItem{
			Tag:   it,
			Type:  proxyDisplayName(outbound.Type()),
			Delay: delay,
		}
	})

	return newIterator(items)
}

func proxyDisplayName(proxyType string) string {
	pluginName, loaded := plugin.TypeMap[proxyType]
	if loaded {
		return pluginName
	}
	return C.ProxyDisplayName(proxyType)
}
