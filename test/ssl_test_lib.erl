%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 2008-2010. All Rights Reserved.
%%
%% The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved online at http://www.erlang.org/.
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%%
%% %CopyrightEnd%
%%

%%
-module(ssl_test_lib).

-include("test_server.hrl").
-include("test_server_line.hrl").

%% Note: This directive should only be used in test suites.
-compile(export_all).

-record(sslsocket, { fd = nil, pid = nil}).

timetrap(Time) ->
    Mul = try 
	      test_server:timetrap_scale_factor()
	  catch _:_ -> 1 end,
    test_server:timetrap(1000+Time*Mul).

%% For now always run locally
run_where(_) ->
    ClientNode = node(),
    ServerNode = node(),
    {ok, Host} = rpc:call(ServerNode, inet, gethostname, []),
    {ClientNode, ServerNode, Host}.

run_where(_, ipv6) ->
    ClientNode = node(),
    ServerNode = node(),
    {ok, Host} = rpc:call(ServerNode, inet, gethostname, []),
    {ClientNode, ServerNode, Host}.

node_to_hostip(Node) ->
    [_ , Host] = string:tokens(atom_to_list(Node), "@"),
    {ok, Address} = inet:getaddr(Host, inet),
    Address.

start_server(Args) ->
    Result = spawn_link(?MODULE, run_server, [Args]),
    receive
	{listen, up} ->
	    Result
    end.

run_server(Opts) ->
    Node = proplists:get_value(node, Opts),
    Port = proplists:get_value(port, Opts),
    Options = proplists:get_value(options, Opts),
    Pid = proplists:get_value(from, Opts),
    test_server:format("ssl:listen(~p, ~p)~n", [Port, Options]),
    {ok, ListenSocket} = rpc:call(Node, ssl, listen, [Port, Options]),
    Pid ! {listen, up},
    send_selected_port(Pid, Port, ListenSocket),
    run_server(ListenSocket, Opts).

run_server(ListenSocket, Opts) ->
    AcceptSocket = connect(ListenSocket, Opts),
    Node = proplists:get_value(node, Opts),
    Pid = proplists:get_value(from, Opts),
    {Module, Function, Args} = proplists:get_value(mfa, Opts),
    test_server:format("Server: apply(~p,~p,~p)~n", 
		       [Module, Function, [AcceptSocket | Args]]),
    case rpc:call(Node, Module, Function, [AcceptSocket | Args]) of
	no_result_msg ->
	    ok;
	Msg ->
	    test_server:format("Msg: ~p ~n", [Msg]),    
	    Pid ! {self(), Msg}
    end,
    receive 
	listen ->
	    run_server(ListenSocket, Opts);
	close ->
	    ok = rpc:call(Node, ssl, close, [AcceptSocket])
    end.

%%% To enable to test with s_client -reconnect
connect(ListenSocket, Opts) ->
    Node = proplists:get_value(node, Opts),
    ReconnectTimes =  proplists:get_value(reconnect_times, Opts, 0),
    AcceptSocket = connect(ListenSocket, Node, 1 + ReconnectTimes, dummy),
    case ReconnectTimes of
	0 ->
	    AcceptSocket;
	_ ->
	  remove_close_msg(ReconnectTimes),
	  AcceptSocket
    end.
    
connect(_, _, 0, AcceptSocket) ->
    AcceptSocket;
connect(ListenSocket, Node, N, _) ->
    test_server:format("ssl:transport_accept(~p)~n", [ListenSocket]),
    {ok, AcceptSocket} = rpc:call(Node, ssl, transport_accept, 
				  [ListenSocket]),    
    test_server:format("ssl:ssl_accept(~p)~n", [AcceptSocket]),
    ok = rpc:call(Node, ssl, ssl_accept, [AcceptSocket]),
    connect(ListenSocket, Node, N-1, AcceptSocket).
  
remove_close_msg(0) ->
    ok;
remove_close_msg(ReconnectTimes) ->
    receive
	{ssl_closed, _} ->
	   remove_close_msg(ReconnectTimes -1)
    end.
	    

