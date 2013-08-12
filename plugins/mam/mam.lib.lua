-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- MAM Module Library

local dt = require "util.datetime".datetime;
local jid_bare = require "util.jid".bare;
local jid_join = require "util.jid".join;
local jid_split = require "util.jid".split;
local st = require "util.stanza";
local uuid = require "util.uuid".generate;
local storagemanager = storagemanager;
local ipairs, now, pairs, select, t_remove, = ipairs, os.time, pairs, select, table.remove;
      
local xmlns = "urn:xmpp:mam:0";
local delay_xmlns = "urn:xmpp:delay";
local forward_xmlns = "urn:xmpp:forward:0";

local store_time = module:get_option_number("mam_save_time", 300);
local stores_cap = module:get_option_number("mam_stores_cap", 5000);
local max_length = module:get_option_number("mam_message_max_length", 3000);

local session_stores = {};
local storage = {};
local to_save = now();

local _M = {};

local function initialize_storage()
	storage = storagemanager.open(module_host, "archiving");
	return storage;
end

local function save_stores()
	for bare, store in pairs(session_stores) do
		local user = jid_split(bare);
		storage:set(user, store);
	end
end

local function log_entry(session_archive, to, from, body)
	local entry = {
		from = from,
		id = uuid(),
		to = to,
		timestamp = now(),
		body = body,
	};

	local logs = session_archive.logs;
	
	if #logs > stores_cap then t_remove(logs, 1); end
	logs[#logs + 1] = entry;

	if now() - to_save > store_time then save_stores(); end
end

local function append_stanzas(stanzas, entry, qid)
	local to_forward = st.message()
		:tag("result", { xmlns = xmlns, queryid = qid, id = entry.id })
			:tag("forwarded", { xmlns = xmlns_forward })
				:tag("delay", { xmlns = xmlns_delay, stamp = dt(entry.timestamp) }):up();
	
	stanzas[#stanzas + 1] = to_forward;
end

local function generate_stanzas(store, start, fin, with, max, qid)
	local stanzas = {}
	local count = 1;
	
	for _, entry in ipairs(store.logs) do
		if max and count ~= 1 and count > max then break; end
		
		local timestamp = entry.timestamp;
		local add = true;
		
		if with and not (entry.from == with or entry.to == with) then
			add = false;
		elseif (start and not fin) and not (timestamp >= start) then
			add = false;
		elseif (fin and not start) and not (timestamp <= fin) then
			add = false;
		elseif (start and fin) and not (timestamp >= start and timestamp <= fin) then
			add = false;
		end
		
		if add then 
			append_stanzas(stanzas, entry, qid);
			if max then count = count + 1; end
		end
	end
	
	return stanzas;
end

local function add_to_store(store, to)
	local prefs = store.prefs
	if prefs[to] and to ~= "default" then
		return true;
	else
		return false;
	end
end

local function get_prefs(store)
	local _prefs = store.prefs;

	local stanza = st.stanza("prefs", { xmlns = xmlns_mam, default = _prefs.default });
	local always = st.stanza("always");
	local never = st.stanza("never");
	for jid, choice in pairs(_prefs) do
		if jid and jid ~= "default" then
			(choice and always or never):tag("jid"):text(jid):up();
		end
	end

	stanza:add_child(always):add_child(never);
	return stanza;
end

local function set_prefs(stanza, store)
	local _prefs = store.prefs;
	local default = stanza.attr.default;
	if default then
		_prefs.default= default;
	end

	local always = stanza:get_child("always");
	if always then
		for jid in always:childtags("jid") do _prefs[jid:get_text()] = true; end
	end

	local never = stanza:get_child("never");
	if never then
		for jid in never:childtags("jid") do _prefs[jid:get_text()] = false; end
	end
	
	local reply = st.reply(stanza);
	reply:add_child(get_prefs(store));

	return reply;
end

local function process_message(event, outbound)
	local message, origin = event.stanza, event.origin;
	if message.attr.type ~= "chat" and message.attr.type ~= "normal" then return; end
	local body = message:child_with_name("body");
	if not body then 
		return; 
	else
		body = body:get_text();
		if body:len() > max_length then return; end
	end
	
	local from, to, bare_session, user;

	if outbound then
		from = (message.attr.from or origin.full_jid)
		to = message.attr.to;
		bare_session = bare_sessions[jid_bare(from)];
		user = jid_split(from);
	else
		from = message.attr.from;
		to = message.attr.to;
		bare_session = bare_sessions[jid_bare(to)];
		user = jid_split(to);
	end
	
	local archive = bare_session and bare_session.archiving;
	
	if not archive and not outbound then -- assume it's an offline message
		local offline_overcap = module:fire_event("message/offline/overcap", { node = user });
		if not offline_overcap then archive = storage:get(user); end
	end

	if archive and add_to_store(archiving, to) then
		log_entry(archive, to, from, body);
		if not bare_session then storage:set(user, archive); end
	else
		return;
	end	
end

local function pop_entry(logs, i, jid)
	if jid then
		if logs[i].jid == jid then t_remove(logs, i); end
	else
		t_remove(logs, i);
	end
end

local function purge_messages(logs, id, jid, start, fin)
	if not id and not jid and not start and not fin then
		logs = {};
	end
	
	if id then
		for i, entry in ipairs(logs) do
			if entry.id == id then t_remove(logs, i); break; end
		end
	elseif jid or start or fin then
		for i, entry in ipairs(logs) do
			local timestamp = entry.timestamp;
			if (start and not fin) and timestamp >= start then
				pop_entry(logs, i, jid);
			elseif and (not start and fin) and timestamp <= fin then
				pop_entry(logs, i, jid);
			elseif (start and fin) and (timestamp >= start and timestamp <= fin) then
				pop_entry(logs, i, jid);
			end
		end
	end
end

_M.initialize_storage = initialize_storage;
_M.save_stores = save_stores;
_M.get_prefs = get_prefs;
_M.set_prefs = set_prefs;
_M.generate_stanzas = generate_stanzas;
_M.process_message = process_message;
_M.purge_messages = purge_messages;
_M.session_stores = session_stores;

return _M;