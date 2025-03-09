package distro

import (
	"libcore/plugin/anytls"

	"github.com/sagernet/sing-box/adapter/outbound"
)

func registerPluginsOutbound(registry *outbound.Registry) {
	anytls.RegisterOutbound(registry)
}