start_client(Args) ->
    Result = spawn_link(?MODULE, run_client, [Args]),
    receive 
	connected ->
	    Result
    end.

run_client(Opts) ->
    Node = proplists:get_value(node, Opts),
    Host = proplists:get_value(host, Opts),
    Port = proplists:get_value(port, Opts),
    Pid = proplists:get_value(from, Opts),
    Options = proplists:get_value(options, Opts),
    test_server:format("ssl:connect(~p, ~p, ~p)~n", [Host, Port, Options]),
    case rpc:call(Node, ssl, connect, [Host, Port, Options]) of
	{ok, Socket} ->
	    Pid ! connected,
	    test_server:format("Client: connected~n", []), 
	    %% In specail cases we want to know the client port, it will
	    %% be indicated by sending {port, 0} in options list!
	    send_selected_port(Pid,  proplists:get_value(port, Options), Socket),
	    {Module, Function, Args} = proplists:get_value(mfa, Opts),
	    test_server:format("Client: apply(~p,~p,~p)~n", 
			       [Module, Function, [Socket | Args]]),
	    case rpc:call(Node, Module, Function, [Socket | Args]) of
		no_result_msg ->
		    ok;
		Msg ->
		    Pid ! {self(), Msg}
	    end,
	    receive 
		close ->
		    ok = rpc:call(Node, ssl, close, [Socket])
	    end;
	{error, Reason} ->
	    test_server:format("Client: connection failed: ~p ~n", [Reason]), 
	       Pid ! {self(), {error, Reason}}
    end.

close(Pid) ->
    Pid ! close.

check_result(Server, ServerMsg, Client, ClientMsg) -> 
    receive 
	{Server, ServerMsg} -> 
	    receive 
		{Client, ClientMsg} ->
		    ok;
		Unexpected ->
		    Reason = {{expected, {Client, ClientMsg}}, 
			      {got, Unexpected}},
		    test_server:fail(Reason)
	    end;
	{Client, ClientMsg} -> 
	    receive 
		{Server, ServerMsg} ->
		    ok;
		Unexpected ->
		    Reason = {{expected, {Server, ClientMsg}}, 
			      {got, Unexpected}},
		    test_server:fail(Reason)
	    end;
	{Port, {data,Debug}} when is_port(Port) ->
	    io:format("openssl ~s~n",[Debug]),
	    check_result(Server, ServerMsg, Client, ClientMsg);

	Unexpected ->
	    Reason = {{expected, {Client, ClientMsg}},
		      {expected, {Server, ServerMsg}}, {got, Unexpected}},
	    test_server:fail(Reason)
    end.

check_result(Pid, Msg) -> 
    receive 
	{Pid, Msg} -> 
	    ok;
	{Port, {data,Debug}} when is_port(Port) ->
	    io:format("openssl ~s~n",[Debug]),
	    check_result(Pid,Msg);
	Unexpected ->
	    Reason = {{expected, {Pid, Msg}}, 
		      {got, Unexpected}},
	    test_server:fail(Reason)
    end.

check_result_ignore_renegotiation_reject(Pid, Msg) -> 
    receive 
	{Pid,  fail_session_fatal_alert_during_renegotiation} ->
	    test_server:comment("Server rejected old renegotiation"),
	    ok;
	{ssl_error, _, esslconnect} ->
	    test_server:comment("Server rejected old renegotiation"),
	    ok;
	{Pid, Msg} -> 
	    ok;
	{Port, {data,Debug}} when is_port(Port) ->
	    io:format("openssl ~s~n",[Debug]),
	    check_result(Pid,Msg);
	Unexpected ->
	    Reason = {{expected, {Pid, Msg}}, 
		      {got, Unexpected}},
	    test_server:fail(Reason)
    end.


