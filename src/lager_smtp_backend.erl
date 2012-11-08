-module(lager_smtp_backend).
-author("Ivan Blinkov <ivan@blinkov.ru>").

-behaviour(gen_event).

-export([init/1, handle_call/2, handle_event/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {level, to, relay, username, password, port, ssl, flush_interval, flush_scheduled}).
-define(ETS_BUFFER, lager_smtp_buffer).

-include_lib("lager/include/lager.hrl").

init(Args) when is_list(Args) ->
	application:start(gen_smtp),
	To = lists:map(fun iolist_to_binary/1, proplists:get_value(to, Args)),
	ets:new(?ETS_BUFFER, [ordered_set, private, named_table]),
	{ok, #state{
		level = lager_util:level_to_num(proplists:get_value(level, Args, error)),
		to = To,
		relay = iolist_to_binary(proplists:get_value(relay, Args)),
		username = iolist_to_binary(proplists:get_value(username, Args)),
		password = iolist_to_binary(proplists:get_value(password, Args)),
		port = proplists:get_value(port, Args, 587),
		ssl = proplists:get_value(ssl, Args, true),
		flush_interval = proplists:get_value(flush_interval, Args, 20000),
		flush_scheduled = false
	}}.

handle_call(get_loglevel, #state{level=Level} = State) ->
		{ok, Level, State};

handle_call({set_loglevel, Level}, State) ->
		{ok, ok, State#state{level=lager_util:level_to_num(Level)}};

handle_call(_Request, State) ->
		{ok, ok, State}.

handle_event({log, Level, {Date, Time}, [_LevelStr, Location, RawMessage]}, #state{
		level = LogLevel,
		flush_scheduled = FlushScheduled,
		flush_interval = FlushInterval
	} = State) when Level =< LogLevel ->
	ets:insert(?ETS_BUFFER, {{Date, Time, Location}, Level, RawMessage}),
	case FlushScheduled of
		true -> ok;
		false ->
			timer:apply_after(FlushInterval, gen_event, notify, [lager_event, smtp_flush])
	end,		
	{ok, State#state{flush_scheduled = true}};

handle_event(smtp_flush, #state{
		to = To,
		relay = Relay,
		username = Username,
		password = Password,
		port = Port,
		ssl = SSL
	} = State) ->
	Body = ets:foldl(fun({{Date, Time, Location}, Level, RawMessage}, Acc) ->
		BinaryDate = iolist_to_binary(Date),
		BinaryTime = iolist_to_binary(Time),
		BinaryLocation = iolist_to_binary(Location),
		BinaryLevel = convert_level(Level),	
		BinaryMessage = iolist_to_binary(RawMessage),	

		BodyPart = <<"[", BinaryLevel/binary, "] ", 
			BinaryDate/binary, " ", BinaryTime/binary, " at ",
			BinaryLocation/binary, "\r\n\r\n",
			BinaryMessage/binary, "\r\n\r\n">>,
		<<Acc/binary, BodyPart/binary>>
	end, <<>>, ?ETS_BUFFER),
	
	BinaryNode = list_to_binary(atom_to_list(node())),
	Subject = <<"Logs from ", BinaryNode/binary>>,
	Recipients = join_to(To),	
	
	S = <<"Subject: ">>, F = <<"\r\nFrom: ">>, T = <<"\r\nTo: ">>, B = <<"\r\n\r\n">>,
	
	Message = <<S/binary, Subject/binary, F/binary, Username/binary,
				T/binary, Recipients/binary, B/binary, Body/binary>>,	
	
	gen_smtp_client:send({Username, To, Message},
		[{relay, Relay}, {username, Username}, {password, Password}, {port, Port}, {ssl, SSL}]),
	{ok, State#state{flush_scheduled = false}};


handle_event(_Event, State) ->
		{ok, State}.



handle_info(_Info, State) ->
		{ok, State}.

terminate(_Reason, _State) ->
		application:stop(gen_smtp),
		ok.

code_change(_OldVsn, State, _Extra) ->
		{ok, State}.

join_to(To) ->
	join_to(To, []).

join_to([Last], Acc) when is_binary(Last) ->
	iolist_to_binary(lists:reverse([Last | Acc]));
join_to([Recipient|To], Acc) ->
	join_to(To, [<<", ">> | [Recipient | Acc]]).

convert_level(?DEBUG) -> <<"debug">>;
convert_level(?INFO) -> <<"info">>;
convert_level(?NOTICE) -> <<"Notice">>;
convert_level(?WARNING) -> <<"Warning">>;
convert_level(?ERROR) -> <<"ERROR">>;
convert_level(?CRITICAL) -> <<"CRITICAL">>;
convert_level(?ALERT) -> <<"WARNING">>;
convert_level(?EMERGENCY) -> <<"EMERGENCY">>.

