%%--------------------------------------------------------------------
%% Copyright (c) 2015-2016 Feng Lee <feng@emqtt.io>.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqttd_acl).

-behaviour(emqttd_acl_mod).
-include("emqttd_lcy.hrl").
-include_lib("../../../include/emqttd.hrl").
-import(proplists, [get_value/2]).
-import(emqttd_redis_client,[q/2]).

%% ACL callbacks
-export([init/1, check_acl/2, reload_acl/1, description/0]).

-record(state, {acl_query, acl_nomatch,get_uuid}).
-behaviour(ecpool_worker).

-export([parse_query/1, connect/1, squery/1, equery/2, equery/3]).

-define(UNDEFINED(S), (S =:= undefined orelse S =:= <<>>)).

init({AclQuery, AclNomatch,GetUUID}) ->
    {ok, #state{acl_query = AclQuery, acl_nomatch = AclNomatch,get_uuid = GetUUID}}.


%% 创建一个定时器把自的边接数更新的认证服器上

check_acl({#mqtt_client{username = <<$$, _/binary>>}, _PubSub, _Topic}, _State) ->
    ignore;



check_acl({Client, PubSub, Topic}, #state{acl_query   = {AclSql, AclParams},
                                          acl_nomatch = Default,
                                          get_uuid = GetUUID}) ->

     case q(GetUUID, Client) of
                {ok, undefined} ->
                    {error, not_found};
                {ok, Uuid} ->
                    Client2 = Client#mqtt_client{username = Uuid},
                    Result = equery(AclSql,AclParams,Client2),
                    %%io:format("ACL query from db,Result ~p~n",[Result]),
                    case Result of
                        {ok, _, []} ->
                            Default;
                        {ok, _, Rows} ->
                            Rules = filter(PubSub, compile(Rows)),
                            case match(Client2, Topic, Rules) of
                                {matched, allow} -> allow;
                                {matched, deny}  -> deny;
                                nomatch          -> Default
                            end;
                        {error, _Reason} ->
                            ignore
                    end;
                {error, Reason} ->
                    {error, Reason}
    end.

match(_Client, _Topic, []) ->
    nomatch;

match(Client, Topic, [Rule|Rules]) ->
    case emqttd_access_rule:match(Client, Topic, Rule) of
        nomatch -> match(Client, Topic, Rules);
        {matched, AllowDeny} -> {matched, AllowDeny}
    end.

filter(PubSub, Rules) ->
    [Term || Term = {_, _, Access, _} <- Rules, Access =:= PubSub orelse Access =:= pubsub].

compile(Rows) ->
    compile(Rows, []).
compile([], Acc) ->
    Acc;
compile([{Allow, IpAddr, Username, ClientId, Access, Topic}|T], Acc) ->
    Who  = who(IpAddr, Username, ClientId),
    Term = {allow(Allow), Who, access(Access), [topic(Topic)]},
    compile(T, [emqttd_access_rule:compile(Term) | Acc]).

who(_, <<"$all">>, _) ->
    all;
who(null, null, null) ->
    throw(undefined_who);
who(CIDR, Username, ClientId) ->
    Cols = [{ipaddr, b2l(CIDR)}, {user, Username}, {client, ClientId}],
    case [{C, V} || {C, V} <- Cols, V =/= null] of
        [Who] -> Who;
        Conds -> {'and', Conds}
    end.

allow(1)        -> allow;
allow(0)        -> deny;
allow(<<"1">>)  -> allow;
allow(<<"0">>)  -> deny.

access(1)       -> subscribe;
access(2)       -> publish;
access(3)       -> pubsub;
access(<<"1">>) -> subscribe;
access(<<"2">>) -> publish;
access(<<"3">>) -> pubsub.

topic(<<"eq ", Topic/binary>>) ->
    {eq, Topic};
topic(Topic) ->
    Topic.

reload_acl(_State) ->
    ok.

description() ->
    "ACL with PgSql".

b2l(null) -> null;
b2l(B)    -> binary_to_list(B).


%%--------------------------------------------------------------------
%% Avoid SQL Injection: Parse SQL to Parameter Query.
%%--------------------------------------------------------------------

parse_query(undefined) ->
    undefined;
parse_query(Sql) ->
    case re:run(Sql, "'%[uca]'", [global, {capture, all, list}]) of
        {match, Variables} ->
            Params = [Var || [Var] <- Variables],
            {pgvar(Sql, Params), Params};
        nomatch ->
            {Sql, []}
    end.

pgvar(Sql, Params) ->
    Vars = ["$" ++ integer_to_list(I) || I <- lists:seq(1, length(Params))],
    lists:foldl(fun({Param, Var}, S) ->
            re:replace(S, Param, Var, [global, {return, list}])
        end, Sql, lists:zip(Params, Vars)).



%%--------------------------------------------------------------------
%% PostgreSQL Connect/Query
%%--------------------------------------------------------------------

connect(Opts) ->
    Host     = get_value(host, Opts),
    Username = get_value(username, Opts),
    Password = get_value(password, Opts),
    epgsql:connect(Host, Username, Password, conn_opts(Opts)).

conn_opts(Opts) ->
    conn_opts(Opts, []).
conn_opts([], Acc) ->
    Acc;
conn_opts([Opt = {database, _}|Opts], Acc) ->
    conn_opts(Opts, [Opt|Acc]);
conn_opts([Opt = {ssl, _}|Opts], Acc) ->
    conn_opts(Opts, [Opt|Acc]);
conn_opts([Opt = {port, _}|Opts], Acc) ->
    conn_opts(Opts, [Opt|Acc]);
conn_opts([Opt = {timeout, _}|Opts], Acc) ->
    conn_opts(Opts, [Opt|Acc]);
conn_opts([_Opt|Opts], Acc) ->
    conn_opts(Opts, Acc).

squery(Sql) ->
    ecpool:with_client(?APP, fun(C) -> epgsql:squery(C, Sql) end).

equery(Sql, Params) ->
    ecpool:with_client(?APP, fun(C) -> epgsql:equery(C, Sql, Params) end).

equery(Sql, Params, Client) ->
    ecpool:with_client(?APP, fun(C) -> epgsql:equery(C, Sql, replvar(Params, Client)) end).

replvar(Params, Client) ->
    replvar(Params, Client, []).

replvar([], _Client, Acc) ->
    lists:reverse(Acc);
replvar(["'%u'" | Params], Client = #mqtt_client{username = Username}, Acc) ->
    replvar(Params, Client, [Username | Acc]);
replvar(["'%c'" | Params], Client = #mqtt_client{client_id = ClientId}, Acc) ->
    replvar(Params, Client, [ClientId | Acc]);
replvar(["'%a'" | Params], Client = #mqtt_client{peername = {IpAddr, _}}, Acc) ->
    replvar(Params, Client, [inet_parse:ntoa(IpAddr) | Acc]);
replvar([Param | Params], Client, Acc) ->
    replvar(Params, Client, [Param | Acc]).