wait_for_result(Server, ServerMsg, Client, ClientMsg) -> 
    receive 
	{Server, ServerMsg} -> 
	    receive 
		{Client, ClientMsg} ->
		    ok;
		Unexpected ->
		    Unexpected
	    end;
	{Client, ClientMsg} -> 
	    receive 
		{Server, ServerMsg} ->
		    ok;
		Unexpected ->
		    Unexpected
	    end;
	{Port, {data,Debug}} when is_port(Port) ->
	    io:format("openssl ~s~n",[Debug]),
	    wait_for_result(Server, ServerMsg, Client, ClientMsg);
	Unexpected ->
	    Unexpected
    end.


wait_for_result(Pid, Msg) -> 
    receive 
	{Pid, Msg} -> 
	    ok;
	{Port, {data,Debug}} when is_port(Port) ->
	    io:format("openssl ~s~n",[Debug]),
	    wait_for_result(Pid,Msg);
	Unexpected ->
	    Unexpected
    end.

cert_options(Config) ->
    ClientCaCertFile = filename:join([?config(priv_dir, Config), 
				      "client", "cacerts.pem"]),
    ClientCertFile = filename:join([?config(priv_dir, Config), 
				    "client", "cert.pem"]),
    ServerCaCertFile = filename:join([?config(priv_dir, Config), 
				      "server", "cacerts.pem"]),
    ServerCertFile = filename:join([?config(priv_dir, Config), 
				    "server", "cert.pem"]),
    ServerKeyFile = filename:join([?config(priv_dir, Config), 
			     "server", "key.pem"]),
    ClientKeyFile = filename:join([?config(priv_dir, Config), 
			     "client", "key.pem"]),
    ServerKeyCertFile = filename:join([?config(priv_dir, Config), 
				       "server", "keycert.pem"]),
    ClientKeyCertFile = filename:join([?config(priv_dir, Config), 
				       "client", "keycert.pem"]),

    BadCaCertFile = filename:join([?config(priv_dir, Config), 
				   "badcacert.pem"]),
    BadCertFile = filename:join([?config(priv_dir, Config), 
				   "badcert.pem"]),
    BadKeyFile = filename:join([?config(priv_dir, Config), 
			      "badkey.pem"]),
    [{client_opts, [{ssl_imp, new},{reuseaddr, true}]}, 
     {client_verification_opts, [{cacertfile, ClientCaCertFile}, 
				{certfile, ClientCertFile},  
				{keyfile, ClientKeyFile},
				{ssl_imp, new}]}, 
     {server_opts, [{ssl_imp, new},{reuseaddr, true}, 
		    {certfile, ServerCertFile}, {keyfile, ServerKeyFile}]},
     {server_verification_opts, [{ssl_imp, new},{reuseaddr, true}, 
		    {cacertfile, ServerCaCertFile},
		    {certfile, ServerCertFile}, {keyfile, ServerKeyFile}]},
     {client_kc_opts, [{certfile, ClientKeyCertFile},  {ssl_imp, new}]}, 
     {server_kc_opts, [{ssl_imp, new},{reuseaddr, true}, 
		       {certfile, ServerKeyCertFile}]},
     {client_bad_ca, [{cacertfile, BadCaCertFile}, 
		      {certfile, ClientCertFile},
		      {keyfile, ClientKeyFile},
		      {ssl_imp, new}]},
     {client_bad_cert, [{cacertfile, ClientCaCertFile},	    
			{certfile, BadCertFile},  
			{keyfile, ClientKeyFile},
			{ssl_imp, new}]},
     {server_bad_ca, [{ssl_imp, new},{cacertfile, BadCaCertFile},
		      {certfile, ServerCertFile}, 
		      {keyfile, ServerKeyFile}]},
     {server_bad_cert, [{ssl_imp, new},{cacertfile, ServerCaCertFile},
			{certfile, BadCertFile}, {keyfile, ServerKeyFile}]},
     {server_bad_key, [{ssl_imp, new},{cacertfile, ServerCaCertFile},
		       {certfile, ServerCertFile}, {keyfile, BadKeyFile}]}
     | Config].


