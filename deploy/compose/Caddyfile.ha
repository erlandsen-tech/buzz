{
	admin off
	auto_https off
}

# Upstream is Home Assistant on the Pi, over Tailscale. This proxy holds the
# long-lived token so no agent container ever sees it.
(ha) {
	reverse_proxy 100.93.239.124:8123 {
		header_up Authorization "Bearer {env.HA_TOKEN}"
		header_up Host 100.93.239.124:8123
		# Home Assistant rejects requests carrying X-Forwarded-* with 400 unless
		# the proxy is listed in its trusted_proxies. Strip them instead of
		# reconfiguring HA.
		header_up -X-Forwarded-For
		header_up -X-Forwarded-Proto
		header_up -X-Forwarded-Host
	}
}

:8126 {
	log

	# Reads: everything under /api/ with a safe method.
	@read {
		method GET HEAD
		path /api/*
	}

	# Automation authoring: create, update, delete an automation config.
	@automation {
		method POST DELETE
		path /api/config/automation/config/*
	}

	# Scene and script authoring, same surface as automations.
	@config_write {
		method POST DELETE
		path /api/config/scene/config/* /api/config/script/config/*
	}

	# Reloading the automation/script/scene registry after a write.
	@reload {
		method POST
		path /api/services/automation/reload /api/services/script/reload /api/services/scene/reload
	}

	# Template evaluation is a POST but has no side effects — useful for
	# checking a condition before writing an automation that depends on it.
	@template {
		method POST
		path /api/template
	}

	handle @read {
		import ha
	}
	handle @automation {
		import ha
	}
	handle @config_write {
		import ha
	}
	handle @reload {
		import ha
	}
	handle @template {
		import ha
	}

	# Everything else, including POST /api/services/* — direct device actuation.
	handle {
		respond "blocked by ha-proxy: this seat may read state and author automations, but may not call services directly" 403
	}
}
