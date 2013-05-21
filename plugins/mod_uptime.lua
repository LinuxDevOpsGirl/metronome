-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2008-2010, Matthew Wild, Waqas Hussain

local st = require "util.stanza";

local start_time = metronome.start_time;
module:hook_global("server-started", function() start_time = metronome.start_time end);

-- XEP-0012: Last activity
module:add_feature("jabber:iq:last");

module:hook("iq/host/jabber:iq:last:query", function(event)
	local origin, stanza = event.origin, event.stanza;
	if stanza.attr.type == "get" then
		origin.send(st.reply(stanza):tag("query", {xmlns = "jabber:iq:last", seconds = tostring(os.difftime(os.time(), start_time))}));
		return true;
	end
end);

-- Ad-hoc command
local adhoc_new = module:require "adhoc".new;

function uptime_text()
	local t = os.time()-start_time;
	local seconds = t%60;
	t = (t - seconds)/60;
	local minutes = t%60;
	t = (t - minutes)/60;
	local hours = t%24;
	t = (t - hours)/24;
	local days = t;
	return string.format("This server has been running for %d day%s, %d hour%s and %d minute%s (since %s)",
		days, (days ~= 1 and "s") or "", hours, (hours ~= 1 and "s") or "",
		minutes, (minutes ~= 1 and "s") or "", os.date("%c", start_time));
end

function uptime_command_handler (self, data, state)
	return { info = uptime_text(), status = "completed" };
end

local descriptor = adhoc_new("Get uptime", "uptime", uptime_command_handler);

module:add_item ("adhoc", descriptor);