make_dsa_cert(Config) ->
    
    {ServerCaCertFile, ServerCertFile, ServerKeyFile} = make_dsa_cert_files("server", Config),
    {ClientCaCertFile, ClientCertFile, ClientKeyFile} = make_dsa_cert_files("client", Config),
    [{server_dsa_opts, [{ssl_imp, new},{reuseaddr, true}, 
				 {cacertfile, ServerCaCertFile},
				 {certfile, ServerCertFile}, {keyfile, ServerKeyFile}]},
     {server_dsa_verify_opts, [{ssl_imp, new},{reuseaddr, true}, 
			       {cacertfile, ServerCaCertFile},
			       {certfile, ServerCertFile}, {keyfile, ServerKeyFile},
			       {verify, verify_peer}]},
     {client_dsa_opts, [{ssl_imp, new},{reuseaddr, true}, 
			{cacertfile, ClientCaCertFile},
			{certfile, ClientCertFile}, {keyfile, ClientKeyFile}]}
     | Config].


    
make_dsa_cert_files(RoleStr, Config) ->    
    CaInfo = {CaCert, _} = erl_make_certs:make_cert([{key, dsa}]),
    {Cert, CertKey} = erl_make_certs:make_cert([{key, dsa}, {issuer, CaInfo}]),
    CaCertFile = filename:join([?config(priv_dir, Config), 
				RoleStr, "dsa_cacerts.pem"]),
    CertFile = filename:join([?config(priv_dir, Config), 
			      RoleStr, "dsa_cert.pem"]),
    KeyFile = filename:join([?config(priv_dir, Config), 
				   RoleStr, "dsa_key.pem"]),
    
    der_to_pem(CaCertFile, [{'Certificate', CaCert, not_encrypted}]),
    der_to_pem(CertFile, [{'Certificate', Cert, not_encrypted}]),
    der_to_pem(KeyFile, [CertKey]),
    {CaCertFile, CertFile, KeyFile}.

start_upgrade_server(Args) ->
    Result = spawn_link(?MODULE, run_upgrade_server, [Args]),
    receive
	{listen, up} ->
	    Result
    end.

run_upgrade_server(Opts) ->
    Node = proplists:get_value(node, Opts),
    Port = proplists:get_value(port, Opts),
    TimeOut = proplists:get_value(timeout, Opts, infinity),
    TcpOptions = proplists:get_value(tcp_options, Opts),
    SslOptions = proplists:get_value(ssl_options, Opts),
    Pid = proplists:get_value(from, Opts),

    test_server:format("gen_tcp:listen(~p, ~p)~n", [Port, TcpOptions]),
    {ok, ListenSocket} = rpc:call(Node, gen_tcp, listen, [Port, TcpOptions]),
    Pid ! {listen, up},
    send_selected_port(Pid, Port, ListenSocket),
    test_server:format("gen_tcp:accept(~p)~n", [ListenSocket]),
    {ok, AcceptSocket} = rpc:call(Node, gen_tcp, accept, [ListenSocket]),

    try
	{ok, SslAcceptSocket} = case TimeOut of
				    infinity ->
					test_server:format("ssl:ssl_accept(~p, ~p)~n",
							   [AcceptSocket, SslOptions]),
					rpc:call(Node, ssl, ssl_accept,
						 [AcceptSocket, SslOptions]);
				    _ ->
					test_server:format("ssl:ssl_accept(~p, ~p, ~p)~n",
							   [AcceptSocket, SslOptions, TimeOut]),
					rpc:call(Node, ssl, ssl_accept,
						 [AcceptSocket, SslOptions, TimeOut])
				end,
	{Module, Function, Args} = proplists:get_value(mfa, Opts),
	Msg = rpc:call(Node, Module, Function, [SslAcceptSocket | Args]),
	Pid ! {self(), Msg},
	receive
	    close ->
		ok = rpc:call(Node, ssl, close, [SslAcceptSocket])
	end
    catch error:{badmatch, Error} ->
	    Pid ! {self(), Error}
    end.

start_upgrade_client(Args) ->
    spawn_link(?MODULE, run_upgrade_client, [Args]).

