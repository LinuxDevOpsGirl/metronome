-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2008-2013, Kim Alvefur, Matthew Wild, Waqas Hussain

local get_children = require "core.hostmanager".get_children;
local is_contact_subscribed = require "core.rostermanager".is_contact_subscribed;
local jid_split = require "util.jid".split;
local jid_bare = require "util.jid".bare;
local st = require "util.stanza"
local calculate_hash = require "util.caps".calculate_hash;
local ipairs, pairs = ipairs, pairs;
local hosts, my_host = hosts, module.host;

local show_hosts = module:get_option_boolean("disco_show_hosts", false);
local disco_items = module:get_option_table("disco_items", {});
do -- validate disco_items
	for _, item in ipairs(disco_items) do
		local err;
		if type(item) ~= "table" then
			err = "item is not a table";
		elseif type(item[1]) ~= "string" then
			err = "item jid is not a string";
		elseif item[2] and type(item[2]) ~= "string" then
			err = "item name is not a string";
		end
		if err then
			module:log("error", "option disco_items is malformed: %s", err);
			disco_items = {};
			break;
		end
	end
end

module:add_identity("server", "im", module:get_option_string("name", "Metronome"));
module:add_feature("http://jabber.org/protocol/disco#info");
module:add_feature("http://jabber.org/protocol/disco#items");

-- Generate and cache disco result and caps hash
local _cached_server_disco_info, _cached_server_caps_feature, _cached_server_caps_hash, _cached_children_data;
local function build_server_disco_info()
	local query = st.stanza("query", { xmlns = "http://jabber.org/protocol/disco#info" });
	local done = {};
	for _, identity in ipairs(module:get_items("identity")) do
		local identity_s = identity.category.."\0"..identity.type;
		if not done[identity_s] then
			query:tag("identity", identity):up();
			done[identity_s] = true;
		end
	end
	for _, feature in ipairs(module:get_items("feature")) do
		if not done[feature] then
			query:tag("feature", {var=feature}):up();
			done[feature] = true;
		end
	end
	for _, extension in ipairs(module:get_items("extension")) do
		if not done[extension] then
			query:add_child(extension);
			done[extension] = true;
		end
	end
	_cached_server_disco_info = query;
	_cached_server_caps_hash = calculate_hash(query);
	_cached_server_caps_feature = st.stanza("c", {
		xmlns = "http://jabber.org/protocol/caps";
		hash = "sha-1";
		node = "http://lightwitch.org/metronome";
		ver = _cached_server_caps_hash;
	});
end
local function clear_disco_cache()
	_cached_server_disco_info, _cached_server_caps_feature, _cached_server_caps_hash = nil, nil, nil;
end
local function get_server_disco_info()
	if not _cached_server_disco_info then build_server_disco_info(); end
	return _cached_server_disco_info;
end
local function get_server_caps_feature()
	if not _cached_server_caps_feature then build_server_disco_info(); end
	return _cached_server_caps_feature;
end
local function get_server_caps_hash()
	if not _cached_server_caps_hash then build_server_disco_info(); end
	return _cached_server_caps_hash;
end
local function build_cached_children_data()
	_cached_children_data = {};
	if not show_hosts then
		for jid, name in pairs(get_children(my_host)) do
			if hosts[jid].type == "component" then _cached_children_data[jid] = name; end
		end
	else
		for jid, name in pairs(get_children(my_host)) do _cached_children_data[jid] = name; end
	end
end

module:hook("item-added/identity", clear_disco_cache);
module:hook("item-added/feature", clear_disco_cache);
module:hook("item-added/extension", clear_disco_cache);
module:hook("item-removed/identity", clear_disco_cache);
module:hook("item-removed/feature", clear_disco_cache);
module:hook("item-removed/extension", clear_disco_cache);

-- Handle disco requests to the server
module:hook("iq/host/http://jabber.org/protocol/disco#info:query", function(event)
	local origin, stanza = event.origin, event.stanza;
	if stanza.attr.type ~= "get" then return; end
	local node = stanza.tags[1].attr.node;
	if node and node ~= "" and node ~= "http://lightwitch.org/metronome#"..get_server_caps_hash() then return; end -- TODO fire event?
	local reply_query = get_server_disco_info();
	reply_query.node = node;
	local reply = st.reply(stanza):add_child(reply_query);
	return origin.send(reply);
end);
module:hook("iq/host/http://jabber.org/protocol/disco#items:query", function(event)
	local origin, stanza = event.origin, event.stanza;
	if stanza.attr.type ~= "get" then return; end
	local node = stanza.tags[1].attr.node;
	if node and node ~= "" then return; end -- TODO fire event?

	local reply = st.reply(stanza):query("http://jabber.org/protocol/disco#items");
	for jid, name in pairs(_cached_children_data) do
		reply:tag("item", {jid = jid, name = name~=true and name or nil}):up();
	end
	for _, item in ipairs(disco_items) do
		reply:tag("item", {jid=item[1], name=item[2]}):up();
	end
	return origin.send(reply);
end);

-- Handle caps stream feature
module:hook("stream-features", function (event)
	if event.origin.type == "c2s" then
		event.features:add_child(get_server_caps_feature());
	end
end);

-- Handle disco requests to user accounts
module:hook("iq/bare/http://jabber.org/protocol/disco#info:query", function(event)
	local origin, stanza = event.origin, event.stanza;
	if stanza.attr.type ~= "get" then return; end
	local node = stanza.tags[1].attr.node;
	local username = jid_split(stanza.attr.to) or origin.username;
	if not stanza.attr.to or is_contact_subscribed(username, my_host, jid_bare(stanza.attr.from)) then
		local reply = st.reply(stanza):tag("query", {xmlns = "http://jabber.org/protocol/disco#info"});
		if not reply.attr.from then reply.attr.from = origin.username.."@"..origin.host; end -- COMPAT To satisfy Psi when querying own account
		module:fire_event("account-disco-info", { origin = origin, stanza = reply, node = node });
		if reply[false] then -- error caught during callbacks
			if reply.callback then
				reply = reply.callback(stanza, reply.error);
			else
				reply = st.error_reply(stanza, reply.type, reply.condition, reply.description);
			end
		end
		return origin.send(reply);
	end
end);
module:hook("iq/bare/http://jabber.org/protocol/disco#items:query", function(event)
	local origin, stanza = event.origin, event.stanza;
	if stanza.attr.type ~= "get" then return; end
	local node = stanza.tags[1].attr.node;
	local username = jid_split(stanza.attr.to) or origin.username;
	if not stanza.attr.to or is_contact_subscribed(username, my_host, jid_bare(stanza.attr.from)) then
		local reply = st.reply(stanza):tag("query", {xmlns = "http://jabber.org/protocol/disco#items"});
		if not reply.attr.from then reply.attr.from = origin.username.."@"..origin.host; end -- COMPAT To satisfy Psi when querying own account
		module:fire_event("account-disco-items", { origin = origin, stanza = reply, node = node });
		return origin.send(reply);
	end
end);

local function rebuild_children_data(host)
	if host:match("%.(.*)") == my_host then build_cached_children_data(); end
end
module:hook_global("host-activated", rebuild_children_data);
module:hook_global("host-deactivated", rebuild_children_data);
function module.load() build_cached_children_data(); end