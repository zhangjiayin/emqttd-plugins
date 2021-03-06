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

%% @doc emqttd plugin template supervisor.
-module(emqttd_redisl_sup).

-behaviour(supervisor).
-include("emqttd_lcy.hrl").

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, PoolEnv} = application:get_env(emqttd_lcy, eredis_pool),
    PoolSpec = ecpool:pool_spec(?APP, emqttd_redis_client, emqttd_redis_client, PoolEnv),
    {ok, {{one_for_one, 10, 100}, [PoolSpec]}}.