run_upgrade_client(Opts) ->
    Node = proplists:get_value(node, Opts),
    Host = proplists:get_value(host, Opts),
    Port = proplists:get_value(port, Opts),
    Pid = proplists:get_value(from, Opts),
    TcpOptions = proplists:get_value(tcp_options, Opts),
    SslOptions = proplists:get_value(ssl_options, Opts),
    
    test_server:format("gen_tcp:connect(~p, ~p, ~p)~n", 
		       [Host, Port, TcpOptions]),
    {ok, Socket} = rpc:call(Node, gen_tcp, connect, [Host, Port, TcpOptions]),

    send_selected_port(Pid, Port, Socket),

    test_server:format("ssl:connect(~p, ~p)~n", [Socket, SslOptions]),
    {ok, SslSocket} = rpc:call(Node, ssl, connect, [Socket, SslOptions]),

    {Module, Function, Args} = proplists:get_value(mfa, Opts),
    test_server:format("apply(~p, ~p, ~p)~n", 
		       [Module, Function, [SslSocket | Args]]),
    Msg = rpc:call(Node, Module, Function, [SslSocket | Args]),
    Pid ! {self(), Msg},
    receive 
	close ->
	    ok = rpc:call(Node, ssl, close, [SslSocket])
    end.

start_upgrade_server_error(Args) ->
    Result = spawn_link(?MODULE, run_upgrade_server_error, [Args]),
    receive
	{listen, up} ->
	    Result
    end.

run_upgrade_server_error(Opts) ->
    Node = proplists:get_value(node, Opts),
    Port = proplists:get_value(port, Opts),
    TimeOut = proplists:get_value(timeout, Opts, infinity),
    TcpOptions = proplists:get_value(tcp_options, Opts),
    SslOptions = proplists:get_value(ssl_options, Opts),
    Pid = proplists:get_value(from, Opts),

    test_server:format("gen_tcp:listen(~p, ~p)~n", [Port, TcpOptions]),
    {ok, ListenSocket} = rpc:call(Node, gen_tcp, listen, [Port, TcpOptions]),
    Pid ! {listen, up},
    send_selected_port(Pid, Port, ListenSocket),
    test_server:format("gen_tcp:accept(~p)~n", [ListenSocket]),
    {ok, AcceptSocket} = rpc:call(Node, gen_tcp, accept, [ListenSocket]),
    Error = case TimeOut of
		infinity ->
		    test_server:format("ssl:ssl_accept(~p, ~p)~n",
				       [AcceptSocket, SslOptions]),
		    rpc:call(Node, ssl, ssl_accept,
			     [AcceptSocket, SslOptions]);
		_ ->
		    test_server:format("ssl:ssl_accept(~p, ~p, ~p)~n",
				       [AcceptSocket, SslOptions, TimeOut]),
		    rpc:call(Node, ssl, ssl_accept,
			     [AcceptSocket, SslOptions, TimeOut])
	    end,
    Pid ! {self(), Error}.

start_server_error(Args) ->
    Result = spawn_link(?MODULE, run_server_error, [Args]),
    receive 
	{listen, up} ->
	    Result
    end.

run_server_error(Opts) ->
    Node = proplists:get_value(node, Opts),
    Port = proplists:get_value(port, Opts),
    Options = proplists:get_value(options, Opts),
    Pid = proplists:get_value(from, Opts),
    test_server:format("ssl:listen(~p, ~p)~n", [Port, Options]),
    case rpc:call(Node, ssl, listen, [Port, Options]) of
	{ok, ListenSocket} ->
	    %% To make sure error_client will
	    %% get {error, closed} and not {error, connection_refused}
	    Pid ! {listen, up},
	    send_selected_port(Pid, Port, ListenSocket),
	    test_server:format("ssl:transport_accept(~p)~n", [ListenSocket]),
	    case rpc:call(Node, ssl, transport_accept, [ListenSocket]) of
		{error, _} = Error ->
		    Pid ! {self(), Error};
		{ok, AcceptSocket} ->
		    test_server:format("ssl:ssl_accept(~p)~n", [AcceptSocket]),
		    Error = rpc:call(Node, ssl, ssl_accept, [AcceptSocket]),
		    Pid ! {self(), Error}
	    end;
	Error ->
	    %% Not really true but as this is an error test 
	    %% this is what we want.
	    Pid ! {listen, up},
	    Pid ! {self(), Error}
    end.

start_client_error(Args) ->
    spawn_link(?MODULE, run_client_error, [Args]).

run_client_error(Opts) ->
    Node = proplists:get_value(node, Opts),
    Host = proplists:get_value(host, Opts),
    Port = proplists:get_value(port, Opts),
    Pid = proplists:get_value(from, Opts),
    Options = proplists:get_value(options, Opts),
    test_server:format("ssl:connect(~p, ~p, ~p)~n", [Host, Port, Options]),
    Error = rpc:call(Node, ssl, connect, [Host, Port, Options]),
    Pid ! {self(), Error}.

inet_port(Pid) when is_pid(Pid)->
    receive
	{Pid, {port, Port}} ->
	    Port
    end;

inet_port(Node) ->
    {Port, Socket} = do_inet_port(Node),
     rpc:call(Node, gen_tcp, close, [Socket]),
     Port.

do_inet_port(Node) ->
    {ok, Socket} = rpc:call(Node, gen_tcp, listen, [0, [{reuseaddr, true}]]),
    {ok, Port} = rpc:call(Node, inet, port, [Socket]),
    {Port, Socket}.

no_result(_) ->
    no_result_msg.

trigger_renegotiate(Socket, [ErlData, N]) ->
    [{session_id, Id} | _ ] = ssl:session_info(Socket),
    trigger_renegotiate(Socket, ErlData, N, Id).

trigger_renegotiate(Socket, _, 0, Id) ->
    test_server:sleep(1000),
    case ssl:session_info(Socket) of
	[{session_id, Id} | _ ] ->
	    fail_session_not_renegotiated;
	%% Tests that uses this function will not reuse
	%% sessions so if we get a new session id the
	%% renegotiation has succeeded.
       	[{session_id, _} | _ ] -> 
	    ok;
	{error, closed} ->
	    fail_session_fatal_alert_during_renegotiation;
	{error, timeout} ->
	    fail_timeout
    end;

trigger_renegotiate(Socket, ErlData, N, Id) ->
    ssl:send(Socket, ErlData),
    trigger_renegotiate(Socket, ErlData, N-1, Id).				   
    

send_selected_port(Pid, 0, #sslsocket{} = Socket) ->
    {ok, {_, NewPort}} = ssl:sockname(Socket),	 
    Pid ! {self(), {port, NewPort}};
send_selected_port(Pid, 0, Socket) ->
    {ok, {_, NewPort}} = inet:sockname(Socket),	 
    Pid ! {self(), {port, NewPort}};
send_selected_port(_,_,_) ->
    ok.

rsa_suites() ->
    lists:filter(fun({dhe_dss, _, _}) ->
			 false;
		    (_) ->
			 true
		 end,
		 ssl:cipher_suites()).

dsa_suites() ->
     lists:filter(fun({dhe_dss, _, _}) ->
			 true;
		    (_) ->
			 false
		 end,
		 ssl:cipher_suites()).


openssl_rsa_suites() ->
    Ciphers = ssl:cipher_suites(openssl),
    lists:filter(fun(Str) ->
			 case re:run(Str,"DSS",[]) of
			     nomatch ->
				 true;
			     _ ->
				 false
			 end 
		 end, Ciphers).

openssl_dsa_suites() ->
    Ciphers = ssl:cipher_suites(openssl),
    lists:filter(fun(Str) ->
			 case re:run(Str,"DSS",[]) of
			     nomatch ->
				 false;
			     _ ->
				 true
			 end 
		 end, Ciphers).

pem_to_der(File) ->
    {ok, PemBin} = file:read_file(File),
    public_key:pem_decode(PemBin).

der_to_pem(File, Entries) ->
    PemBin = public_key:pem_encode(Entries),
    file:write_file(File, PemBin).
